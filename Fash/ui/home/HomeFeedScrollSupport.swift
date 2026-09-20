import SwiftUI
import UIKit

enum HomeScrollIds {
    static let top = "home_feed_scroll_top"
    static let pinnedTabs = "home_feed_pinned_tabs"
    static let feedContent = "home_feed_content"
}

struct HomeFeedScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// In-scroll tab row minY — when < 0 the row scrolled off; show Android-style sticky overlay.
struct HomeTabRowMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

struct HomeTabRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 48

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

struct HomeFeedScrollOffsetAnchor: View {
    var body: some View {
        Color.clear
            .frame(height: 0)
            .id(HomeScrollIds.top)
            .homeFeedScrollOffsetReporting()
    }
}

extension View {
    func homeFeedScrollOffsetReporting(space: String = "homeFeedScroll") -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: HomeFeedScrollOffsetKey.self,
                    value: geo.frame(in: .named(space)).minY
                )
            }
            .allowsHitTesting(false)
        }
    }

    func homeTabRowScrollReporting(space: String = "homeFeedScroll") -> some View {
        background {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: HomeTabRowMinYKey.self,
                        value: geo.frame(in: .named(space)).minY
                    )
                    .preference(key: HomeTabRowHeightKey.self, value: geo.size.height)
            }
            .allowsHitTesting(false)
        }
    }
}

struct HomeHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

extension View {
    func homeFeedHeaderHeightReporting() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(key: HomeHeaderHeightKey.self, value: geo.size.height)
            }
        }
    }

    func onHomeHeaderHeightChange(_ height: Binding<CGFloat>) -> some View {
        onPreferenceChange(HomeHeaderHeightKey.self) { newHeight in
            guard newHeight > 1, abs(newHeight - height.wrappedValue) > 0.5 else { return }
            height.wrappedValue = newHeight
        }
    }
}

enum HomeFeedScrollReset {
    @MainActor
    static func scrollToTop(proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(HomeScrollIds.top, anchor: .top)
        }
    }

    /// Retries until masonry/header layout settles — matches Profile + Android `animateScrollToItem(0)`.
    @MainActor
    static func scheduleScrollToTop(
        proxy: ScrollViewProxy,
        delaysMs: [Int] = [0, 80, 200]
    ) {
        scrollToTop(proxy: proxy)
        guard delaysMs.contains(where: { $0 > 0 }) else { return }
        Task { @MainActor in
            for delayMs in delaysMs where delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
                scrollToTop(proxy: proxy)
            }
        }
    }

    @MainActor
    static func scrollToFeedTop(proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(HomeScrollIds.pinnedTabs, anchor: .top)
        }
    }

    /// Tab swipe / different tab — pinned tab row + feed start (Profile `scrollToPinnedContent` parity).
    @MainActor
    static func scheduleScrollToFeedTop(
        proxy: ScrollViewProxy,
        delaysMs: [Int] = [0, 80, 200, 320]
    ) {
        scrollToFeedTop(proxy: proxy)
        guard delaysMs.contains(where: { $0 > 0 }) else { return }
        Task { @MainActor in
            for delayMs in delaysMs where delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
                scrollToFeedTop(proxy: proxy)
            }
        }
    }
}

enum HomeFeedScrollMath {
    static func isAtTop(contentOffsetY: CGFloat, adjustedInsetTop: CGFloat, tolerance: CGFloat = 28) -> Bool {
        contentOffsetY <= -adjustedInsetTop + tolerance
    }

    static func isNearBottom(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        adjustedInsetBottom: CGFloat
    ) -> Bool {
        guard contentHeight > 1, viewportHeight > 1 else { return true }
        let maxOffset = max(
            0,
            contentHeight - viewportHeight + adjustedInsetBottom
        )
        if maxOffset <= 48 { return true }
        let distanceFromBottom = maxOffset - contentOffsetY
        let threshold = max(520, viewportHeight * 1.35)
        return distanceFromBottom <= threshold
    }
}

