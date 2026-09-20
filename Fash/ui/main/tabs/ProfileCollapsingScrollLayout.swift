import SwiftUI
import UIKit

/// Seller storefront tab slots — not [ProfileListingTab] raw values (sold = 3 would collide).
enum SellerProfileTab: Int {
    case selling = 0
    case sold = 1
}

enum ProfileListingTabSet {
    case ownProfile
    case sellerStorefront

    var tabCount: Int {
        switch self {
        case .ownProfile: return ProfileListingTab.allCases.count
        case .sellerStorefront: return SellerProfileTab.sold.rawValue + 1
        }
    }

    func title(for index: Int) -> String {
        switch self {
        case .ownProfile:
            return ProfileListingTab(rawValue: index)?.title ?? ""
        case .sellerStorefront:
            switch SellerProfileTab(rawValue: index) {
            case .sold: return L10n.profileTabSold
            default: return L10n.profileTabSelling
            }
        }
    }

    func emptyTitle(for index: Int) -> String {
        switch self {
        case .ownProfile:
            return ProfileListingTab(rawValue: index)?.emptyTitle ?? L10n.feedEmptyTitle
        case .sellerStorefront:
            switch SellerProfileTab(rawValue: index) {
            case .sold: return L10n.profileEmptySoldTitle
            default: return L10n.profileEmptySellingTitle
            }
        }
    }

    func emptySubtitle(for index: Int) -> String {
        switch self {
        case .ownProfile:
            return ProfileListingTab(rawValue: index)?.emptySubtitle ?? L10n.feedEmptySubtitle
        case .sellerStorefront:
            switch SellerProfileTab(rawValue: index) {
            case .sold: return L10n.profileEmptySoldSubtitle
            default: return L10n.profileEmptySellingSubtitle
            }
        }
    }

    func pinnedFooter(for index: Int) -> String? {
        switch self {
        case .ownProfile:
            switch ProfileListingTab(rawValue: index) {
            case .active: return L10n.profileEmptyPinnedFooterSelling
            case .inReview: return L10n.profileEmptyPinnedFooterInReview
            case .rejected: return L10n.profileEmptyPinnedFooterRejected
            case .sold: return L10n.profileEmptyPinnedFooterSold
            case .wishlist: return L10n.profileEmptyPinnedFooterWishlist
            default: return nil
            }
        case .sellerStorefront:
            switch SellerProfileTab(rawValue: index) {
            case .sold: return L10n.profileEmptyPinnedFooterSold
            default: return L10n.profileEmptyPinnedFooterSelling
            }
        }
    }
}

private enum ProfileCollapseMetrics {
    static let scrollDistance: CGFloat = 280
}

private struct ProfileScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ProfileHeaderBoundsKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Collapsing profile scroll — Android [ProfileCollapsingScrollLayout].
struct ProfileCollapsingScrollLayout<ExpandedHeader: View, CompactHeader: View>: View {
    @Environment(\.fashSpacing) private var spacing
    @Binding var selectedTab: Int
    let tabSet: ProfileListingTabSet
    /// Visual order of logical tab indices — Android `orderedTabIndices`.
    var orderedTabIndices: [Int] = ProfileListingTab.allCases.map(\.rawValue)
    /// Optional tab badge from summary counts — `(logicalTabIndex) -> count`.
    var tabBadgeCounts: ((Int) -> Int?)? = nil
    let items: [ListingFeedItem]
    var showQuickActions: Bool = false
    var showStatusOverlay: Bool = false
    /// When true, hide "active"/"inactive" chips (seller storefront); own profile passes false.
    var suppressActiveStatusOnGrid: Bool = true
    var additionalBottomInset: CGFloat = 0
    /// Legacy flag — profile grid always uses hoisted chunked masonry rows in `LazyVStack`.
    var useStaggeredMasonryGrid: Bool = false
    /// When true, hoists one continuous masonry (eager column layout) instead of tiny lazy rows.
    var masonryEagerLayout: Bool = false
    /// Skeleton grid (Explore-style) while the first page loads.
    var showGridLoading: Bool = false
    var showGridLoadRetry: Bool = false
    var onRetryGridLoad: (() -> Void)? = nil
    var hasMoreListings: Bool = false
    var isLoadingMoreListings: Bool = false
    var isReloadingListings: Bool = false
    var onLoadMore: (() -> Void)? = nil
    /// When false, empty listings are hidden (still loading).
    var showEmptyState: Bool = true
    /// Skip scroll clamp bumps while pull-to-refresh is in flight — avoids snapping back to top.
    var isRefreshing: Bool = false
    /// Block scroll + clamp while profile shell is still loading — prevents jump-to-top during load.
    var lockScroll: Bool = false
    /// Increment to scroll the listing grid under pinned tabs (Home journey shortcuts).
    var scrollToGridToken: Int = 0
    /// Bottom-nav re-tap — scroll to profile top (expanded header).
    var scrollToTopToken: Int = 0
    var scrollToListingId: String? = nil
    var scrollToListingToken: Int = 0
    /// Hero scrolled off + tabs pinned — Android `rememberProfilePromoFooterVisible` (index > 0).
    var onTabsPinnedAtTopChange: ((Bool) -> Void)? = nil
    /// Fired when a horizontal tab pan locks — dismiss listing preview overlays.
    var onTabHorizontalSwipeActive: ((Bool) -> Void)? = nil
    /// When false, only [FeedLoadMoreFooter] at the list bottom triggers pagination (seller storefront).
    var enableScrollProximityLoadMore: Bool = false
    /// When false, tiles do not prefetch pages while scrolling mid-grid.
    var enableTilePrefetchLoadMore: Bool = false
    /// Skeleton rows at grid bottom while the next page loads (seller storefront).
    var loadMoreSkeletonRows: Int = 0
    /// Sliding-window feeds — skip clamp when tile count shrinks (trim); tab swipe still snaps to pinned grid.
    var suppressScrollClamp: Bool = false
    /// Load next page only when feed bottom reaches the viewport (not mid-grid prefetch).
    var loadMoreAtScrollBottom: Bool = false
    var bottomLoadMoreTolerance: CGFloat = 40
    /// Optional scroll boundary for sliding-window trim gating (seller storefront).
    var feedScrollBoundary: HomeFeedScrollBoundary? = nil
    /// Sliding-window trim/prepend — keeps viewport stable after rows drop above the fold.
    var feedTrimCompensationToken: Int = 0
    var feedTrimCompensationSignedDeltaY: CGFloat = 0
    var onListingCellVisible: ((Int, CGFloat) -> Void)? = nil
    var onListingClick: (ListingFeedItem) -> Void
    var onLike: ((ListingFeedItem) -> Void)?
    var onSave: ((ListingFeedItem) -> Void)?
    @ViewBuilder var expandedHeader: () -> ExpandedHeader
    @ViewBuilder var compactHeader: () -> CompactHeader

