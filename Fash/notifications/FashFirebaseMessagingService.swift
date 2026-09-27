import Foundation

/// Port of Android `FashFirebaseMessagingService` — parses FCM `data` payload and routes deep links.
enum FashFirebaseMessagingService {
    static func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        let data = stringDataMap(from: userInfo)
        routeFromPushData(data)
    }

    @MainActor
    static func handleForegroundNotification(userInfo: [AnyHashable: Any]) {
        let data = stringDataMap(from: userInfo)
        if AppDependencies.shared.appMaintenance.applyFromPushData(data) {
            return
        }
        guard isNotificationForLoggedInUser(data) else { return }

        if data["type"] == AccountSwitchDeepLinks.fcmType {
            return
        }

        if data["inbox_refresh"] == "1" {
            AppDependencies.shared.requestInboxUnreadRefresh()
            AppDependencies.shared.requestChatInboxRefresh()
        }

        if AppPromoPushParsing.isAppPromoPushData(data),
           let campaign = AppPromoPushParsing.parseAppPromoFromPushData(
               data: data,
               fallbackTitle: data["title"],
               fallbackBody: data["body"]
           ) {
            let deps = AppDependencies.shared
            AppPromoPresentationPolicy.handleIncoming(
                campaign: campaign,
                deps: deps,
                openConversationId: ChatNotificationPresence.openConversationId(deps: deps),
                userNotificationId: inboxNotificationId(from: data),
                chatVM: nil
            )
            return
        }

        let title = data["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = data["body"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let title, !title.isEmpty {
            let deps = AppDependencies.shared
            let openId = ChatNotificationPresence.openConversationId(deps: deps)
            if ChatInAppNotificationPolicy.shouldSuppressInApp(data: data, openConversationId: openId) {
                ChatNotificationPresence.handleSuppressedChatNotification(data: data, deps: deps)
                return
            }
            deps.showInAppNotification(FashInAppNotificationSession(
                title: title,
                body: body,
                userNotificationId: inboxNotificationId(from: data),
                dataMap: data
            ))
            AppDependencies.shared.requestInboxUnreadRefresh()
            if ChatInAppNotificationPolicy.isChatRelated(data: data) {
                AppDependencies.shared.requestChatInboxRefresh()
            }
        }
    }

    private static func routeFromPushData(_ data: [String: String]) {
        Task { @MainActor in
            let deps = AppDependencies.shared
            if deps.appMaintenance.applyFromPushData(data) {
                return
            }
            if let prompt = AccountSwitchDeepLinks.parseFromFcmData(data) {
                deps.requestAccountSwitchPrompt(prompt)
                return
            }
            NotificationEngagementReporter.reportOpen(reporter: deps.feedEventReporter, data: data)
            if AppPromoPushParsing.isAppPromoPushData(data),
               let campaign = AppPromoPushParsing.parseAppPromoFromPushData(
                   data: data,
                   fallbackTitle: data["title"],
                   fallbackBody: data["body"]
               ) {
                AppPromoPresentationPolicy.handleIncoming(
                    campaign: campaign,
                    deps: deps,
                    openConversationId: ChatNotificationPresence.openConversationId(deps: deps),
                    userNotificationId: inboxNotificationId(from: data),
                    chatVM: nil
                )
                return
            }
            if let deepLink = data["deep_link"]?.trimmingCharacters(in: .whitespacesAndNewlines), !deepLink.isEmpty,
               routeDeepLink(deepLink, deps: deps) {
                return
            }
            // Types flagged in NotificationNavigationPolicy (currently chat + recommendations
            // carrying a listing) skip the generic inbox/notification-detail screen entirely,
            // even when the payload also carries a ledger id — add new direct types there.
            if let router = deps.navigationRouter, let target = NotificationNavigationPolicy.resolve(data) {
                switch target {
                case .chat(let conversationId):
                    InAppNotificationNavigation.openChat(conversationId: conversationId, router: router, deps: deps)
                case .listing(let listingId):
                    deps.presentListingDetail(listingId: listingId, router: router)
                }
                return
            }
            let nav = data["nav_target"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ?? data["navTarget"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ?? ""
            if nav == "onboarding", let router = deps.navigationRouter {
                InAppNotificationNavigation.openOnboarding(router: router)
                return
            }
            if nav == "order" || nav == "orders",
               let orderId = InAppNotificationNavigation.orderId(from: data),
               let router = deps.navigationRouter {
                InAppNotificationNavigation.openOrder(orderId: orderId, router: router, deps: deps)
                return
            }
            if let inboxId = inboxNotificationId(from: data) {
                deps.pendingInboxNotificationId = inboxId
                deps.navigationRouter?.showNotificationScreen = true
                deps.navigationRouter?.notificationDetailId = inboxId
            }
            deps.requestInboxUnreadRefresh()
            if ChatInAppNotificationPolicy.isChatRelated(data: data) {
                deps.requestChatInboxRefresh()
            }
        }
    }

    @MainActor
    private static func storePendingDeepLink(url: URL, deps: AppDependencies) {
        guard url.scheme == "fash" else { return }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch url.host {
        case "listing":
            deps.pendingDeepLinkListingId = path
        case "profile":
            deps.pendingDeepLinkSellerUsername = path
        case "inbox":
            deps.pendingInboxNotificationId = path
        default:
            break
        }
    }

    @MainActor
    private static func isNotificationForLoggedInUser(_ data: [String: String]) -> Bool {
        let sessionUid = AppDependencies.shared.authSessionStore.read()?.userId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if sessionUid.isEmpty { return true }
        let recipient = data["recipient_user_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if recipient.isEmpty { return true }
        return sessionUid.caseInsensitiveCompare(recipient) == .orderedSame
    }

    /// Ledger row id from tray / FCM data (`user_notification_id`, `notification_id`, or `fash://inbox/{id}`).
    static func inboxNotificationId(from data: [String: String]) -> String? {
        for key in ["user_notification_id", "notification_id", "inbox_notification_id"] {
            let value = data[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        if let deepLink = data["deep_link"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let id = inboxId(fromDeepLink: deepLink) {
            return id
        }
        return nil
    }

    @MainActor
    private static func routeDeepLink(_ deepLink: String, deps: AppDependencies) -> Bool {
        if let inboxId = inboxId(fromDeepLink: deepLink) {
            deps.pendingInboxNotificationId = inboxId
            deps.navigationRouter?.showNotificationScreen = true
            deps.navigationRouter?.notificationDetailId = inboxId
            return true
        }
        guard let url = URL(string: deepLink) else { return false }
        let host = url.host?.lowercased() ?? ""
        switch host {
        case "listing", "profile", "invite":
            if let router = deps.navigationRouter {
                DeepLinkRouter.handle(url: url, router: router, deps: deps)
            } else {
                storePendingDeepLink(url: url, deps: deps)
            }
            return true
        default:
            if url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" {
                if let router = deps.navigationRouter {
                    DeepLinkRouter.handle(url: url, router: router, deps: deps)
                    return true
                }
            }
            return false
        }
    }

    private static func inboxId(fromDeepLink raw: String) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard url.scheme?.lowercased() == "fash", url.host?.lowercased() == "inbox" else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : path
    }

    private static func stringDataMap(from userInfo: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        mergeDictionary(userInfo, into: &out)
        if let dataStr = out["data"], let nested = jsonObject(from: dataStr) {
            mergeDictionary(nested, into: &out)
        }
        applyApsAlertFallback(userInfo, into: &out)
        return out
    }

    private static func mergeDictionary(_ dict: [AnyHashable: Any], into out: inout [String: String]) {
        for (rawKey, value) in dict {
            guard let key = rawKey as? String, !key.isEmpty else { continue }
            if key.hasPrefix("gcm.") || key.hasPrefix("google.") || key.hasPrefix("fcm.") { continue }
            if key == "aps" { continue }
            if let nested = value as? [AnyHashable: Any] {
                mergeDictionary(nested, into: &out)
                continue
            }
            if let nested = value as? [String: Any] {
                mergeDictionary(Dictionary(uniqueKeysWithValues: nested.map { ($0.key as AnyHashable, $0.value) }), into: &out)
                continue
            }
            let string: String?
            if let s = value as? String {
                string = s
            } else if let number = value as? NSNumber {
                string = number.stringValue
            } else {
                string = nil
            }
            guard let string, !string.isEmpty else { continue }
            if out[key] == nil || out[key]?.isEmpty == true {
                out[key] = string
            }
        }
    }

    private static func jsonObject(from raw: String) -> [AnyHashable: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [AnyHashable: Any]
    }

    private static func applyApsAlertFallback(_ userInfo: [AnyHashable: Any], into out: inout [String: String]) {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return }
        if let alert = aps["alert"] as? [AnyHashable: Any] {
            if out["title"] == nil, let title = alert["title"] as? String, !title.isEmpty {
                out["title"] = title
            }
            if out["body"] == nil, let body = alert["body"] as? String, !body.isEmpty {
                out["body"] = body
            }
        } else if let alert = aps["alert"] as? String, !alert.isEmpty, out["body"] == nil {
            out["body"] = alert
        }
    }
}
