import Foundation
import SwiftUI
import UIKit

/// Cursor-paginated home feed page — backend `HomeFeedPageResponse`.
struct HomeFeedPage: Sendable {
    let items: [ListingFeedItem]
    let hasMore: Bool
    let nextCursor: String?
}

/// Window sizing — home following vs image-heavy seller storefront.
struct FeedSlidingWindowPolicy: Sendable {
    var maxItems: Int
    var bufferBefore: Int
    var bufferAfter: Int
    var backfillVisibleThreshold: Int

    static let homeFollowing = FeedSlidingWindowPolicy(
        maxItems: 80,
        bufferBefore: 30,
        bufferAfter: 30,
        backfillVisibleThreshold: 12
    )

    /// Tighter cap — seller grids load full-bleed photos; trim earlier to avoid jetsam.
    static let sellerStorefront = FeedSlidingWindowPolicy(
        maxItems: 48,
        bufferBefore: 16,
        bufferAfter: 16,
        backfillVisibleThreshold: 10
    )
}

/// TikTok-style bounded in-memory window with front-trim + scroll compensation.
struct FeedSlidingWindow {
    private(set) var items: [ListingFeedItem] = []
    /// Logical index of `items[0]` in the full feed timeline (for analytics / offset backfill).
    private(set) var logicalStartIndex = 0

    struct Config {
        static let maxItems = FeedSlidingWindowPolicy.homeFollowing.maxItems
        static let bufferBefore = FeedSlidingWindowPolicy.homeFollowing.bufferBefore
        static let bufferAfter = FeedSlidingWindowPolicy.homeFollowing.bufferAfter
        static let prefetchThreshold = 10
    }

    struct TrimResult {
        let removedCount: Int
        /// Positive height removed from top — subtract from `contentOffset.y`.
        let scrollDeltaY: CGFloat
    }

    struct PrependResult {
        let addedCount: Int
        /// Positive height inserted at top — add to `contentOffset.y`.
        let scrollDeltaY: CGFloat
    }

    mutating func reset(with initial: [ListingFeedItem]) {
        items = initial
        logicalStartIndex = 0
    }

    /// Append-only with dedupe — never replaces the whole array.
    mutating func appendUnique(_ newItems: [ListingFeedItem], knownIds: inout Set<String>) -> Int {
        let fresh = newItems.filter { knownIds.insert($0.id).inserted }
        guard !fresh.isEmpty else { return 0 }
        items.append(contentsOf: fresh)
        return fresh.count
    }

    /// Rehydrate rows above the window when the user scrolls back toward the header.
    mutating func prependUnique(
        _ newItems: [ListingFeedItem],
        knownIds: inout Set<String>,
        columnWidth: CGFloat,
        columnAssignments: [String: Bool] = [:]
    ) -> PrependResult? {
        let fresh = newItems.filter { knownIds.insert($0.id).inserted }
        guard !fresh.isEmpty else { return nil }
        items.insert(contentsOf: fresh, at: 0)
        logicalStartIndex = max(0, logicalStartIndex - fresh.count)
        let deltaY = columnAssignments.isEmpty
            ? Self.estimateMasonryHeight(items: fresh, columnWidth: columnWidth)
            : Self.exactMasonryHeight(items: fresh, columnWidth: columnWidth, columnAssignments: columnAssignments)
        return PrependResult(addedCount: fresh.count, scrollDeltaY: deltaY)
    }

    /// Restore previously-trimmed items from the global store, bypassing knownIds check.
    /// Caller guarantees `restoredItems` are already in `knownIds` and ordered oldest-first.
    mutating func restoreFront(_ restoredItems: [ListingFeedItem]) {
        guard !restoredItems.isEmpty else { return }
        items.insert(contentsOf: restoredItems, at: 0)
        logicalStartIndex = max(0, logicalStartIndex - restoredItems.count)
    }

    /// Append items that are guaranteed deduplicated by the caller (via FeedGlobalItemStore).
    mutating func appendKnownFresh(_ newItems: [ListingFeedItem]) {
        items.append(contentsOf: newItems)
    }

    /// Drop rows far above the viewport; returns scroll compensation for UIKit.
    mutating func trimFrontIfNeeded(
        visibleIndex: Int,
        columnWidth: CGFloat,
        policy: FeedSlidingWindowPolicy = .homeFollowing,
        columnAssignments: [String: Bool] = [:]
    ) -> TrimResult? {
        guard items.count > policy.maxItems else { return nil }
        guard visibleIndex >= policy.bufferBefore + 6 else { return nil }

        let targetStart = max(0, visibleIndex - policy.bufferBefore)
        let removeCount = min(targetStart, items.count - policy.maxItems / 2)
        guard removeCount > 0 else { return nil }

        let removed = Array(items.prefix(removeCount))
        let deltaY = columnAssignments.isEmpty
            ? Self.estimateMasonryHeight(items: removed, columnWidth: columnWidth)
            : Self.exactMasonryHeight(items: removed, columnWidth: columnWidth, columnAssignments: columnAssignments)
        items.removeFirst(removeCount)
        logicalStartIndex += removeCount
        return TrimResult(removedCount: removeCount, scrollDeltaY: deltaY)
    }

