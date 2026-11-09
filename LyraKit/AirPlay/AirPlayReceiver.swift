import Foundation
import Network
import SystemConfiguration

/// An AirPlay 1 (RAOP) receiver found on the network: Apple TV, AirPlay stereo, or a Mac
/// with AirPlay Receiver turned on. Lyra streams to these itself (see `AirPlayStreamer`).
public struct AirPlayReceiver: Sendable, Hashable, Identifiable {
    /// The device's MAC address from its `MAC@Name` service name; stable across launches.
    public let id: String
    public let name: String
    public let model: String?
    /// The `_raop._tcp` Bonjour service to connect to.
    let endpoint: NWEndpoint
    let txt: [String: String]

    /// `pw=true`: the receiver wants a password Lyra doesn't support yet.
    public var requiresPassword: Bool { txt["pw"] == "true" }

    /// Lyra sends unencrypted (`et` 0) audio as PCM (`cn` 0) or Apple Lossless (`cn` 1).
    public var isSupported: Bool {
        let encryption = (txt["et"] ?? "0").split(separator: ",")
        return encryption.contains("0") && !codecs.isEmpty && !requiresPassword
    }

    /// Formats this receiver takes, PCM first since that's what Apple TVs actually play.
    var codecs: [RAOPCodec] {
        let listed = (txt["cn"] ?? "0,1").split(separator: ",")
        return [listed.contains("0") ? .pcm : nil, listed.contains("1") ? .alac : nil].compactMap { $0 }
    }

    public var systemImage: String {
        let model = model ?? ""
        if model.hasPrefix("AppleTV") { return "appletv" }
        if model.hasPrefix("AudioAccessory") { return "homepod" }
        if model.hasPrefix("Mac") { return "laptopcomputer" }
        return "hifispeaker"
    }

    init?(serviceName: String, endpoint: NWEndpoint, txt: [String: String]) {
        let parts = serviceName.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        id = String(parts[0])
        name = String(parts[1])
        model = txt["am"]
        self.endpoint = endpoint
        self.txt = txt
    }
}

/// Finds AirPlay receivers with Bonjour and reports the current list on the main actor.
@MainActor
public final class AirPlayBrowser {
    private let onChange: @MainActor ([AirPlayReceiver]) -> Void
    private var browser: NWBrowser?

    public init(onChange: @escaping @MainActor ([AirPlayReceiver]) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_raop._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = Self.makeHandler { [weak self] receivers in
            self?.onChange(receivers)
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Nonisolated so the handler isn't main-actor isolated (Network calls it on its queue).
    private nonisolated static func makeHandler(
        _ report: @escaping @Sendable @MainActor ([AirPlayReceiver]) -> Void
    ) -> @Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void {
        { results, _ in
            let receivers = parse(results)
            Task { @MainActor in report(receivers) }
        }
    }

    /// One entry per device (a receiver shows up once per network interface), excluding this Mac.
    nonisolated static func parse(_ results: Set<NWBrowser.Result>) -> [AirPlayReceiver] {
        let thisMac = SCDynamicStoreCopyComputerName(nil, nil) as String?
        var byID: [String: AirPlayReceiver] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            guard let receiver = AirPlayReceiver(serviceName: name, endpoint: result.endpoint, txt: txt),
                  receiver.name != thisMac else { continue }
            byID[receiver.id] = byID[receiver.id] ?? receiver
        }
        return byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
