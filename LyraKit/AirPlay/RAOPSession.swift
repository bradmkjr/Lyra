import Foundation
import Network
import os

public enum RAOPError: LocalizedError, Equatable {
    case connectionClosed
    case unreachable(String)
    case status(method: String, code: Int)
    case missingTransport
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .connectionClosed: "The receiver closed the connection."
        case .unreachable(let detail): "Couldn't reach the receiver (\(detail))."
        case .status(_, 403): "The receiver refused AirPlay. On a Mac, set AirPlay Receiver to allow anyone on the same network."
        case .status(_, 453): "The receiver is busy playing from another device."
        case .status(let method, let code): "The receiver rejected \(method) (RTSP \(code))."
        case .missingTransport: "The receiver didn't say where to send audio."
        case .unsupportedFormat: "This receiver can't take the audio format the other rooms are using."
        }
    }
}

/// Resumes a continuation once, even if several callbacks race to finish it.
private final class ResumeOnce: Sendable {
    private let done = OSAllocatedUnfairLock(initialState: false)
    func claim() -> Bool { done.withLock { done in defer { done = true }; return !done } }
}

/// The RTSP control channel to one receiver (TCP, request/response).
actor RTSPConnection {
    private let connection: NWConnection
    private var buffer = Data()
    private var cseq = 0
    private var session: String?
    private let clientInstance = (0..<8).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
    private let activeRemote = String(UInt32.random(in: 1...UInt32.max))
    // No X-Apple-Client-Name: with a non-ASCII computer name ("Bradford’s") every receiver
    // went silent after adding it. Revisit with an ASCII-only name once playback is solid.

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // IPv4 keeps the SDP and UDP addressing simple; every receiver here has one.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        connection = NWConnection(to: endpoint, using: parameters)
    }

    /// Connects; returns this Mac's address and the receiver's, as seen on this connection.
    func open() async throws -> (local: NWEndpoint.Host, remote: NWEndpoint.Host) {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { @Sendable state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: RAOPError.unreachable(error.localizedDescription)) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: RAOPError.connectionClosed) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        guard case .hostPort(let local, _)? = connection.currentPath?.localEndpoint,
              case .hostPort(let remote, _)? = connection.currentPath?.remoteEndpoint else {
            throw RAOPError.unreachable("no address")
        }
        return (local, remote)
    }

    func setSession(_ value: String?) {
        // "Session: DEADBEEF;timeout=60" → "DEADBEEF"
        session = value?.split(separator: ";").first.map(String.init)
    }

    func request(_ method: String, uri: String, headers extra: [(String, String)] = [],
                 contentType: String? = nil, body: Data? = nil) async throws -> RTSPResponse {
        cseq += 1
        var headers: [(String, String)] = [
            ("CSeq", String(cseq)),
            ("User-Agent", "AirPlay/550.10"),
            ("Client-Instance", clientInstance),
            ("DACP-ID", clientInstance),
            ("Active-Remote", activeRemote),
        ]
        if let session { headers.append(("Session", session)) }
        if let contentType { headers.append(("Content-Type", contentType)) }
        headers += extra
        try await send(RTSPRequest.encode(method: method, uri: uri, headers: headers, body: body))
        while true {
            if let (response, length) = RTSPResponse.parse(buffer) {
                buffer = buffer.subdata(in: (buffer.startIndex + length)..<buffer.endIndex)
                return response
            }
            buffer.append(try await receive())
        }
    }

    func close() {
        connection.cancel()
    }

    private func send(_ data: Data) async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receive() async throws -> Data {
        let connection = connection
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { @Sendable data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: RAOPError.connectionClosed)
                }
            }
        }
    }
}

