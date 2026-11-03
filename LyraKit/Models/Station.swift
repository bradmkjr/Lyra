import Foundation

public struct Station: Sendable, Hashable, Identifiable, Codable {
    public var id: String { stationId }
    public let stationId: String
    public let stationToken: String
    public var stationName: String
    public var isQuickMix: Bool?
    public var dateCreated: PandoraDate?

    public init(stationId: String, stationToken: String, stationName: String) {
        self.stationId = stationId
        self.stationToken = stationToken
        self.stationName = stationName
    }
}

/// Pandora encodes dates as `{ "time": <ms since epoch>, ... }`.
public struct PandoraDate: Sendable, Hashable, Codable {
    public let time: Int64
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(time) / 1000) }
}
