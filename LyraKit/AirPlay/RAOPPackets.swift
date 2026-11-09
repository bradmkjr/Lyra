import Foundation

// AirPlay 1 (RAOP) wire formats. References: shairport-sync, OwnTone and libraop, which
// document the protocol iTunes used; Apple's ALAC encoder for the frame layout.

/// How audio is carried. AirPlay 1 receivers list what they take in `cn`: 0 = PCM, 1 = ALAC.
enum RAOPCodec: String, Sendable {
    /// Raw 16-bit big-endian PCM. What pyatv sends and what Apple TV 3s play.
    case pcm
    /// Apple Lossless, from macOS's encoder; only for receivers without PCM.
    case alac

    var rtpmap: String {
        switch self {
        case .pcm: "L16/\(RAOPFormat.sampleRate)/\(RAOPFormat.channels)"
        case .alac: "AppleLossless"
        }
    }
}

/// RAOP audio is 44.1 kHz, 16-bit, stereo, in packets of 352 frames.
enum RAOPFormat {
    static let sampleRate = 44_100
    static let channels = 2
    static let framesPerPacket = 352
}

// MARK: - Clock

/// NTP-format (32.32 fixed point, seconds since 1900) time on a monotonic base. Receivers
/// sync to whatever clock Lyra answers their timing requests with, so it only has to be
/// steady, not exact wall-clock time.
enum NTPTime {
    private static let unixToNTPSeconds: UInt64 = 2_208_988_800
    private static let reference: (uptime: UInt64, ntp: UInt64) = {
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let unixNanos = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        return (uptime, fixedPoint(nanos: unixNanos) &+ (unixToNTPSeconds << 32))
    }()

    /// Monotonic nanoseconds; the time base for every timestamp Lyra hands out.
    static func uptimeNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func now() -> UInt64 { from(uptimeNanos: uptimeNanos()) }

    static func from(uptimeNanos: UInt64) -> UInt64 {
        if uptimeNanos >= reference.uptime {
            return reference.ntp &+ fixedPoint(nanos: uptimeNanos - reference.uptime)
        }
        return reference.ntp &- fixedPoint(nanos: reference.uptime - uptimeNanos)
    }

    static func fixedPoint(nanos: UInt64) -> UInt64 {
        let seconds = nanos / 1_000_000_000
        let fraction = ((nanos % 1_000_000_000) << 32) / 1_000_000_000
        return seconds << 32 | fraction
    }
}

// MARK: - Audio payload

/// Raw 16-bit PCM (`L16`), the plainest AirPlay 1 payload: every receiver lists `cn=0`.
/// pyatv's working sender does the same. Samples go out big-endian.
enum PCMPayload {
    static func encode(_ samples: ArraySlice<Int16>) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples { data.appendBigEndian(sample) }
        return data
    }
}

// MARK: - Apple Lossless

/// Writes bits most-significant first, as ALAC expects.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: UInt32, bits: Int) {
        for shift in stride(from: bits - 1, through: 0, by: -1) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if (value >> UInt32(shift)) & 1 == 1 {
                bytes[bytes.count - 1] |= UInt8(0x80 >> (bitCount % 8))
            }
            bitCount += 1
        }
    }
}

/// Encodes PCM as ALAC "escape" (uncompressed) frames. Kept for receivers that only take
/// ALAC (`cn` without 0); the macOS receiver stayed silent with these, so Lyra prefers L16.
enum ALACEscapeEncoder {
    private static let channelPairElement: UInt32 = 1
    private static let endElement: UInt32 = 7

    /// `samples` is interleaved stereo (L, R, L, R…), at most 352 frames.
    static func encode(_ samples: ArraySlice<Int16>) -> Data {
        let frames = samples.count / RAOPFormat.channels
        let isPartial = frames != RAOPFormat.framesPerPacket
        var writer = BitWriter()
        writer.write(channelPairElement, bits: 3)
        writer.write(0, bits: 4)   // element instance tag
        writer.write(0, bits: 12)  // unused
        writer.write(isPartial ? 1 : 0, bits: 1)
        writer.write(0, bits: 2)   // bytes shifted
        writer.write(1, bits: 1)   // escape: samples follow uncompressed
        if isPartial { writer.write(UInt32(frames), bits: 32) }
        for sample in samples {
            writer.write(UInt32(UInt16(bitPattern: sample)), bits: 16)
        }
        writer.write(endElement, bits: 3)
        return Data(writer.bytes)
    }
}

// MARK: - RTP packets

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func bigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value = value << 8 | T(self[startIndex + offset + index])
        }
        return value
    }
}