/// One AirPlay 1 session: RTSP control plus UDP audio and control channels to a receiver.
actor RAOPSession {
    let receiver: AirPlayReceiver
    private let rtsp: RTSPConnection
    private var uri = ""
    private var audio: NWConnection?
    private var controlSocket: ControlSocket?
    private var endpoints: (local: NWEndpoint.Host, remote: NWEndpoint.Host)?
    /// Where this receiver wants sync packets: its IPv4 address and control port.
    private var controlDestination: (host: String, port: UInt16)?
    private static let log = Logger(subsystem: "com.velpeo.Lyra", category: "airplay")

    init(receiver: AirPlayReceiver) {
        self.receiver = receiver
        rtsp = RTSPConnection(endpoint: receiver.endpoint)
    }

    /// Connects and starts recording at `sequence`/`timestamp`. Lyra's UDP servers listen
    /// on `controlPort` (resend requests) and `timingPort` (clock requests). The sequence
    /// mirrors pyatv's working sender: first sync before RECORD, then FLUSH to set the start.
    /// Opens the RTSP connection; returns this Mac's address on it, so the control socket
    /// can be bound to the same address.
    func open() async throws -> String {
        let (local, remote) = try await rtsp.open()
        endpoints = (local, remote)
        return Self.address(local)
    }

    func start(controlSocket: ControlSocket, timingPort: UInt16, sequence: UInt16, timestamp: UInt32, volume: Float,
               codec: RAOPCodec, firstSync: Data) async throws {
        guard let (local, remote) = endpoints else { throw RAOPError.connectionClosed }
        let localIP = Self.address(local)
        let controlPort = controlSocket.port
        self.controlSocket = controlSocket
        let sessionID = UInt32.random(in: 1...UInt32.max)
        uri = "rtsp://\(localIP)/\(sessionID)"

        try await check("OPTIONS", rtsp.request("OPTIONS", uri: "*"))
        _ = try? await rtsp.request("GET", uri: "/info")
        try await check("ANNOUNCE", rtsp.request(
            "ANNOUNCE", uri: uri, contentType: "application/sdp",
            body: RTSPRequest.announceSDP(sessionID: sessionID, localIP: localIP, remoteIP: Self.address(remote),
                                          codec: codec)))
        let setup = try await check("SETUP", rtsp.request("SETUP", uri: uri, headers: [
            ("Transport", "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(controlPort);timing_port=\(timingPort)"),
        ]))
        guard let serverPort = setup.transport["server_port"].flatMap(UInt16.init),
              let receiverControl = setup.transport["control_port"].flatMap(UInt16.init) else {
            throw RAOPError.missingTransport
        }
        await rtsp.setSession(setup.headers["session"])
        audio = Self.udp(to: remote, port: serverPort, from: local)
        controlDestination = (Self.address(remote), receiverControl)

        sendControl(firstSync)
        _ = try? await rtsp.request("POST", uri: "/feedback")
        try await check("RECORD", rtsp.request("RECORD", uri: uri))
        try await check("FLUSH", rtsp.request("FLUSH", uri: uri, headers: [
            ("Range", "npt=0-"),
            ("RTP-Info", "seq=\(sequence);rtptime=\(timestamp)"),
        ]))
        try await setVolume(volume)
        Self.log.notice("AirPlay session started with \(self.receiver.name, privacy: .public) (audio port \(serverPort))")
    }

    func setVolume(_ volume: Float) async throws {
        let body = String(format: "volume: %.6f\r\n", RTSPRequest.volumeDB(volume))
        try await check("SET_PARAMETER", rtsp.request("SET_PARAMETER", uri: uri, contentType: "text/parameters",
                                                     body: Data(body.utf8)))
    }

    /// Drops buffered audio (skip/pause); playback resumes at `sequence`/`timestamp`.
    func flush(sequence: UInt16, timestamp: UInt32) async {
        _ = try? await rtsp.request("FLUSH", uri: uri, headers: [("RTP-Info", "seq=\(sequence);rtptime=\(timestamp)")])
    }

    func stop() async {
        _ = try? await rtsp.request("TEARDOWN", uri: uri)
        audio?.cancel()
        await rtsp.close()
        Self.log.notice("AirPlay session ended with \(self.receiver.name, privacy: .public)")
    }

    func sendAudio(_ packet: Data) {
        audio?.send(content: packet, completion: .idempotent)
    }

    func sendControl(_ packet: Data) {
        guard let controlDestination else { return }
        controlSocket?.send(packet, to: controlDestination.host, port: controlDestination.port)
    }

    @discardableResult
    private func check(_ method: String, _ response: RTSPResponse) throws -> RTSPResponse {
        guard response.status == 200 else {
            Self.log.error("\(self.receiver.name, privacy: .public) rejected \(method, privacy: .public): \(response.status)")
            throw RAOPError.status(method: method, code: response.status)
        }
        return response
    }

    private static func address(_ host: NWEndpoint.Host) -> String {
        // Scoped addresses print as "fe80::1%en0"; the scope isn't part of the address.
        String("\(host)".split(separator: "%").first ?? "")
    }

    /// Audio and sync must come from the same address as the RTSP session: on a Mac with two
    /// interfaces on one subnet, macOS may otherwise send them from the other address, and
    /// the receiver discards packets from a source it doesn't have a session with.
    private static func udp(to host: NWEndpoint.Host, port: UInt16, from local: NWEndpoint.Host) -> NWConnection {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: local, port: .any)
        let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        connection.start(queue: .global(qos: .userInteractive))
        return connection
    }
}