    @State private var headerHeight: CGFloat = 0
    @State private var reportedTabsPinned = false
    @State private var showBriefBar = false
    @State private var showSectionTitle = false
    @State private var lastScrollOffset: CGFloat = 0
    @State private var profileScrollResetToken = 0
    @State private var scrollClampRevision = 0
    @State private var masonryColumnAssignmentsByTab: [Int: [String: Bool]] = [:]
    @State private var listingInteractionEnabled = true
    @State private var tabSlideDirection: Int = 0
    /// Sticky chrome stayed pinned through rubber-band — avoids tab row flicker / “missing” tabs.
    @State private var chromePinnedLatch = false
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var feedContentBottomY: CGFloat = .infinity
    @State private var lastProximityLoadMoreAt: Date = .distantPast
    @State private var lastPaginationEvalUptime: UInt64 = 0
    @State private var lastPaginationEvalOffset: CGFloat = .greatestFiniteMagnitude
    @State private var profileMasonryLayout: ListingMasonryColumnLayout = .empty
    @State private var profileMasonryContainerWidth: CGFloat = 0
    @State private var masonryLayoutRefreshTask: Task<Void, Never>?
    @State private var profileLayoutedItemCount = 0

    /// One id for all tabs — Android keeps one [LazyListState]; do not vary per tab (preserves scroll on swipe).
    private let listingGridScrollId = ProfileScrollIds.listingGrid

