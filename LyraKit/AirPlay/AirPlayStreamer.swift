import Foundation
import Network
import os

/// A UDP port Lyra listens on; replies go back to whoever sent the request.
final class UDPServer: Sendable {
    let port: UInt16
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    /// `handler` returns the replies for one incoming datagram; it runs off the main thread.
    static func start(handler: @escaping @Sendable (Data) -> [Data]) async throws -> UDPServer {
        let listener = try NWListener(using: .udp, on: .any)
        let queue = DispatchQueue(label: "com.velpeo.Lyra.udp", qos: .userInteractive)
        listener.newConnectionHandler = { @Sendable connection in
            connection.start(queue: queue)
            receive(on: connection, handler: handler)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { @Sendable state in
                let result: Result<UInt16, Error>?
                switch state {
                case .ready: result = listener.port.map { .success($0.rawValue) } ?? .failure(RAOPError.missingTransport)
                case .failed(let error): result = .failure(error)
                default: result = nil
                }
                guard let result, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
        return UDPServer(listener: listener, port: port)
    }

    private static func receive(on connection: NWConnection, handler: @escaping @Sendable (Data) -> [Data]) {
        connection.receiveMessage { @Sendable data, _, _, error in
            if let data {
                for reply in handler(data) { connection.send(content: reply, completion: .idempotent) }
            }
            if error == nil { receive(on: connection, handler: handler) }
        }
    }

    func stop() {
        listener.cancel()
    }
}

/// The control channel: one UDP socket that both sends sync packets to receivers and
/// answers their resend requests. It has to be one socket: receivers only trust sync
/// packets from the `control_port` Lyra declared in SETUP (as pyatv does it). A BSD
/// socket, because Network.framework can't send unsolicited datagrams from a listener.
final class ControlSocket: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let source: DispatchSourceRead

    /// Bound to `localIP`, the address the RTSP session uses: with two interfaces on one
    /// subnet, an unbound socket may send sync from the other address, which receivers
    /// ignore. `handler` returns replies to a datagram; they go back to its sender.
    init(localIP: String, handler: @escaping @Sendable (Data) -> [Data]) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw RAOPError.unreachable("socket() failed: \(errno)") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, localIP, &address.sin_addr) == 1 else {
            close(fd)
            throw RAOPError.unreachable("bad local address \(localIP)")
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0 else {
            close(fd)
            throw RAOPError.unreachable("bind() failed: \(errno)")
        }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
        source = DispatchSource.makeReadSource(fileDescriptor: fd,
                                               queue: DispatchQueue(label: "com.velpeo.Lyra.control", qos: .userInteractive))
        source.setEventHandler { @Sendable in
            var buffer = [UInt8](repeating: 0, count: 2048)
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength)
                }
            }
            guard count > 0 else { return }
            for reply in handler(Data(buffer[0..<count])) {
                Self.send(reply, fd: fd, to: sender)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    /// Sends from the control port to `host` (IPv4 dotted quad) and `port`.
    func send(_ data: Data, to host: String, port: UInt16) {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return }
        Self.send(data, fd: descriptor, to: address)
    }

    private static func send(_ data: Data, fd: Int32, to address: sockaddr_in) {
        var address = address
        data.withUnsafeBytes { bytes in
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func stop() {
        source.cancel()
    }
}

/// Recently sent audio packets, for receivers that ask for one again. Shared with the
/// control server's thread, hence the lock.
final class PacketHistory: Sendable {
    private let packets = OSAllocatedUnfairLock(initialState: [UInt16: Data]())
    private static let capacity: UInt16 = 1024

    func record(_ packet: Data, sequence: UInt16) {
        packets.withLock { packets in
            packets[sequence] = packet
            packets[sequence &- Self.capacity] = nil
        }
    }

    func packets(from sequence: UInt16, count: UInt16) -> [Data] {
        packets.withLock { packets in
            (0..<min(count, 64)).compactMap { packets[sequence &+ $0] }
        }
    }
}

/// Hands audio from the real-time tap thread to the streamer: the tap pushes, a task
/// drains. Bounded so nothing piles up while no room is listening.
public final class PCMPipe: Sendable {
    private struct Chunk { let samples: [Int16]; let capturedAt: UInt64 }
    private let chunks = OSAllocatedUnfairLock(initialState: [Chunk]())
    private static let maxChunks = 400  // a few seconds of tap callbacks

    public func push(_ samples: [Int16], capturedAt: UInt64) {
        chunks.withLock { chunks in
            if chunks.count >= Self.maxChunks { chunks.removeFirst(chunks.count - Self.maxChunks + 1) }
            chunks.append(Chunk(samples: samples, capturedAt: capturedAt))
        }
    }

    func drain() -> [(samples: [Int16], capturedAt: UInt64)] {
        chunks.withLock { chunks in
            defer { chunks.removeAll(keepingCapacity: true) }
            return chunks.map { ($0.samples, $0.capturedAt) }
        }
    }
}

/// Counts traffic from receivers, so a silent room can be diagnosed from the log.
final class AirPlayTraffic: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (timing: 0, resend: 0, resentPackets: 0))

    func timingRequest() { counts.withLock { $0.timing += 1 } }
    func resendRequest(packets: Int) { counts.withLock { $0.resend += 1; $0.resentPackets += packets } }
    var snapshot: (timing: Int, resend: Int, resentPackets: Int) { counts.withLock { $0 } }
}