/// UIKit scroll boundary — gates Following load-more + home sticky tab chrome.
@Observable
@MainActor
final class HomeFeedScrollBoundary {
    private(set) var isNearBottom = false
    private(set) var isAtTop = true
    private(set) var isScrollingUp = false
    private(set) var isUserInteracting = false
    private(set) var contentOffsetY: CGFloat = 0
    /// True when in-scroll tab row scrolled off — drives pinned tab overlay.
    private(set) var stickyTabsVisible = false

    private var stickyTabsLatch = false
    private var stickyForceHidden = false

    /// Load-more when near the feed bottom and not actively scrolling up toward the header.
    var allowsFollowingLoadMore: Bool {
        guard !isScrollingUp else { return false }
        guard !isUserInteracting else { return false }
        return isNearBottom
    }

    func forceHideHomeStickyTabs() {
        stickyForceHidden = true
        stickyTabsLatch = false
        if stickyTabsVisible {
            stickyTabsVisible = false
        }
    }

    func updateHomeStickyTabsVisibility(headerHeight: CGFloat, tabRowHeight: CGFloat) {
        let chromeHeight = max(headerHeight, 0) + max(tabRowHeight, 44)
        let pinThreshold = max(chromeHeight - 6, 72)
        let unpinThreshold = max(pinThreshold - 36, 12)
        let offset = max(0, contentOffsetY)

        if stickyForceHidden {
            // Reset when:
            //   (a) scroll returned to the top — tap-to-top animation completed, OR
            //   (b) scroll passed the header — user scrolled through the header zone
            //       and sticky tabs must be visible again (deep-scroll guest tab bug fix).
            if contentOffsetY <= 24 || offset >= pinThreshold {
                stickyForceHidden = false
            } else {
                if stickyTabsVisible { stickyTabsVisible = false }
                stickyTabsLatch = false
                return
            }
        }

        if isAtTop || offset <= unpinThreshold {
            stickyTabsLatch = false
        } else if offset >= pinThreshold {
            stickyTabsLatch = true
        }

        if stickyTabsVisible != stickyTabsLatch {
            stickyTabsVisible = stickyTabsLatch
        }
    }

    fileprivate func apply(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        adjustedInsetTop: CGFloat,
        adjustedInsetBottom: CGFloat,
        deltaY: CGFloat,
        isUserInteracting: Bool
    ) {
        let atTop = HomeFeedScrollMath.isAtTop(
            contentOffsetY: contentOffsetY,
            adjustedInsetTop: adjustedInsetTop
        )
        let nearBottom = HomeFeedScrollMath.isNearBottom(
            contentOffsetY: contentOffsetY,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            adjustedInsetBottom: adjustedInsetBottom
        )
        if atTop != isAtTop { isAtTop = atTop }
        if nearBottom != isNearBottom { isNearBottom = nearBottom }
        if isUserInteracting != self.isUserInteracting { self.isUserInteracting = isUserInteracting }
        if abs(contentOffsetY - self.contentOffsetY) > 0.5 {
            self.contentOffsetY = contentOffsetY
        }
        if abs(deltaY) > 3.5 {
            if deltaY < 0 {
                if !isScrollingUp { isScrollingUp = true }
            } else if isScrollingUp {
                isScrollingUp = false
            }
        }
        if atTop, isScrollingUp { isScrollingUp = false }
    }

    fileprivate func clearScrollingUpIfIdle() {
        guard isScrollingUp else { return }
        // Release when back at top, or when user scrolled up away from the pagination zone.
        if isAtTop || !isNearBottom {
            isScrollingUp = false
        }
    }
}

