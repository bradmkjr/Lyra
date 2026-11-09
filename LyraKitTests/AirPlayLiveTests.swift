import Foundation
import Network
import Testing
@testable import LyraKit

/// Plays a test tone on real receivers. Skipped unless receivers are named; separate
/// several with "|" to check multi-room sync, e.g.:
///   TEST_RUNNER_LYRA_AIRPLAY_TARGET='B8782E336332@Great Room Apple TV|5855CA2D32A9@Family Room Apple TV' make test
struct AirPlayLiveTests {
    private static let target = ProcessInfo.processInfo.environment["LYRA_AIRPLAY_TARGET"]

    @Test(.enabled(if: target != nil))
    func testToneReachesReceiver() async throws {
        let names = try #require(Self.target).split(separator: "|").map(String.init)
        let receivers = try names.map { name in
            let endpoint = NWEndpoint.service(name: name, type: "_raop._tcp", domain: "local.", interface: nil)
            return try #require(AirPlayReceiver(serviceName: name, endpoint: endpoint, txt: ["et": "0", "cn": "0,1"]))
        }
        let streamer = AirPlayStreamer()

        for receiver in receivers {
            try await streamer.connect(receiver, volume: 0.5, delay: 0)
            print("LIVE connected \(receiver.name)")
        }
        // 9 s of a fairly loud tone, stepping the receiver's volume: 50%, 80%, 100%.
        await streamer.playTestTone(seconds: 9, level: 0.5)
        for volume: Float in [0.5, 0.8, 1.0] {
            print("LIVE volume \(volume) at \(Date().formatted(date: .omitted, time: .standard))")
            for receiver in receivers { await streamer.setVolume(volume, for: receiver.id) }
            try await Task.sleep(for: .seconds(3))
        }
        try await Task.sleep(for: .seconds(3))
        let traffic = streamer.traffic.snapshot
        for receiver in receivers { await streamer.disconnect(receiver.id) }

        print("LIVE timing requests: \(traffic.timing), resend requests: \(traffic.resend), packets resent: \(traffic.resentPackets)")
        #expect(traffic.timing > 0, "The receiver never asked Lyra for the time.")
    }
}
