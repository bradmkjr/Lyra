import Foundation

public struct Station: Sendable, Hashable, Identifiable, Decodable {
    public var id: String { stationId }
    public let stationId: String
    public let stationToken: String
    public var stationName: String
    public var isQuickMix: Bool?
    public var isShared: Bool?
    public var allowRename: Bool?
    public var allowAddMusic: Bool?
    public var allowDelete: Bool?
    public var dateCreated: PandoraDate?

    public init(stationId: String, stationToken: String, stationName: String,
                isQuickMix: Bool? = nil, dateCreated: PandoraDate? = nil) {
        self.stationId = stationId
        self.stationToken = stationToken
        self.stationName = stationName
        self.isQuickMix = isQuickMix
        self.dateCreated = dateCreated
    }

    /// Hermes shows the QuickMix station as "Shuffle".
    public var displayName: String { isQuickMix == true ? "Shuffle" : stationName }
    public var canRename: Bool { allowRename ?? (isQuickMix != true) }
    public var canEdit: Bool { allowAddMusic ?? (isQuickMix != true) }
}

/// Pandora encodes dates as `{ "time": <ms since epoch>, ... }`.
public struct PandoraDate: Sendable, Hashable, Codable {
    public let time: Int64
    public init(time: Int64) { self.time = time }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(time) / 1000) }
}