/// Lyra's AirPlay 1 sender: one audio stream, one clock, sent to any number of receivers.
///
/// Every frame gets an RTP timestamp and the host time it was captured. Sync packets tell
/// each receiver to play a frame `baseLatency + delay` after its capture time, so rooms
/// line up on one clock and `delay` shifts a single room.
public actor AirPlayStreamer {
    /// How far behind capture every room plays; receivers buffer this much.
    public static let baseLatency: TimeInterval = 1.5
    /// Per-room delay range: earlier or later than the base latency.
    public static let delayRange: ClosedRange<TimeInterval> = -1.5...1.5

    private struct Room {
        let session: RAOPSession
        var volume: Float
        var delay: TimeInterval
        var sentFirstAudio = false
    }

    private static let log = Logger(subsystem: "com.velpeo.Lyra", category: "airplay")
    private let history = PacketHistory()
    private let encoder = try? ALACEncoder()
    /// One format for the whole stream (resend requests don't say who's asking). PCM unless
    /// the first room can only take ALAC.
    private var codec: RAOPCodec = .pcm
    nonisolated let traffic = AirPlayTraffic()
    /// Lyra's music, pushed by the audio tap.
    public nonisolated let input = PCMPipe()
    private var pumpTask: Task<Void, Never>?
    /// A jump this big between where audio should be and where it is means a pause, skip
    /// or stall: flush the rooms and restart the clock rather than play late audio.
    private static let gapTolerance: TimeInterval = 0.25
    private var packetsSent = 0
    private var timing: UDPServer?
    /// One control socket per local address sessions use (usually just one).
    private var controls: [String: ControlSocket] = [:]
    private var rooms: [String: Room] = [:]
    private var connecting: Set<String> = []

    // Stream timeline.
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private var sequence = UInt16.random(in: 0...UInt16.max)
    private let firstTimestamp = UInt32.random(in: 0...UInt32.max)
    private var framesSent: UInt64 = 0
    /// Host time (uptime nanoseconds) of frame `anchorFrame`; nil until audio arrives.
    private var anchor: (frame: UInt64, nanos: UInt64)?
    private var pending: [Int16] = []
    private var syncTask: Task<Void, Never>?
    private var toneTask: Task<Void, Never>?
    /// While set, audio goes to this room only (calibration chirps).
    private var exclusiveRoom: String?
    /// True while a test tone or calibration chirp plays; the music pump holds off.
    private var isPlayingClip = false
    private var serversTask: Task<UInt16, Error>?

    public init() {}

    public var connectedIDs: Set<String> { Set(rooms.keys) }

    // MARK: Rooms

    /// Starts a session with `receiver`; it joins the stream at the current position.
    public func connect(_ receiver: AirPlayReceiver, volume: Float, delay: TimeInterval) async throws {
        // `connecting` covers the awaits below, so a second connect (a Test on a room that's
        // reconnecting) can't open a duplicate session.
        guard rooms[receiver.id] == nil, !connecting.contains(receiver.id) else { return }
        connecting.insert(receiver.id)
        defer { connecting.remove(receiver.id) }
        if rooms.isEmpty { codec = receiver.codecs.first ?? .pcm }
        guard receiver.codecs.contains(codec) else { throw RAOPError.unsupportedFormat }
        let session = RAOPSession(receiver: receiver)
        do {
            let localIP = try await session.open()
            let timingPort = try await servers()
            let control = try controlSocket(for: localIP)
            try await session.start(controlSocket: control, timingPort: timingPort,
                                    sequence: sequence, timestamp: currentTimestamp, volume: volume,
                                    codec: codec, firstSync: syncPacket(delay: delay, isFirst: true))
        } catch {
            await session.stop()
            throw error
        }
        rooms[receiver.id] = Room(session: session, volume: volume, delay: delay)
        startPump()
        startSyncLoop()
    }

    public func disconnect(_ id: String) async {
        guard let room = rooms.removeValue(forKey: id) else { return }
        let traffic = traffic.snapshot
        Self.log.notice("Disconnecting \(room.session.receiver.name, privacy: .public): sent \(self.packetsSent) audio packets; received \(traffic.timing) timing and \(traffic.resend) resend requests (\(traffic.resentPackets) packets resent)")
        await room.session.stop()
        if rooms.isEmpty { stopAll() }
    }

    public func disconnectAll() async {
        for id in rooms.keys { await disconnect(id) }
    }

    public func setVolume(_ volume: Float, for id: String) async {
        guard rooms[id] != nil else { return }
        rooms[id]?.volume = volume
        try? await rooms[id]?.session.setVolume(volume)
    }

    public func setDelay(_ delay: TimeInterval, for id: String) async {
        guard rooms[id] != nil else { return }
        rooms[id]?.delay = delay
        await sendSync(to: id, isFirst: false)
    }

    // MARK: Audio

    /// Adds interleaved 16-bit stereo PCM at 44.1 kHz. `capturedAt` is the uptime
    /// (nanoseconds) of its first frame; it anchors the clock when the stream (re)starts.
    public func enqueue(_ samples: [Int16], capturedAt nanos: UInt64) async {
        if let anchor {
            let frames = Double(framesSent) + Double(pending.count / 2) - Double(anchor.frame)
            let expected = Double(anchor.nanos) + frames / Double(RAOPFormat.sampleRate) * 1e9
            if abs(Double(nanos) - expected) > Self.gapTolerance * 1e9 {
                Self.log.info("Audio jumped \(Int((Double(nanos) - expected) / 1e6)) ms; flushing rooms")
                await flush()
            }
        }
        if anchor == nil { anchor = (framesSent + UInt64(pending.count / 2), nanos) }
        pending += samples
        let packetSamples = RAOPFormat.framesPerPacket * RAOPFormat.channels
        // Take each packet out *before* awaiting: other calls into this actor (the music pump,
        // a test tone, a flush) can run during the await and change `pending`.
        while pending.count >= packetSamples {
            let packet = Array(pending[0..<packetSamples])
            pending.removeFirst(packetSamples)
            await sendPacket(packet[...])
        }
    }

    /// Drops buffered audio everywhere (skip, pause); the next `enqueue` re-anchors the clock.
    public func flush() async {
        pending = []
        anchor = nil
        for room in rooms.values {
            await room.session.flush(sequence: sequence, timestamp: currentTimestamp)
        }
    }

    /// A 440 Hz tone with short fades. `level` is its amplitude, 0…1 of full scale.
    public func playTestTone(seconds: Double = 3, level: Double = 0.18) {
        let total = Int(seconds * Double(RAOPFormat.sampleRate))
        var samples = [Int16]()
        samples.reserveCapacity(total * 2)
        for frame in 0..<total {
            let fade = min(1, Double(min(frame, total - frame)) / 2205)  // 50 ms fades
            let value = Int16(sin(2 * .pi * 440 * Double(frame) / Double(RAOPFormat.sampleRate)) * 32_767 * level * fade)
            samples += [value, value]
        }
        play(samples: samples)
    }

    /// Plays stereo samples paced in real time, to every room or `only` one. Returns the
    /// uptime (ns) its first frame is stamped with: rooms play it `baseLatency + delay` later.
    @discardableResult
    public func play(samples: [Int16], only roomID: String? = nil) -> UInt64 {
        toneTask?.cancel()
        exclusiveRoom = roomID
        isPlayingClip = true
        let start = NTPTime.uptimeNanos()
        toneTask = Task {
            let total = samples.count / 2
            var sent = 0
            while sent < total, !Task.isCancelled {
                let elapsed = Double(NTPTime.uptimeNanos() - start) / 1e9
                let due = min(total, Int(elapsed * Double(RAOPFormat.sampleRate)) + RAOPFormat.framesPerPacket)
                if due > sent {
                    let capturedAt = start + UInt64(Double(sent) / Double(RAOPFormat.sampleRate) * 1e9)
                    await enqueue(Array(samples[(sent * 2)..<(due * 2)]), capturedAt: capturedAt)
                    sent = due
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            // Let the last partial packet out, then go back to every room.
            await enqueue([Int16](repeating: 0, count: RAOPFormat.framesPerPacket * 2),
                          capturedAt: start + UInt64(Double(total) / Double(RAOPFormat.sampleRate) * 1e9))
            exclusiveRoom = nil
            isPlayingClip = false
        }
        return start
    }

    // MARK: Internals

    private var currentTimestamp: UInt32 { firstTimestamp &+ UInt32(truncatingIfNeeded: framesSent) }

    private func sendPacket(_ samples: ArraySlice<Int16>) async {
        let payload: Data
        switch codec {
        case .pcm:
            payload = PCMPayload.encode(samples)
        case .alac:
            // Apple's encoder; the hand-built escape frame is only a fallback.
            payload = (try? encoder?.encode(samples)) ?? ALACEscapeEncoder.encode(samples)
        }
        // Claim this packet's sequence number and timestamp before any await (reentrancy).
        let packetSequence = sequence
        let packet = RAOPPacket.audio(sequence: packetSequence, timestamp: currentTimestamp, ssrc: ssrc,
                                      isFirst: false, payload: payload)
        sequence &+= 1
        framesSent += UInt64(RAOPFormat.framesPerPacket)
        history.record(packet, sequence: packetSequence)
        packetsSent += 1
        for (id, room) in rooms {
            if let exclusiveRoom, exclusiveRoom != id { continue }
            if room.sentFirstAudio {
                await room.session.sendAudio(packet)
            } else {
                var first = packet
                first[first.startIndex + 1] = 0xE0  // marker bit on a session's first packet
                await room.session.sendAudio(first)
                rooms[id]?.sentFirstAudio = true
            }
        }
    }

    /// Tells one receiver when the next frame plays: its capture time plus its latency.
    private func sendSync(to id: String, isFirst: Bool) async {
        guard let room = rooms[id] else { return }
        await room.session.sendControl(syncPacket(delay: room.delay, isFirst: isFirst))
    }

    private func syncPacket(delay: TimeInterval, isFirst: Bool) -> Data {
        let nanos: UInt64
        if let anchor {
            let frames = Double(framesSent) - Double(anchor.frame)
            nanos = anchor.nanos &+ UInt64(max(0, frames / Double(RAOPFormat.sampleRate) * 1e9))
        } else {
            nanos = NTPTime.uptimeNanos()
        }
        let latency = max(0.2, Self.baseLatency + delay)
        return RAOPPacket.sync(timestamp: currentTimestamp, ntp: NTPTime.from(uptimeNanos: nanos),
                               latencyFrames: UInt32(latency * Double(RAOPFormat.sampleRate)), isFirst: isFirst)
    }

    /// Feeds tap audio to the rooms every 10 ms while any room is connected.
    private func startPump() {
        guard pumpTask == nil else { return }
        _ = input.drain()  // drop whatever piled up before a room was listening
        pumpTask = Task {
            while !Task.isCancelled {
                let chunks = input.drain()
                if !isPlayingClip {
                    for chunk in chunks { await enqueue(chunk.samples, capturedAt: chunk.capturedAt) }
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func startSyncLoop() {
        guard syncTask == nil else { return }
        syncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                for id in rooms.keys { await sendSync(to: id, isFirst: false) }
            }
        }
    }

    private func stopAll() {
        syncTask?.cancel()
        syncTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        toneTask?.cancel()
        toneTask = nil
        timing?.stop()
        timing = nil
        for control in controls.values { control.stop() }
        controls = [:]
        pending = []
        anchor = nil
    }

    /// The timing server answers clock requests; the control server resends lost packets.
    /// The timing server answers clock requests on any address; created once, even when
    /// several rooms connect together.
    private func servers() async throws -> UInt16 {
        if let timing { return timing.port }
        if let serversTask { return try await serversTask.value }
        let traffic = traffic
        let task = Task {
            let timing = try await UDPServer.start { request in
                let received = NTPTime.now()
                traffic.timingRequest()
                return RAOPPacket.timingReply(to: request, receivedAt: received, now: NTPTime.now()).map { [$0] } ?? []
            }
            self.setTiming(timing)
            return timing.port
        }
        serversTask = task
        defer { serversTask = nil }
        return try await task.value
    }

    private func setTiming(_ server: UDPServer) {
        timing = server
        Self.log.notice("AirPlay timing server on port \(server.port)")
    }

    /// The control socket for sessions on `localIP`: sends their sync, resends lost packets.
    private func controlSocket(for localIP: String) throws -> ControlSocket {
        if let existing = controls[localIP] { return existing }
        let history = history
        let traffic = traffic
        let control = try ControlSocket(localIP: localIP) { request in
            guard let (sequence, count) = RAOPPacket.resendRequest(request) else { return [] }
            let packets = history.packets(from: sequence, count: count)
            traffic.resendRequest(packets: packets.count)
            return packets.map(RAOPPacket.retransmission(of:))
        }
        controls[localIP] = control
        Self.log.notice("AirPlay control socket on \(localIP, privacy: .public):\(control.port)")
        return control
    }
}
