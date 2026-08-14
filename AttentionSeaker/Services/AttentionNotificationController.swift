import AppKit
import Foundation
import UserNotifications

struct AttentionNotificationPreferences: Equatable, Sendable {
    var issueReasons: AttentionReason
    var pullRequestReasons: AttentionReason

    static let none = AttentionNotificationPreferences(issueReasons: [], pullRequestReasons: [])

    var isEmpty: Bool {
        issueReasons.isEmpty && pullRequestReasons.isEmpty
    }

    func reasons(for kind: AttentionKind) -> AttentionReason {
        switch kind {
        case .issue:
            return issueReasons
        case .pullRequest:
            return pullRequestReasons
        }
    }

    func matchingReasons(kind: AttentionKind, itemReasons: AttentionReason) -> AttentionReason {
        reasons(for: kind).intersection(itemReasons)
    }

    func isEnabled(kind: AttentionKind, reason: AttentionReason) -> Bool {
        reasons(for: kind).contains(reason)
    }

    mutating func setEnabled(_ enabled: Bool, kind: AttentionKind, reason: AttentionReason) {
        switch kind {
        case .issue:
            if enabled {
                issueReasons.insert(reason)
            } else {
                issueReasons.remove(reason)
            }
        case .pullRequest:
            if enabled {
                pullRequestReasons.insert(reason)
            } else {
                pullRequestReasons.remove(reason)
            }
        }
    }
}

struct AttentionNotification: Identifiable, Equatable, Sendable {
    var id: String { nodeID }

    let nodeID: String
    let kind: AttentionKind
    let repositoryName: String
    let number: Int
    let title: String
    let url: URL
    let matchingReasons: AttentionReason
}

enum NotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

@MainActor
protocol AttentionNotificationSending {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async throws -> Bool
    func send(_ notifications: [AttentionNotification]) async throws
    func openSystemSettings()
}

@MainActor
final class UserNotificationController: NSObject, AttentionNotificationSending,
    UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorizationState() async -> NotificationAuthorizationState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func send(_ notifications: [AttentionNotification]) async throws {
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = "\(notification.repositoryName) #\(notification.number)"
            content.subtitle = reasonDescription(notification.matchingReasons)
            content.body = notification.title
            content.sound = .default
            content.threadIdentifier = notification.repositoryName
            content.userInfo = ["url": notification.url.absoluteString]

            let request = UNNotificationRequest(
                identifier: "AttentionSeaker.\(notification.nodeID)",
                content: content,
                trigger: nil
            )
            try await center.add(request)
        }
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let urlString = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: urlString)
        else { return }
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }
    }

    private func reasonDescription(_ reasons: AttentionReason) -> String {
        var labels: [String] = []
        if reasons.contains(.reviewRequested) { labels.append("Needs your review") }
        if reasons.contains(.assigned) { labels.append("Assigned to you") }
        if reasons.contains(.mentioned) { labels.append("Mentions you") }
        if reasons.contains(.authored) { labels.append("Authored by you") }
        return labels.joined(separator: " • ")
    }
}
