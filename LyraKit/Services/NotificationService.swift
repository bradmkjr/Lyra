import UserNotifications
import Foundation
import Observation

/// Service for handling system notifications and distributed notifications
@MainActor
@Observable
public final class NotificationService {
    public static let shared = NotificationService()
    
    private init() {
        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
    
    /// Show a new song notification
    public func showSongNotification(songName: String, artistName: String) {
        let content = UNMutableNotificationContent()
        content.title = songName
        content.body = artistName
        content.subtitle = "Now Playing"
        content.sound = .default
        
        // Create the notification request
        let request = UNNotificationRequest(
            identifier: "song.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to add notification: \(error)")
            }
        }
    }
    
    /// Send distributed notification for 3rd-party tools (compatible with Hermes)
    public func sendDistributedNotification(songName: String, artistName: String, albumName: String) {
        let userInfo: [String: Any] = [
            "event": "song",
            "song": songName,
            "artist": artistName,
            "album": albumName
        ]
        
        // Post notification to distributed notification center (for 3rd party tools)
        DistributedNotificationCenter.default().post(
            name: Notification.Name("lyra.song"),
            object: nil,
            userInfo: userInfo
        )
    }
    
    /// Setup notification categories
    public func setupNotificationCategories() {
        let likeAction = UNNotificationAction(
            identifier: "LIKE",
            title: "Like",
            options: [.destructive]
        )
        
        let dislikeAction = UNNotificationAction(
            identifier: "DISLIKE",
            title: "Dislike",
            options: [.destructive]
        )
        
        let skipAction = UNNotificationAction(
            identifier: "SKIP",
            title: "Skip",
            options: []
        )
        
        let category = UNNotificationCategory(
            identifier: "SONG_NOTIFICATION",
            actions: [likeAction, dislikeAction, skipAction],
            intentIdentifiers: [],
            options: []
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}