enum RAOPPacket {
    /// Audio data, sent to the receiver's server port.
    static func audio(sequence: UInt16, timestamp: UInt32, ssrc: UInt32, isFirst: Bool, payload: Data) -> Data {
        var packet = Data([0x80, isFirst ? 0xE0 : 0x60])
        packet.appendBigEndian(sequence)
        packet.appendBigEndian(timestamp)
        packet.appendBigEndian(ssrc)
        packet.append(payload)
        return packet
    }

    /// Sync, sent to the receiver's control port about once a second: "at NTP time `ntp`,
    /// frame `timestamp` was current; play it `latencyFrames` later". Per-receiver delay is
    /// just a different `latencyFrames`.
    static func sync(timestamp: UInt32, ntp: UInt64, latencyFrames: UInt32, isFirst: Bool) -> Data {
        var packet = Data([isFirst ? 0x90 : 0x80, 0xD4, 0x00, 0x07])
        packet.appendBigEndian(timestamp &- latencyFrames)
        packet.appendBigEndian(ntp)
        packet.appendBigEndian(timestamp)
        return packet
    }

    /// Reply to a receiver's timing request (`0xD2`), NTP-style.
    static func timingReply(to request: Data, receivedAt received: UInt64, now: UInt64) -> Data? {
        guard request.count >= 32, request[request.startIndex + 1] & 0x7F == 0x52 else { return nil }
        var packet = Data([0x80, 0xD3, 0x00, 0x07, 0, 0, 0, 0])
        packet.appendBigEndian(request.bigEndian(UInt64.self, at: 24))  // their transmit time
        packet.appendBigEndian(received)
        packet.appendBigEndian(now)
        return packet
    }

    /// A receiver's resend request (`0xD5`): first missing sequence number and count.
    static func resendRequest(_ packet: Data) -> (sequence: UInt16, count: UInt16)? {
        guard packet.count >= 8, packet[packet.startIndex + 1] & 0x7F == 0x55 else { return nil }
        return (packet.bigEndian(UInt16.self, at: 4), packet.bigEndian(UInt16.self, at: 6))
    }

    /// A resent audio packet, wrapped for the control port.
    static func retransmission(of audioPacket: Data) -> Data {
        var packet = Data([0x80, 0xD6, 0x00, 0x01])
        packet.append(audioPacket)
        return packet
    }
}

// MARK: - RTSP

struct RTSPResponse: Sendable {
    let status: Int
    /// Header names lowercased.
    let headers: [String: String]
    let body: Data

    /// Parses one response from the front of `buffer`; nil until it's complete.
    static func parse(_ buffer: Data) -> (response: RTSPResponse, length: Int)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("RTSP/"), let status = Int(statusLine[1]) else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headerEnd.upperBound - buffer.startIndex
        let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count >= bodyStart + bodyLength else { return nil }
        let body = buffer.subdata(in: (buffer.startIndex + bodyStart)..<(buffer.startIndex + bodyStart + bodyLength))
        return (RTSPResponse(status: status, headers: headers, body: body), bodyStart + bodyLength)
    }

    /// `Transport: RTP/AVP/UDP;unicast;server_port=6000;control_port=6001;…` as a dictionary.
    var transport: [String: String] {
        var values: [String: String] = [:]
        for part in (headers["transport"] ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
        }
        return values
    }
}

enum RTSPRequest {
    static func encode(method: String, uri: String, headers: [(String, String)], body: Data? = nil) -> Data {
        var text = "\(method) \(uri) RTSP/1.0\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if let body { text += "Content-Length: \(body.count)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        if let body { data.append(body) }
        return data
    }

    /// SDP for ANNOUNCE: unencrypted audio in `codec`, 352 frames per packet, 44.1 kHz stereo.
    static func announceSDP(sessionID: UInt32, localIP: String, remoteIP: String, codec: RAOPCodec) -> Data {
        let family = localIP.contains(":") ? "IP6" : "IP4"
        let sdp = [
            "v=0",
            "o=iTunes \(sessionID) 0 IN \(family) \(localIP)",
            "s=iTunes",
            "c=IN \(family) \(remoteIP)",
            "t=0 0",
            "m=audio 0 RTP/AVP 96",
            "a=rtpmap:96 \(codec.rtpmap)",
            "a=fmtp:96 \(RAOPFormat.framesPerPacket) 0 16 40 10 14 2 255 0 0 \(RAOPFormat.sampleRate)",
        ].joined(separator: "\r\n") + "\r\n"
        return Data(sdp.utf8)
    }

    /// AirPlay 1 volume in dB: -30 (quietest) to 0 (full); -144 mutes.
    static func volumeDB(_ volume: Float) -> Float {
        volume <= 0 ? -144 : -30 + 30 * min(volume, 1)
    }
}