    /// Trim items from the tail of the window. Used bidirectionally: when loading content above,
    /// cut the same count from below so the window stays bounded without scroll compensation.
    /// Unlike trimFront, this does NOT change [logicalStartIndex].
    @discardableResult
    mutating func trimBack(count: Int) -> Int {
        guard count > 0, !items.isEmpty else { return 0 }
        let removeCount = min(count, items.count)
        items.removeLast(removeCount)
        return removeCount
    }

    mutating func mapItems(_ transform: (ListingFeedItem) -> ListingFeedItem) {
        items = items.map(transform)
    }

    /// O(1) in-place patch for a single item (like/save toggles) — avoids full O(n) map.
    @discardableResult
    mutating func patchItem(withId id: String, transform: (ListingFeedItem) -> ListingFeedItem) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        items[idx] = transform(items[idx])
        return true
    }

    /// Engagement / edit — drop rows without shifting [logicalStartIndex].
    mutating func removeItems(withIds ids: Set<String>, knownIds: inout Set<String>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        knownIds.subtract(ids)
    }

    @discardableResult
    mutating func insertUniqueAtTop(_ item: ListingFeedItem, knownIds: inout Set<String>) -> Bool {
        guard knownIds.insert(item.id).inserted else { return false }
        items.insert(item, at: 0)
        return true
    }

    static func estimateMasonryHeight(items: [ListingFeedItem], columnWidth: CGFloat) -> CGFloat {
        guard !items.isEmpty, columnWidth > 1 else { return 0 }
        let gap: CGFloat = 8
        var left: CGFloat = 0
        var right: CGFloat = 0
        // Shortest-column placement mirrors the actual masonry layout algorithm,
        // replacing the previous parity heuristic which was 10-30% off for portrait-heavy feeds.
        for item in items {
            let h = ListingMasonryGrid.tileHeight(columnWidth: columnWidth, item: item)
            if left <= right {
                left += h + gap
            } else {
                right += h + gap
            }
        }
        return max(left, right)
    }

    /// Compute height using stored column assignments for precision.
    /// For items without a stored assignment, falls back to shortest-column simulation.
    static func exactMasonryHeight(
        items: [ListingFeedItem],
        columnWidth: CGFloat,
        columnAssignments: [String: Bool]
    ) -> CGFloat {
        guard !items.isEmpty, columnWidth > 1 else { return 0 }
        let gap: CGFloat = 8
        var left: CGFloat = 0
        var right: CGFloat = 0
        for item in items {
            let h = ListingMasonryGrid.tileHeight(columnWidth: columnWidth, item: item)
            let isRight = columnAssignments[item.id] ?? (left > right)
            if isRight { right += h + gap } else { left += h + gap }
        }
        return max(left, right)
    }
}

/// Keeps the viewport stable after sliding-window trim/prepend on a parent `ScrollView`.
struct FeedScrollTrimCompensator: UIViewRepresentable {
    var token: Int
    /// Signed UIKit adjustment: negative = trim (scroll up), positive = prepend (scroll down).
    var signedDeltaY: CGFloat
    /// When non-nil and in the future, all compensation is skipped (tap-to-top suppression window).
    var suppressUntil: Date? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        uiView.coordinator = context.coordinator
        context.coordinator.suppressUntil = suppressUntil
        guard token > 0, token != context.coordinator.lastToken else { return }
        context.coordinator.lastToken = token
        uiView.applyCompensation(signedDeltaY: signedDeltaY)
    }

    final class Coordinator {
        var lastToken = 0
        var suppressUntil: Date?
    }

    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        func applyCompensation(signedDeltaY: CGFloat) {
            DispatchQueue.main.async { [weak self] in
                self?.applyCompensationNow(signedDeltaY: signedDeltaY)
            }
        }

        private func applyCompensationNow(signedDeltaY: CGFloat) {
            guard abs(signedDeltaY) > 0.5, let scrollView = enclosingScrollView() else { return }
            // Suppress during the tap-to-top window so a stale restore token cannot push
            // the viewport back down after requestScrollHomeToTop set it to the true top.
            if let sup = coordinator?.suppressUntil, Date.now < sup { return }
            scrollView.layoutIfNeeded()
            let minY = -scrollView.adjustedContentInset.top
            // Safety net: skip positive-delta compensation when already at or near the top.
            if signedDeltaY > 0, scrollView.contentOffset.y <= minY + 150 { return }
            var offset = scrollView.contentOffset
            offset.y = max(minY, offset.y + signedDeltaY)
            scrollView.setContentOffset(offset, animated: false)
        }
    }
}

private extension UIView {
    func enclosingScrollView() -> UIScrollView? {
        var candidate: UIView? = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView { return scrollView }
            candidate = view.superview
        }
        return nil
    }
}