/// Boundary tracking + one-shot UIKit scroll-to-top on the home feed `UIScrollView`.
struct HomeFeedScrollCoordinator: UIViewRepresentable {
    var scrollBoundary: HomeFeedScrollBoundary
    var scrollToTopToken: Int = 0
    var homeHeaderHeight: CGFloat = 0
    var homeTabRowHeight: CGFloat = 48

    func makeCoordinator() -> Coordinator { Coordinator(boundary: scrollBoundary) }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.boundary = scrollBoundary
        coordinator.homeHeaderHeight = homeHeaderHeight
        coordinator.homeTabRowHeight = homeTabRowHeight
        uiView.coordinator = coordinator
        coordinator.installIfNeeded(from: uiView)
        scrollBoundary.updateHomeStickyTabsVisibility(
            headerHeight: homeHeaderHeight,
            tabRowHeight: homeTabRowHeight
        )
        if scrollToTopToken > 0, scrollToTopToken != coordinator.lastScrollToTopToken {
            coordinator.lastScrollToTopToken = scrollToTopToken
            coordinator.scrollToTrueTop(on: uiView)
        }
    }

    @MainActor
    final class Coordinator {
        var boundary: HomeFeedScrollBoundary
        var homeHeaderHeight: CGFloat = 0
        var homeTabRowHeight: CGFloat = 48
        var lastScrollToTopToken = 0
        weak var scrollView: UIScrollView?
        private var offsetObservation: NSKeyValueObservation?
        private var lastContentOffsetY: CGFloat?
        private var scrollIdleTask: Task<Void, Never>?

        init(boundary: HomeFeedScrollBoundary) {
            self.boundary = boundary
        }

        func installIfNeeded(from anchor: UIView) {
            guard let scrollView = anchor.enclosingScrollView() else { return }
            if self.scrollView === scrollView, offsetObservation != nil { return }

            offsetObservation?.invalidate()
            self.scrollView = scrollView
            lastContentOffsetY = scrollView.contentOffset.y
            reportBoundary(on: scrollView, deltaY: 0)

            offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let y = sv.contentOffset.y
                    let delta = y - (self.lastContentOffsetY ?? y)
                    self.lastContentOffsetY = y
                    self.reportBoundary(on: sv, deltaY: delta)
                }
            }
        }

        @MainActor
        private func reportBoundary(on scrollView: UIScrollView, deltaY: CGFloat) {
            let interacting = scrollView.isDragging
                || scrollView.isTracking
                || scrollView.isDecelerating
            boundary.apply(
                contentOffsetY: scrollView.contentOffset.y,
                contentHeight: scrollView.contentSize.height,
                viewportHeight: scrollView.bounds.height,
                adjustedInsetTop: scrollView.adjustedContentInset.top,
                adjustedInsetBottom: scrollView.adjustedContentInset.bottom,
                deltaY: deltaY,
                isUserInteracting: interacting
            )
            boundary.updateHomeStickyTabsVisibility(
                headerHeight: homeHeaderHeight,
                tabRowHeight: homeTabRowHeight
            )
            scrollIdleTask?.cancel()
            scrollIdleTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                boundary.clearScrollingUpIfIdle()
            }
        }

        func scrollToTrueTop(on anchor: AnchorView) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = anchor.enclosingScrollView() else { return }
                scrollView.layoutIfNeeded()
                if scrollView.contentInset.top > 0.5 {
                    scrollView.contentInset.top = 0
                    var inset = scrollView.verticalScrollIndicatorInsets
                    inset.top = 0
                    scrollView.verticalScrollIndicatorInsets = inset
                }
                boundary.forceHideHomeStickyTabs()
                let top = -scrollView.adjustedContentInset.top
                scrollView.setContentOffset(CGPoint(x: 0, y: top), animated: false)
                boundary.updateHomeStickyTabsVisibility(
                    headerHeight: homeHeaderHeight,
                    tabRowHeight: homeTabRowHeight
                )
            }
        }
    }

    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let coordinator else { return }
                coordinator.installIfNeeded(from: self)
            }
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
