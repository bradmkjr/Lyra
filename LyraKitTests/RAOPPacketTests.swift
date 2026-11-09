import Foundation
import Testing
@testable import LyraKit

struct RAOPPacketTests {
    /// Reads bits back MSB-first to check the ALAC layout.
    private struct BitReader {
        let bytes: [UInt8]
        var position = 0
        mutating func read(_ bits: Int) -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<bits {
                let bit = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
                value = value << 1 | UInt32(bit)
                position += 1
            }
            return value
        }
    }

    @Test func fullALACEscapeFrameRoundTrips() {
        let samples = (0..<(RAOPFormat.framesPerPacket * 2)).map { Int16(truncatingIfNeeded: $0 &* 97 &- 20_000) }
        let frame = ALACEscapeEncoder.encode(samples[...])
        // 3+4+12+4 header bits, 16 bits per sample, 3 end bits, padded to bytes.
        #expect(frame.count == (23 + samples.count * 16 + 3 + 7) / 8)

        var reader = BitReader(bytes: Array(frame))
        #expect(reader.read(3) == 1)   // channel pair element
        #expect(reader.read(4) == 0)
        #expect(reader.read(12) == 0)
        #expect(reader.read(1) == 0)   // full frame, no size
        #expect(reader.read(2) == 0)
        #expect(reader.read(1) == 1)   // escape (uncompressed)
        let decoded = (0..<samples.count).map { _ in Int16(bitPattern: UInt16(reader.read(16))) }
        #expect(decoded == samples)
        #expect(reader.read(3) == 7)   // end element
    }

    @Test func partialFrameCarriesItsLength() {
        let samples = [Int16](repeating: 1000, count: 20)  // 10 frames
        var reader = BitReader(bytes: Array(ALACEscapeEncoder.encode(samples[...])))
        _ = reader.read(19)
        #expect(reader.read(1) == 1)   // partial
        _ = reader.read(3)
        #expect(reader.read(32) == 10)
    }

    @Test func pcmPayloadIsBigEndian() {
        let payload = PCMPayload.encode([0x0102, -2][...])
        #expect(Array(payload) == [0x01, 0x02, 0xFF, 0xFE])
        let full = PCMPayload.encode([Int16](repeating: 0, count: RAOPFormat.framesPerPacket * 2)[...])
        #expect(full.count == 1408)
    }

    @Test func audioPacketHeader() {
        let packet = RAOPPacket.audio(sequence: 0x1234, timestamp: 0xA1B2C3D4, ssrc: 7, isFirst: true, payload: Data([9]))
        #expect(Array(packet) == [0x80, 0xE0, 0x12, 0x34, 0xA1, 0xB2, 0xC3, 0xD4, 0, 0, 0, 7, 9])
        let later = RAOPPacket.audio(sequence: 1, timestamp: 0, ssrc: 0, isFirst: false, payload: Data())
        #expect(later[1] == 0x60)
    }

    @Test func syncPacketMapsTimestampAndLatency() {
        let ntp: UInt64 = 0x0102_0304_0506_0708
        let packet = RAOPPacket.sync(timestamp: 100_000, ntp: ntp, latencyFrames: 88_200, isFirst: true)
        #expect(packet.count == 20)
        #expect(Array(packet.prefix(4)) == [0x90, 0xD4, 0x00, 0x07])
        #expect(packet.bigEndian(UInt32.self, at: 4) == 100_000 - 88_200)
        #expect(packet.bigEndian(UInt64.self, at: 8) == ntp)
        #expect(packet.bigEndian(UInt32.self, at: 16) == 100_000)
        // Latency larger than the timestamp wraps, as RTP timestamps do.
        let early = RAOPPacket.sync(timestamp: 10, ntp: 0, latencyFrames: 20, isFirst: false)
        #expect(early.bigEndian(UInt32.self, at: 4) == UInt32.max - 9)
        #expect(early[0] == 0x80)
    }

    @Test func timingReplyEchoesTransmitTime() throws {
        var request = Data([0x80, 0xD2, 0x00, 0x07, 0, 0, 0, 0])
        request.appendBigEndian(UInt64(1))
        request.appendBigEndian(UInt64(2))
        request.appendBigEndian(UInt64(0xAABB_CCDD_EEFF_0011))
        let reply = try #require(RAOPPacket.timingReply(to: request, receivedAt: 5, now: 6))
        #expect(Array(reply.prefix(4)) == [0x80, 0xD3, 0x00, 0x07])
        #expect(reply.bigEndian(UInt64.self, at: 8) == 0xAABB_CCDD_EEFF_0011)
        #expect(reply.bigEndian(UInt64.self, at: 16) == 5)
        #expect(reply.bigEndian(UInt64.self, at: 24) == 6)
        #expect(RAOPPacket.timingReply(to: Data([0x80, 0xD4]), receivedAt: 0, now: 0) == nil)
    }

    @Test func resendRequestParsing() throws {
        let request = Data([0x80, 0xD5, 0x00, 0x01, 0x12, 0x34, 0x00, 0x03])
        let parsed = try #require(RAOPPacket.resendRequest(request))
        #expect(parsed.sequence == 0x1234)
        #expect(parsed.count == 3)
        #expect(Array(RAOPPacket.retransmission(of: Data([1, 2])).prefix(4)) == [0x80, 0xD6, 0x00, 0x01])
    }

    @Test func ntpTimeIsMonotonicAndFixedPoint() {
        #expect(NTPTime.fixedPoint(nanos: 1_500_000_000) == (1 << 32) | (1 << 31))
        let start = NTPTime.uptimeNanos()
        let a = NTPTime.from(uptimeNanos: start)
        let b = NTPTime.from(uptimeNanos: start + 2_000_000_000)
        // Each conversion truncates its fraction, so allow one unit (~0.2 ns).
        #expect((b - a).distance(to: 2 << 32).magnitude <= 1)
        // Plausible wall clock: after 2020 in NTP seconds.
        #expect(a >> 32 > 3_786_825_600)
    }

    @Test func rtspResponseParsing() throws {
        let raw = Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: 1\r\nTransport: RTP/AVP/UDP;unicast;mode=record;server_port=6000;control_port=6001;timing_port=6002\r\nContent-Length: 2\r\n\r\nhiEXTRA".utf8)
        let (response, length) = try #require(RTSPResponse.parse(raw))
        #expect(response.status == 200)
        #expect(response.headers["cseq"] == "3")
        #expect(response.body == Data("hi".utf8))
        #expect(length == raw.count - 5)
        #expect(response.transport["server_port"] == "6000")
        #expect(response.transport["control_port"] == "6001")
        #expect(RTSPResponse.parse(Data("RTSP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhi".utf8)) == nil)
    }

    @Test func requestAndSDPFormatting() {
        let request = RTSPRequest.encode(method: "SET_PARAMETER", uri: "rtsp://10.0.0.2/1",
                                         headers: [("CSeq", "4")], body: Data("volume: -15.000000\r\n".utf8))
        let text = String(decoding: request, as: UTF8.self)
        #expect(text.hasPrefix("SET_PARAMETER rtsp://10.0.0.2/1 RTSP/1.0\r\nCSeq: 4\r\nContent-Length: 20\r\n\r\nvolume"))
        let sdp = String(decoding: RTSPRequest.announceSDP(sessionID: 42, localIP: "10.0.0.2", remoteIP: "10.0.0.9", codec: .pcm),
                         as: UTF8.self)
        #expect(sdp.contains("o=iTunes 42 0 IN IP4 10.0.0.2\r\n"))
        #expect(sdp.contains("a=rtpmap:96 L16/44100/2\r\n"))
        let alac = String(decoding: RTSPRequest.announceSDP(sessionID: 42, localIP: "10.0.0.2", remoteIP: "10.0.0.9", codec: .alac),
                          as: UTF8.self)
        #expect(alac.contains("a=rtpmap:96 AppleLossless\r\n"))
        #expect(sdp.contains("a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100\r\n"))
        #expect(RTSPRequest.volumeDB(0) == -144)
        #expect(RTSPRequest.volumeDB(1) == 0)
        #expect(RTSPRequest.volumeDB(0.5) == -15)
    }
}