    private var masonryColumnAssignments: Binding<[String: Bool]> {
        Binding(
            get: { masonryColumnAssignmentsByTab[selectedTab] ?? [:] },
            set: { masonryColumnAssignmentsByTab[selectedTab] = $0 }
        )
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            profileScrollRoot(scrollProxy: scrollProxy)
        }
    }

    @ViewBuilder
    private func profileScrollRoot(scrollProxy: ScrollViewProxy) -> some View {
        ScrollView {
            profileLazyStack(scrollProxy: scrollProxy)
        }
        .scrollDisabled(lockScroll)
        .background(profileViewportHeightReader)
        .background {
            PinnedTabScrollOffsetFixer(
                resetToken: profileScrollResetToken,
                clampRevision: scrollClampRevision,
                headerHeight: headerHeight
            )
        }
        .coordinateSpace(name: ProfileScrollIds.coordinateSpaceName)
        .onAppear(perform: resetProfileScrollChromeState)
        .onPreferenceChange(ProfileScrollOffsetKey.self, perform: handleProfileScrollOffset)
        .onPreferenceChange(FeedContentBottomYKey.self, perform: handleFeedContentBottomY)
        .onPreferenceChange(ProfileHeaderBoundsKey.self, perform: handleProfileHeaderBounds)
        .onChange(of: resolvedTabIndices) { _, indices in
            guard !indices.contains(selectedTab) else { return }
            selectedTab = indices.first ?? 0
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            handleSelectedTabChange(from: oldTab, to: newTab)
            guard oldTab != newTab, !isRefreshing, !lockScroll else { return }
            guard chromePinnedLatch || reportedTabsPinned else { return }
            scheduleApplyPinnedGridScroll(using: scrollProxy)
        }
        .onChange(of: items.count) { oldCount, newCount in
            guard !suppressScrollClamp else { return }
            guard !isRefreshing, !showGridLoading, showEmptyState else { return }
            guard newCount < oldCount else { return }
            scrollClampRevision += 1
        }
        .onChange(of: scrollToGridToken) { _, token in
            guard token > 0, !lockScroll else { return }
            scheduleApplyPinnedGridScroll(using: scrollProxy)
        }
        .onChange(of: scrollToTopToken) { _, token in
            guard token > 0, !lockScroll else { return }
            applyScrollToTop(using: scrollProxy)
        }
        .onChange(of: scrollToListingToken) { _, token in
            guard token > 0, !lockScroll, !showGridLoading else { return }
            scrollToFocusedListing(using: scrollProxy)
        }
    }

    private func scrollToFocusedListing(using scrollProxy: ScrollViewProxy) {
        guard let listingId = scrollToListingId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !listingId.isEmpty else { return }
        Task { @MainActor in
            for delayMs in [0, 80, 200, 400] {
                try? await Task.sleep(for: .milliseconds(delayMs))
                var transaction = Transaction()
                transaction.disablesAnimations = delayMs == 0
                withTransaction(transaction) {
                    scrollProxy.scrollTo(listingId, anchor: .center)
                }
            }
        }
    }

    private var profileViewportHeightReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { scrollViewportHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, h in
                    if h > 0 { scrollViewportHeight = h }
                }
        }
    }

    private var profileTabSwipeEnabled: Bool {
        resolvedTabIndices.count > 1
    }

    @ViewBuilder
    private func profileLazyStack(scrollProxy: ScrollViewProxy) -> some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                expandedHeader()
                    .id(ProfileScrollIds.expandedHeader)
                    .background(profileHeaderOffsetReader)
            }
            Section {
                profileGridWidthProbe
                    .onAppear { scheduleProfileMasonryLayoutRefresh(forceImmediate: true) }
                    .onChange(of: items.count) { oldCount, newCount in
                        scheduleProfileMasonryLayoutRefresh(
                            forceImmediate: newCount < oldCount || oldCount == 0
                        )
                    }
                    .onChange(of: selectedTab) { _, _ in
                        profileMasonryLayout = .empty
                        profileLayoutedItemCount = 0
                        scheduleProfileMasonryLayoutRefresh(forceImmediate: true)
                    }
                    .onDisappear { masonryLayoutRefreshTask?.cancel() }

                Color.clear
                    .frame(height: 0)
                    .id(listingGridScrollId)

                profileListingGridStatusBlock
                    .profileTabSwipe(
                        enabled: profileTabSwipeEnabled,
                        currentIndex: visualTabIndex,
                        tabCount: resolvedTabIndices.count,
                        listingInteractionEnabled: $listingInteractionEnabled,
                        onHorizontalSwipeActive: onTabHorizontalSwipeActive
                    ) { visualIndex in
                        commitProfileTabSwipe(toVisualIndex: visualIndex)
                    }

                if shouldShowProfileMasonryChunks {
                    if masonryEagerLayout {
                        profileHoistedMasonryGrid
                            .padding(.top, spacing.spacing2)
                            .overlay(alignment: .top) {
                                profileListingReloadOverlay
                            }
                            .allowsHitTesting(listingInteractionEnabled)
                            .animation(showGridLoading ? nil : FashTabSwipeMotion.contentAnimation, value: selectedTab)
                            .transition(FashTabSwipeMotion.contentTransition)
                            .profileTabSwipe(
                                enabled: profileTabSwipeEnabled,
                                currentIndex: visualTabIndex,
                                tabCount: resolvedTabIndices.count,
                                listingInteractionEnabled: $listingInteractionEnabled,
                                onHorizontalSwipeActive: onTabHorizontalSwipeActive
                            ) { visualIndex in
                                commitProfileTabSwipe(toVisualIndex: visualIndex)
                            }
                    } else {
                        ForEach(profileFeedChunks) { chunk in
                            profileMasonryChunkRow(chunk)
                        }
                    }
                }

                profilePaginationFooter

                profileGridScrollInfrastructure

                Color.clear.frame(height: max(120, additionalBottomInset + 80))
                    .profileTabSwipe(
                        enabled: profileTabSwipeEnabled,
                        currentIndex: visualTabIndex,
                        tabCount: resolvedTabIndices.count,
                        listingInteractionEnabled: $listingInteractionEnabled,
                        onHorizontalSwipeActive: onTabHorizontalSwipeActive
                    ) { visualIndex in
                        commitProfileTabSwipe(toVisualIndex: visualIndex)
                    }
            } header: {
                stickyChrome(scrollProxy: scrollProxy)
                    .profileTabSwipe(
                        enabled: profileTabSwipeEnabled,
                        currentIndex: visualTabIndex,
                        tabCount: resolvedTabIndices.count,
                        listingInteractionEnabled: $listingInteractionEnabled,
                        onHorizontalSwipeActive: onTabHorizontalSwipeActive
                    ) { visualIndex in
                        commitProfileTabSwipe(toVisualIndex: visualIndex)
                    }
            }
        }
    }

    private func commitProfileTabSwipe(toVisualIndex visualIndex: Int) {
        guard visualIndex >= 0, visualIndex < resolvedTabIndices.count else { return }
        let nextTab = resolvedTabIndices[visualIndex]
        guard nextTab != selectedTab else { return }
        tabSlideDirection = FashTabSwipeMotion.slideDirection(
            oldIndex: visualTabIndex,
            newIndex: visualIndex
        )
        withAnimation(FashTabSwipeMotion.contentAnimation) {
            selectedTab = nextTab
        }
    }

    private var profileHeaderOffsetReader: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(ProfileScrollIds.coordinateSpaceName))
            Color.clear
                .preference(key: ProfileScrollOffsetKey.self, value: frame.minY)
                .preference(key: ProfileHeaderBoundsKey.self, value: frame)
        }
        .allowsHitTesting(false)
    }

    private var profileMasonryColumnWidth: CGFloat {
        let width = profileMasonryContainerWidth > 1
            ? profileMasonryContainerWidth
            : UIScreen.main.bounds.width
        return ListingMasonryGrid.feedGridColumnWidth(
            containerWidth: width,
            spacing: spacing
        )
    }

    private var profileFeedChunks: [ListingMasonryFeedPages.FeedOrderChunk] {
        ListingMasonryFeedPages.feedOrderChunks(
            items: items,
            pageSize: ListingMasonryFeedPages.profileChunkPageSize
        )
    }

    /// Each chunk is its own `LazyVStack` row — one nested grid cell only lays out ~one tile (Home uses `VStack`).
    private var shouldShowProfileMasonryChunks: Bool {
        !showGridLoading
            && !(showGridLoadRetry && items.isEmpty)
            && !items.isEmpty
    }

    private func profileMasonryChunkRow(_ chunk: ListingMasonryFeedPages.FeedOrderChunk) -> some View {
        profileFeedChunkRow(chunk)
            .id("\(listingGridScrollId)_chunk_\(chunk.id)")
            .padding(.top, chunk.id == profileFeedChunks.first?.id ? spacing.spacing2 : 0)
            .overlay(alignment: .top) {
                if chunk.id == profileFeedChunks.first?.id {
                    profileListingReloadOverlay
                }
            }
            .allowsHitTesting(listingInteractionEnabled)
            .animation(showGridLoading ? nil : FashTabSwipeMotion.contentAnimation, value: selectedTab)
            .transition(FashTabSwipeMotion.contentTransition)
            .profileTabSwipe(
                enabled: profileTabSwipeEnabled,
                currentIndex: visualTabIndex,
                tabCount: resolvedTabIndices.count,
                listingInteractionEnabled: $listingInteractionEnabled,
                onHorizontalSwipeActive: onTabHorizontalSwipeActive
            ) { visualIndex in
                commitProfileTabSwipe(toVisualIndex: visualIndex)
            }
    }

    @ViewBuilder
    private var profileGridScrollInfrastructure: some View {
        if shouldShowProfileMasonryChunks {
            Color.clear
                .frame(height: 0)
                .background {
                    FeedScrollTrimCompensator(
                        token: feedTrimCompensationToken,
                        signedDeltaY: feedTrimCompensationSignedDeltaY
                    )
                    if let feedScrollBoundary {
                        HomeFeedScrollCoordinator(scrollBoundary: feedScrollBoundary)
                    }
                }
        }
        if enableScrollProximityLoadMore || loadMoreAtScrollBottom, !items.isEmpty {
            FeedScrollContentBottomReporter(coordinateSpace: ProfileScrollIds.coordinateSpaceName)
        }
    }

    private func scheduleProfileMasonryLayoutRefresh(forceImmediate: Bool = false) {
        masonryLayoutRefreshTask?.cancel()
        if forceImmediate {
            refreshProfileMasonryLayout()
            return
        }
        masonryLayoutRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(96))
            guard !Task.isCancelled else { return }
            refreshProfileMasonryLayout()
        }
    }

    private func refreshProfileMasonryLayout() {
        guard !items.isEmpty else {
            profileMasonryLayout = .empty
            profileLayoutedItemCount = 0
            return
        }
        let gap = spacing.spacing2
        var assignments = masonryColumnAssignments.wrappedValue
        let fullRelayout = profileMasonryLayout.isEmpty
            || items.count < profileLayoutedItemCount
            || profileMasonryColumnWidth <= 1

        if fullRelayout {
            profileMasonryLayout = ListingMasonryGrid.makeStableColumnLayout(
                items: items,
                columnWidth: profileMasonryColumnWidth,
                verticalGap: gap,
                assignedIsRightColumn: &assignments
            )
            profileLayoutedItemCount = items.count
        } else if items.count > profileLayoutedItemCount {
            let start = profileLayoutedItemCount
            let slice = Array(items[start...])
            profileMasonryLayout = ListingMasonryGrid.extendStableColumnLayout(
                existing: profileMasonryLayout,
                newItems: slice,
                startIndex: start,
                columnWidth: profileMasonryColumnWidth,
                verticalGap: gap,
                assignedIsRightColumn: &assignments
            )
            profileLayoutedItemCount = items.count
        }
        if assignments != masonryColumnAssignments.wrappedValue {
            masonryColumnAssignments.wrappedValue = assignments
        }
    }

    private func resetProfileScrollChromeState() {
        reportedTabsPinned = false
        chromePinnedLatch = false
        showBriefBar = false
        showSectionTitle = false
        lastScrollOffset = 0
    }

    private var usesFooterBottomLoadMore: Bool {
        loadMoreAtScrollBottom && !enableTilePrefetchLoadMore && !enableScrollProximityLoadMore
    }

    private func shouldRunPaginationEval(for offset: CGFloat) -> Bool {
        guard abs(offset - lastPaginationEvalOffset) > 4 else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastPaginationEvalUptime < 80_000_000 { return false }
        lastPaginationEvalOffset = offset
        lastPaginationEvalUptime = now
        return true
    }

    private func runPaginationEvaluators(headerMinY: CGFloat, bypassThrottle: Bool = false) {
        guard enableScrollProximityLoadMore else { return }
        guard bypassThrottle || shouldRunPaginationEval(for: headerMinY) else { return }
        evaluateScrollProximityLoadMore(headerMinY: headerMinY)
    }

    private func handleProfileScrollOffset(_ offset: CGFloat) {
        applyScrollOffset(offset)
        runPaginationEvaluators(headerMinY: offset)
        evaluateBottomScrollLoadMore(headerMinY: offset)
    }

    private func handleFeedContentBottomY(_ bottomY: CGFloat) {
        feedContentBottomY = bottomY
    }

    private func handleProfileHeaderBounds(_ frame: CGRect) {
        guard frame.height > 10 else { return }
        let nextHeight = frame.height
        guard abs(nextHeight - headerHeight) > 0.5 else { return }
        headerHeight = nextHeight
        applyScrollOffset(frame.minY)
    }

    private func handleSelectedTabChange(from oldTab: Int, to newTab: Int) {
        guard oldTab != newTab else { return }
        feedContentBottomY = .infinity
        lastProximityLoadMoreAt = .distantPast
        lastPaginationEvalOffset = .greatestFiniteMagnitude
        lastPaginationEvalUptime = 0
        if suppressScrollClamp {
            scheduleClampAfterTabContentLayout()
        }
        guard !isRefreshing, !lockScroll else { return }
        let oldVisual = resolvedTabIndices.firstIndex(of: oldTab) ?? 0
        let newVisual = resolvedTabIndices.firstIndex(of: newTab) ?? 0
        tabSlideDirection = FashTabSwipeMotion.slideDirection(oldIndex: oldVisual, newIndex: newVisual)
        if chromePinnedLatch || reportedTabsPinned {
            profileScrollResetToken += 1
        }
        if !suppressScrollClamp {
            scrollClampRevision += 1
        }
    }

    private func applyScrollToTop(using scrollProxy: ScrollViewProxy) {
        resetProfileScrollChromeState()
        chromePinnedLatch = false
        emitTabsPinnedIfNeeded(pinned: false)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollProxy.scrollTo(ProfileScrollIds.expandedHeader, anchor: .top)
        }
        profileScrollResetToken += 1
        scrollClampRevision += 1
    }

    /// Retries until hero height is known — Home → Profile tab switch often fires before layout is ready.
    private func scheduleApplyPinnedGridScroll(using scrollProxy: ScrollViewProxy) {
        Task { @MainActor in
            for delayMs in [0, 80, 160, 320, 520, 720] {
                if delayMs > 0 {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
                guard !lockScroll else { return }
                applyPinnedGridScroll(using: scrollProxy)
                if headerHeight > 24 { return }
            }
        }
    }

    private func applyPinnedGridScroll(using scrollProxy: ScrollViewProxy) {
        if headerHeight > 24 {
            showBriefBar = true
            showSectionTitle = true
            chromePinnedLatch = true
            emitTabsPinnedIfNeeded(pinned: true)
        }
        PinnedTabScrollReset.scrollToPinnedContent(
            proxy: scrollProxy,
            resetToken: $profileScrollResetToken,
            contentId: listingGridScrollId,
            followUpDelaysMs: [120, 280]
        )
        if suppressScrollClamp {
            scheduleClampAfterTabContentLayout()
        }
    }

    /// After tab body height changes, clamp only if offset is past content end — never scroll up to pinned target.
    private func scheduleClampAfterTabContentLayout() {
        let tab = selectedTab
        Task { @MainActor in
            for delayMs in [0, 80, 180, 320] {
                if delayMs > 0 {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
                guard selectedTab == tab else { return }
                scrollClampRevision += 1
            }
        }
    }

    /// Visual tab order — seller is always selling then sold (Android `tabIndices` for storefront).
    private var resolvedTabIndices: [Int] {
        switch tabSet {
        case .sellerStorefront:
            return [SellerProfileTab.selling.rawValue, SellerProfileTab.sold.rawValue]
        case .ownProfile:
            let base = ProfileListingTab.allCases.map(\.rawValue)
            let filtered = orderedTabIndices.filter { base.contains($0) }
            return filtered.isEmpty ? base : filtered
        }
    }

    private var visualTabIndex: Int {
        resolvedTabIndices.firstIndex(of: selectedTab) ?? 0
    }

    private func evaluateBottomScrollLoadMore(headerMinY: CGFloat) {
        guard loadMoreAtScrollBottom, let onLoadMore else { return }
        guard hasMoreListings, !isLoadingMoreListings, !showGridLoading, !items.isEmpty else { return }
        guard shouldRunPaginationEval(for: headerMinY) else { return }
        guard FeedScrollPaginationPolicy.isAtScrollBottom(
            headerMinY: headerMinY,
            contentBottomY: feedContentBottomY,
            viewportHeight: scrollViewportHeight,
            tolerance: bottomLoadMoreTolerance
        ) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProximityLoadMoreAt) >= 0.5 else { return }
        lastProximityLoadMoreAt = now
        onLoadMore()
    }

    private func evaluateScrollProximityLoadMore(headerMinY: CGFloat) {
        guard let onLoadMore else { return }
        let scrolled = max(0, -headerMinY)
        let minScroll = items.count <= 24
            ? max(headerHeight * 0.2, 48)
            : max(headerHeight * 0.35, 120)
        guard scrolled > minScroll else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProximityLoadMoreAt) >= 0.9 else { return }
        guard FeedScrollPaginationPolicy.shouldLoadMore(
            headerMinY: headerMinY,
            contentBottomY: feedContentBottomY,
            viewportHeight: scrollViewportHeight,
            hasItems: !items.isEmpty,
            hasMore: hasMoreListings,
            isLoadingMore: isLoadingMoreListings,
            isLoadingFirstPage: showGridLoading
        ) else { return }
        lastProximityLoadMoreAt = now
        onLoadMore()
    }

    private func applyScrollOffset(_ offset: CGFloat) {
        let pinned = tabsPinnedAtTop(for: offset)
        let collapseProgress = min(max(-offset / ProfileCollapseMetrics.scrollDistance, 0), 1)
        let wantsSectionTitle = pinned || collapseProgress > 0.55
        let wantsBriefBar: Bool
        if showBriefBar {
            wantsBriefBar = !(collapseProgress < 0.36 && !pinned)
        } else {
            wantsBriefBar = pinned || collapseProgress > 0.52
        }

        if pinned == reportedTabsPinned,
           wantsSectionTitle == showSectionTitle,
           wantsBriefBar == showBriefBar,
           abs(offset - lastScrollOffset) < 2 {
            return
        }
        lastScrollOffset = offset

        emitTabsPinnedIfNeeded(pinned: pinned)
        refreshBriefBarVisibility(collapseProgress: collapseProgress, tabsPinned: pinned)

        if wantsSectionTitle != showSectionTitle {
            showSectionTitle = wantsSectionTitle
        }
    }

    /// Sticky tab row pinned — Android `rememberProfilePromoFooterVisible` (`firstVisibleItemIndex > 0`).
    private func tabsPinnedAtTop(for offset: CGFloat) -> Bool {
        let pinThreshold: CGFloat
        let unpinThreshold: CGFloat
        if headerHeight > 24 {
            pinThreshold = -(headerHeight - 12)
            unpinThreshold = -(headerHeight - 48)
        } else {
            pinThreshold = -ProfileCollapseMetrics.scrollDistance * 0.92
            unpinThreshold = -ProfileCollapseMetrics.scrollDistance * 0.75
        }
        if offset <= pinThreshold {
            chromePinnedLatch = true
            return true
        }
        if chromePinnedLatch {
            if offset > unpinThreshold {
                chromePinnedLatch = false
            }
            return chromePinnedLatch
        }
        return false
    }

    private func emitTabsPinnedIfNeeded(pinned: Bool) {
        guard pinned != reportedTabsPinned else { return }
        reportedTabsPinned = pinned
        onTabsPinnedAtTopChange?(pinned)
    }

    private func refreshBriefBarVisibility(collapseProgress: CGFloat, tabsPinned: Bool) {
        // Android ProfileStickyProfileChrome hysteresis — avoid elastic-scroll flicker.
        if tabsPinned || chromePinnedLatch || collapseProgress > 0.52 {
            if !showBriefBar { withAnimation(FashMotion.overlay) { showBriefBar = true } }
        } else if collapseProgress < 0.36, !tabsPinned, !chromePinnedLatch {
            if showBriefBar { withAnimation(FashMotion.overlay) { showBriefBar = false } }
        }
    }

    @ViewBuilder
    private func stickyChrome(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            if showBriefBar {
                compactHeader()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        scrollProxy.scrollTo(ProfileScrollIds.expandedHeader, anchor: .top)
                    }
                Divider().opacity(0.45)
            }
            ProfileTabSwitcher(
                tabSet: tabSet,
                orderedTabIndices: resolvedTabIndices,
                selectedTab: $selectedTab,
                tabBadgeCounts: tabBadgeCounts
            )
            if showSectionTitle {
                Divider().opacity(0.58)
                Text(tabSet.title(for: selectedTab))
                    .font(FashTypography.titleSmall.weight(.semibold))
                    .foregroundStyle(FashColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, spacing.editorialStart)
                    .padding(.vertical, 8)
            }
        }
        .background(FashColors.screen)
        .shadow(
            color: .black.opacity(showBriefBar || reportedTabsPinned ? 0.08 : 0.04),
            radius: 3,
            y: 1
        )
    }

    @ViewBuilder
    private var profilePaginationFooter: some View {
        if hasMoreListings || isLoadingMoreListings, let onLoadMore {
            FeedLoadMoreFooter(
                enabled: hasMoreListings,
                isLoadingMore: isLoadingMoreListings,
                anchorItemCount: items.count,
                triggersLoadOnAppear: usesFooterBottomLoadMore,
                loadingPresentation: .spinner,
                onLoadMore: onLoadMore
            )
        }
    }

    @ViewBuilder
    private var profileListingGridStatusBlock: some View {
        if showGridLoadRetry, items.isEmpty, let onRetryGridLoad {
            FashEmptyStateView(
                title: L10n.feedLoadError,
                subtitle: L10n.feedLoadStallSubtitle,
                actionTitle: L10n.feedRetry,
                onAction: onRetryGridLoad
            )
            .padding(.vertical, 24)
        } else if showGridLoading {
            profileListingLoadingBlock
                .frame(minHeight: 280)
        } else if items.isEmpty, showEmptyState {
            emptyBlock
        }
    }

    private var profileGridWidthProbe: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: 0)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ListingMasonryContainerWidthKey.self,
                        value: proxy.size.width
                    )
                }
            }
            .onPreferenceChange(ListingMasonryContainerWidthKey.self) { width in
                guard width > 1, abs(width - profileMasonryContainerWidth) > 0.5 else { return }
                profileMasonryContainerWidth = width
                scheduleProfileMasonryLayoutRefresh()
            }
    }

    @ViewBuilder
    private var profileHoistedMasonryGrid: some View {
        ListingMasonryColumnFeed(layout: profileMasonryLayout) { item, index in
            profileListingGridCard(item: item, index: index)
        }
    }

    @ViewBuilder
    private func profileFeedChunkRow(_ chunk: ListingMasonryFeedPages.FeedOrderChunk) -> some View {
        let chunkIds = Set(chunk.entries.map(\.item.id))
        let gap = spacing.spacing2
        HStack(alignment: .top, spacing: gap) {
            profileFeedChunkColumn(
                entries: profileMasonryLayout.left.filter { chunkIds.contains($0.item.id) },
                gap: gap
            )
            profileFeedChunkColumn(
                entries: profileMasonryLayout.right.filter { chunkIds.contains($0.item.id) },
                gap: gap
            )
        }
        .padding(.leading, spacing.editorialStart)
        .padding(.trailing, spacing.editorialEnd)
    }

    @ViewBuilder
    private func profileFeedChunkColumn(
        entries: [(index: Int, item: ListingFeedItem)],
        gap: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(entries, id: \.item.id) { entry in
                profileMasonryTile(item: entry.item, index: entry.index)
            }
        }
        .frame(width: profileMasonryColumnWidth, alignment: .top)
    }

    @ViewBuilder
    private func profileMasonryTile(item: ListingFeedItem, index: Int) -> some View {
        let tileHeight = ListingMasonryGrid.tileHeight(
            columnWidth: profileMasonryColumnWidth,
            item: item
        )
        profileListingGridCard(item: item, index: index)
            .environment(\.listingMasonryColumnWidth, profileMasonryColumnWidth)
            .frame(width: profileMasonryColumnWidth, height: max(1, tileHeight), alignment: .top)
            .clipped()
    }

    @ViewBuilder
    private var profileListingReloadOverlay: some View {
        if isReloadingListings, !isRefreshing {
            FashSkeleton.listingGrid(rows: 1)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, spacing.spacing4)
                .allowsHitTesting(false)
        }
    }

    private func profileListingGridCard(item: ListingFeedItem, index: Int) -> some View {
        ListingGridCard(
            item: item,
            onTap: { onListingClick(item) },
            imageAspectRatio: ListingMasonryGrid.masonryAspectRatio(for: item),
            showQuickActions: showQuickActions,
            statusOverlayLabel: showStatusOverlay
                ? ListingStatusUi.overlayLabel(for: item.listingStatus, suppressActive: suppressActiveStatusOnGrid)
                : nil,
            onLike: onLike.map { h in { h(item) } },
            onSave: onSave.map { h in { h(item) } }
        )
        .onAppear {
            onListingCellVisible?(index, profileMasonryColumnWidth)
            if enableTilePrefetchLoadMore {
                profilePrefetchLoadMoreIfNeeded(appearedIndex: index)
            }
        }
    }

    private func profilePrefetchLoadMoreIfNeeded(appearedIndex: Int) {
        guard enableTilePrefetchLoadMore, let onLoadMore else { return }
        guard hasMoreListings, !isLoadingMoreListings, !showGridLoading else { return }
        if FeedPaginationPolicy.shouldPrefetchNextPage(
            appearedIndex: appearedIndex,
            totalCount: items.count
        ) {
            onLoadMore()
        }
    }

    private var profileListingLoadingBlock: some View {
        FashSkeleton.listingGrid(rows: 3, staggered: true)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, 4)
            .padding(.bottom, 24)
    }

    private var emptyBlock: some View {
        VStack(spacing: 12) {
            FashEmptyStateView(
                title: tabSet.emptyTitle(for: selectedTab),
                subtitle: tabSet.emptySubtitle(for: selectedTab)
            )
            .frame(minHeight: 280)
            if reportedTabsPinned, let footer = tabSet.pinnedFooter(for: selectedTab) {
                Divider().padding(.horizontal, spacing.editorialStart).opacity(0.45)
                Text(footer)
                    .font(FashTypography.bodySmall)
                    .foregroundStyle(FashColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, spacing.editorialStart)
            }
        }
        .padding(.vertical, 24)
    }
}

