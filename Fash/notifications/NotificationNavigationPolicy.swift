import Foundation

/// Single source of truth for which push notification types skip the generic notification
/// detail screen and jump straight to their target screen when the tray notification is
/// tapped — mirrors Android `NotificationNavigationPolicy`.
///
/// To add a new "navigate directly" type, add a branch in `resolve` that returns a `Target`.
/// Every type not covered here keeps falling through to the generic notification detail screen.
@MainActor
enum NotificationNavigationPolicy {
    enum Target {
        case chat(conversationId: String)
        case listing(listingId: String)
    }

    static func resolve(_ data: [String: String]) -> Target? {
        if let conversationId = InAppNotificationNavigation.chatConversationId(from: data) {
            return .chat(conversationId: conversationId)
        }

        let type = data["type"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard type.hasPrefix("marketplace.recommendation.") else { return nil }

        let anyData = data.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        guard !NotificationExploreNavigation.isExplorePrimaryIntent(anyData) else { return nil }

        let listingId = data["listing_id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? data["listingId"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let listingId, !listingId.isEmpty else { return nil }
        return .listing(listingId: listingId)
    }
}
