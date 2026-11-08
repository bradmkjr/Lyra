import Foundation
import os
import UserNotifications

/// Song notifications (replaces Hermes's Growl integration) and the `lyra.song`
/// distributed notification for third-party tools.
@MainActor
public final class NotificationService {
    public static let shared = NotificationService()

    public static let songCategory = "SONG"
    public enum Action: String {
        case like = "LIKE"
        case dislike = "DISLIKE"
        case skip = "SKIP"
    }

    /// Posted on `DistributedNotificationCenter` when a song starts. Sandboxed apps can't attach
    /// `userInfo`, so `object` is a JSON string using Hermes's `hermes.song` keys.
    public static let songDistributedNotification = Notification.Name("lyra.song")

    private static let log = Logger(subsystem: "com.velpeo.Lyra", category: "notifications")
    private var authorization: Task<Bool, Never>?

    private init() {}

    /// Registers the Like/Dislike/Skip actions. Call once at launch.
    public func registerCategories() {
        let actions = [
            UNNotificationAction(identifier: Action.like.rawValue, title: "Like"),
            UNNotificationAction(identifier: Action.dislike.rawValue, title: "Dislike"),
            UNNotificationAction(identifier: Action.skip.rawValue, title: "Skip"),
        ]
        let category = UNNotificationCategory(identifier: Self.songCategory, actions: actions,
                                              intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Shows a notification for `song`, asking for permission the first time.
    public func notify(_ song: Song, resumed: Bool = false) async {
        guard await isAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = song.songName
        content.subtitle = song.artistName
        content.body = resumed ? "Resumed · \(song.albumName)" : song.albumName
        content.categoryIdentifier = Self.songCategory
        content.userInfo = ["trackToken": song.trackToken]
        if let attachment = await artworkAttachment(for: song) {
            content.attachments = [attachment]
        }

        // One identifier, so each song replaces the last instead of piling up.
        let request = UNNotificationRequest(identifier: "lyra.song", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.log.error("Couldn't post notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func broadcast(_ song: Song) {
        var info: [String: Any] = [
            "title": song.songName,
            "artist": song.artistName,
            "album": song.albumName,
            "nrating": song.songRating,
            "token": song.trackToken,
        ]
        info["art"] = song.albumArtUrl?.absoluteString
        info["stationId"] = song.stationId
        info["titleUrl"] = song.songDetailUrl?.absoluteString
        info["artistUrl"] = song.artistDetailUrl?.absoluteString
        info["albumUrl"] = song.albumDetailUrl?.absoluteString
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Self.songDistributedNotification, object: String(decoding: data, as: UTF8.self),
            userInfo: nil, deliverImmediately: true)
    }

    private func isAuthorized() async -> Bool {
        if authorization == nil {
            authorization = Task {
                do {
                    return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                } catch {
                    Self.log.error("Notification permission error: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
        }
        return await authorization!.value
    }

    /// Notification attachments must be local files; the system moves them when added.
    private func artworkAttachment(for song: Song) async -> UNNotificationAttachment? {
        guard let url = song.albumArtUrl,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-art-\(UUID().uuidString).jpg")
        do {
            try data.write(to: file)
            return try UNNotificationAttachment(identifier: "art", url: file)
        } catch {
            return nil
        }
    }
}