struct ALACEncoderTests {
    @Test func encodesOnePacketSmallerThanRaw() throws {
        let encoder = try ALACEncoder()
        let tone = (0..<RAOPFormat.framesPerPacket).flatMap { frame -> [Int16] in
            let value = Int16(sin(Double(frame) / 10) * 8000)
            return [value, value]
        }
        let packet = try encoder.encode(tone[...])
        #expect(!packet.isEmpty)
        #expect(packet.count < tone.count * 2)  // compressed below raw PCM
        let silence = try encoder.encode([Int16](repeating: 0, count: tone.count)[...])
        #expect(silence.count < 64)
    }
}

struct CalibrationTests {
    @Test func findsChirpInNoisyRecording() throws {
        let rate = 48_000.0
        let template = RoomCalibration.chirp(sampleRate: rate)
        var generator = SystemRandomNumberGenerator()
        var recording = (0..<Int(rate * 2)).map { _ in Float.random(in: -0.05...0.05, using: &generator) }
        let offset = 37_123
        for (index, sample) in template.enumerated() { recording[offset + index] += sample * 0.2 }
        let found = try #require(ArrivalDetector.find(template, in: recording, range: 20_000..<60_000))
        #expect(abs(found - offset) <= 2)
    }

    @Test func silenceIsNotAnArrival() {
        let template = RoomCalibration.chirp(sampleRate: 48_000)
        let quiet = (0..<96_000).map { _ in Float.random(in: -0.05...0.05) }
        #expect(ArrivalDetector.find(template, in: quiet, range: 0..<80_000) == nil)
    }

    @Test func chirpTrainSpacing() {
        let train = RoomCalibration.chirpTrain(sampleRate: 1000)
        #expect(train.count == 1000 * 2 + 250)
    }
}