private enum ProfileScrollIds {
    static let expandedHeader = "profile_expanded_header"
    static let listingGrid = "profile_listing_grid"
    static let coordinateSpaceName = "profileScroll"
}

/// Scrollable tab row with primary underline — Android [ProfileTabSwitcher].
struct ProfileTabSwitcher: View {
    @Environment(\.fashSpacing) private var spacing
    @Namespace private var tabIndicator
    let tabSet: ProfileListingTabSet
    let orderedTabIndices: [Int]
    @Binding var selectedTab: Int
    var tabBadgeCounts: ((Int) -> Int?)? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(orderedTabIndices, id: \.self) { logicalIndex in
                        let selected = selectedTab == logicalIndex
                        Button {
                            withAnimation(FashTabSwipeMotion.contentAnimation) {
                                selectedTab = logicalIndex
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Text(tabLabel(for: logicalIndex))
                                    .font(FashTypography.labelLarge.weight(selected ? .bold : .regular))
                                    .foregroundStyle(selected ? FashColors.textPrimary : FashColors.textSecondary.opacity(0.75))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                ZStack {
                                    Rectangle()
                                        .fill(Color.clear)
                                        .frame(height: 2)
                                    if selected {
                                        Rectangle()
                                            .fill(FashColors.brandPrimary)
                                            .frame(height: 2)
                                            .matchedGeometryEffect(id: "profile_tab_indicator", in: tabIndicator)
                                    }
                                }
                            }
                            .fashScrollableTabChipStyle(minWidth: tabMinWidth)
                        }
                        .buttonStyle(.plain)
                        .id(logicalIndex)
                    }
                }
                .padding(.horizontal, spacing.editorialStart)
                .padding(.vertical, 2)
            }
            .background(FashColors.screen)
            .animation(FashTabSwipeMotion.contentAnimation, value: selectedTab)
            .onChange(of: selectedTab) { _, tab in
                guard orderedTabIndices.contains(tab) else { return }
                scrollProfileTabIntoView(tab, proxy: proxy)
            }
            .onAppear {
                guard orderedTabIndices.contains(selectedTab) else { return }
                scrollProfileTabIntoView(selectedTab, proxy: proxy, animated: false)
            }
            .onChange(of: orderedTabIndices) { _, indices in
                guard indices.contains(selectedTab) else { return }
                scrollProfileTabIntoView(selectedTab, proxy: proxy)
            }
        }
    }

    private func scrollProfileTabIntoView(
        _ tab: Int,
        proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(FashTabSwipeMotion.tabBarAnimation) {
                    proxy.scrollTo(tab, anchor: .center)
                }
            } else {
                proxy.scrollTo(tab, anchor: .center)
            }
        }
    }

    private func tabLabel(for logicalIndex: Int) -> String {
        let title = tabSet.title(for: logicalIndex)
        guard let count = tabBadgeCounts?(logicalIndex), count > 0 else { return title }
        return "\(title) (\(count))"
    }

    private var tabMinWidth: CGFloat {
        let screen = UIScreen.main.bounds.width
        let edge = spacing.editorialStart * 2
        let slots = min(3, CGFloat(max(orderedTabIndices.count, 1)))
        return max((screen - edge) / slots, 108)
    }
}
