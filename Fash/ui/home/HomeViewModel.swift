import Foundation
import Observation
import UIKit

private enum HomeFeedConstants {
    static let followPageSize = 20
    static let huntTodayLimit = 12
    static let tabLoadMorePageSize = 20
    static let staleThreshold: TimeInterval = 60
}

private struct HomeTabFeedState {
    var hasMore = false
    var isLoadingMore = false
    private(set) var window = FeedSlidingWindow()
    private(set) var globalStore = FeedGlobalItemStore()
    private var knownIds: Set<String> = []

    var items: [ListingFeedItem] { window.items }

    /// Logical offset for API pagination — always equals total items ever loaded for this tab.
    var loadMoreOffset: Int { globalStore.isEmpty ? window.logicalStartIndex + window.items.count : globalStore.count }

    mutating func setFirstPage(_ loaded: [ListingFeedItem]) {
        knownIds = globalStore.reset(with: loaded)
        window.reset(with: loaded)
    }

    @discardableResult
    mutating func appendUniquePage(_ page: [ListingFeedItem]) -> Int {
        let before = globalStore.count
        globalStore.appendNew(page, knownIds: &knownIds)
        let freshItems = globalStore.items(from: before, to: globalStore.count)
        if !freshItems.isEmpty { window.appendKnownFresh(freshItems) }
        return freshItems.count
    }

    mutating func trimFront(
        visibleIndex: Int,
        columnWidth: CGFloat,
        columnAssignments: [String: Bool],
        policy: FeedSlidingWindowPolicy
    ) -> FeedSlidingWindow.TrimResult? {
        window.trimFrontIfNeeded(
            visibleIndex: visibleIndex,
            columnWidth: columnWidth,
            policy: policy,
            columnAssignments: columnAssignments
        )
    }

    @discardableResult
    mutating func trimBack(count: Int) -> Int {
        window.trimBack(count: count)
    }

    /// Restore evicted items from the global store when the user scrolls back up.
    mutating func restoreFromGlobal(
        targetGlobalStart: Int,
        columnWidth: CGFloat,
        columnAssignments: [String: Bool]
    ) -> FeedSlidingWindow.PrependResult? {
        let currentStart = window.logicalStartIndex
        guard currentStart > 0, targetGlobalStart < currentStart else { return nil }
        let toRestore = globalStore.items(from: max(0, targetGlobalStart), to: currentStart)
        guard !toRestore.isEmpty else { return nil }
        let deltaY = FeedSlidingWindow.exactMasonryHeight(
            items: toRestore, columnWidth: columnWidth, columnAssignments: columnAssignments
        )
        window.restoreFront(toRestore)
        return FeedSlidingWindow.PrependResult(addedCount: toRestore.count, scrollDeltaY: deltaY)
    }

    @discardableResult
    mutating func patchItem(withId id: String, transform: (ListingFeedItem) -> ListingFeedItem) -> Bool {
        let patched = window.patchItem(withId: id, transform: transform)
        globalStore.patchItem(withId: id, transform: transform)
        return patched
    }

    var isEmpty: Bool { window.items.isEmpty }
}

@Observable
@MainActor
final class HomeViewModel {
    var isShellLoading = false
    var isRefreshing = false
    var items: [ListingFeedItem] = []
    var errorMessage: String?
    var selectedFeedTabKey = HomeFeedTabKeys.huntToday
    var featuredSellers: [FeaturedSellerItem] = []
    var featuredSellersLoading = false
    var promoSlides: [AppAdvertisingSlideItem] = []
    var guestReengagementSlides: [AppAdvertisingSlideItem] = []
    var homeUxPersonalization = HomeUxPersonalization()
    var tabsLoading: Set<String> = []
    var tabsLoadError: Set<String> = []
    var tabsLoadStalled: Set<String> = []
    /// Per-tab failure detail for empty-state subtitle (network / HTTP / parse).
    private var tabLoadErrorDetails: [String: String] = [:]
    /// Sticky flag — once guest browse is entered, keep using public APIs even if a caller passes isGuestMode=false.
    private(set) var preferPublicBrowse = false
    var followingHasMore = false
    var isLoadingMoreFollowing = false
    var buyerStats = BuyerHomeStats()
    var showSizingBanner = false
    private(set) var homeScrollToTopToken = 0
    /// Tab tap/swipe — scroll to pinned tab row + feed start (not full header).
    private(set) var homeScrollToFeedTopToken = 0
    private(set) var homePinnedScrollResetToken = 0
    private(set) var homeTabBarScrollToken = 0
    var homeFeedTrimToken = 0
    private(set) var homeFeedTrimSignedDeltaY: CGFloat = 0
    /// True while top-of-window content is being loaded; drives the grid's top loading spinner.
    var homeFeedTopLoading = false
    /// Incremented when blank-top detection fires — forces the masonry grid to relayout from scratch.
    var homeFeedRepaintToken = 0
    /// Non-nil during the tap-to-top suppression window — tells FeedScrollTrimCompensator to skip.
    var homeFeedCompensatorSuppressedUntil: Date? = nil
    /// Last column width passed to scheduleSectionTabTrim — used for immediate scroll-to-top restore.
    private var lastKnownFeedColumnWidth: CGFloat = 160

    var dailyOutfitDrop: [OutfitSetCard] { sections.dailyOutfitDrop }

    private var sections = HomeRecommendationSections()
    private var followingWindow = FeedSlidingWindow()
    private var followingItemIds = Set<String>()
    private var followingNextCursor: String?
    private var loadedTabs: Set<String> = []
    private var recommendationSectionsFetched = false
    private var tabLoadTasks: [String: Task<Void, Never>] = [:]
    private var tabLoadGeneration: [String: UInt] = [:]
    private let tabStallWatch = FeedLoadStallWatch()
    private var homeUxApplied = false
    private var lastSuccessfulRefreshAt: Date?
    private var lastFollowFeedLoadMoreAt: Date?
    private var followFeedRateLimitUntil: Date?
    private var sectionTabLoadMoreAt: [String: Date] = [:]
    private var sectionTabRateLimitUntil: [String: Date] = [:]
    private var followingDuplicatePageCount = 0
    private var followingTrimTask: Task<Void, Never>?
    private var sectionTabTrimTask: Task<Void, Never>?
    private var tabFeedState: [String: HomeTabFeedState] = [:]
    private var sectionLoadMoreTasks: [String: Task<Void, Never>] = [:]

    /// Scroll boundary from [HomeFeedScrollCoordinator] — gates Following pagination while scrolling up.
    @ObservationIgnored
    var homeScrollBoundary: HomeFeedScrollBoundary?

    var selectedFeedTab: HomeFeedTab {
        HomeFeedTab(rawValue: selectedFeedTabKey) ?? .huntToday
    }

    func orderedTabs(isGuestMode: Bool) -> [HomeFeedTab] {
        UxPersonalizationMapping.orderedHomeFeedTabs(
            isGuestBrowse: isGuestMode,
            tabOrderKeys: homeUxPersonalization.tabOrder
        )
    }

    func isTabLoading(_ tab: HomeFeedTab) -> Bool {
        tabsLoading.contains(tab.rawValue)
    }

    func isTabLoadError(_ tab: HomeFeedTab) -> Bool {
        tabsLoadError.contains(tab.rawValue)
    }

    func isTabLoadStalled(_ tab: HomeFeedTab) -> Bool {
        tabsLoadStalled.contains(tab.rawValue)
    }

    func tabLoadErrorDetail(for tab: HomeFeedTab) -> String? {
        let detail = tabLoadErrorDetails[tab.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? nil : detail
    }

    func hasMore(for tab: HomeFeedTab) -> Bool {
        if tab == .following { return followingHasMore }
        return tabFeedState[tab.rawValue]?.hasMore ?? false
    }

    func isLoadingMore(for tab: HomeFeedTab) -> Bool {
        if tab == .following { return isLoadingMoreFollowing }
        return tabFeedState[tab.rawValue]?.isLoadingMore ?? false
    }

    func loadMore(deps: AppDependencies, isGuestMode: Bool, fromScrollEdge: Bool = false) {
        let tab = selectedFeedTab
        if tab == .following {
            loadMoreFollowing(deps: deps, isGuestMode: isGuestMode, fromScrollEdge: fromScrollEdge)
            return
        }
        if isGuestMode && tab.requiresAuth { return }
        loadMoreSectionTab(tab, deps: deps, isGuestMode: isGuestMode)
    }

    /// Following tab only — idle window trim for memory (no pagination trigger).
    func scheduleFollowingWindowTrim(visibleIndex: Int, columnWidth: CGFloat, columnAssignments: [String: Bool] = [:]) {
        guard selectedFeedTab == .following else { return }
        scheduleFollowingWindowTrimDeferred(visibleIndex: visibleIndex, columnWidth: columnWidth, columnAssignments: columnAssignments)
    }

    /// Section tabs (huntToday, forYou, etc.) — adaptive sliding window with scroll-back recovery.
    func scheduleSectionTabTrim(visibleIndex: Int, columnWidth: CGFloat, columnAssignments: [String: Bool] = [:]) {
        lastKnownFeedColumnWidth = columnWidth
        let tab = selectedFeedTab
        guard tab != .following else { return }
        sectionTabTrimTask?.cancel()
        sectionTabTrimTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            guard selectedFeedTab == tab else { return }
            guard let boundary = homeScrollBoundary, !boundary.isUserInteracting else { return }
            let assignments = columnAssignments
            let policy = adaptiveSectionTabPolicy(columnWidth: columnWidth)
            var state = tabFeedState[tab.rawValue] ?? HomeTabFeedState()

            // Scroll-back: restore evicted items when near the window boundary.
            if visibleIndex <= policy.backfillVisibleThreshold && state.window.logicalStartIndex > 0 {
                let targetStart = max(0, state.window.logicalStartIndex - policy.bufferBefore)

                // Show top loading indicator; give SwiftUI one frame to render it before content changes.
                homeFeedTopLoading = true
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, selectedFeedTab == tab else { homeFeedTopLoading = false; return }

                if let restore = state.restoreFromGlobal(
                    targetGlobalStart: targetStart,
                    columnWidth: columnWidth,
                    columnAssignments: assignments
                ) {
                    // Bidirectional window: trim same count from tail as prepended at head.
                    state.trimBack(count: restore.addedCount)
                    tabFeedState[tab.rawValue] = state
                    syncItemsForSelectedTab()
                    // Compensate scroll: prepending content above shifts the viewport.
                    // The safety guard in applyCompensationNow skips this when already at/near top.
                    homeFeedTrimSignedDeltaY = restore.scrollDeltaY
                    homeFeedTrimToken += 1
                    FeedPerformance.log(
                        "Home \(tab) restore +\(restore.addedCount) trim-back window=\(state.items.count) start=\(state.window.logicalStartIndex)"
                    )
                }

                // Brief hold so loading indicator is visible, then dismiss.
                try? await Task.sleep(for: .milliseconds(80))
                homeFeedTopLoading = false
                return
            }

            // Forward scroll: trim items far above the viewport.
            guard let trim = state.trimFront(
                visibleIndex: visibleIndex,
                columnWidth: columnWidth,
                columnAssignments: assignments,
                policy: policy
            ) else { return }
            tabFeedState[tab.rawValue] = state
            syncItemsForSelectedTab()
            homeFeedTrimSignedDeltaY = -trim.scrollDeltaY
            homeFeedTrimToken += 1
            FeedPerformance.log(
                "Home \(tab) trim -\(trim.removedCount) window=\(state.items.count) offset=\(state.loadMoreOffset)"
            )
        }
    }

    /// Called when the OS issues a memory warning — flush non-visible image cache entries.
    func handleMemoryWarning() {
        let tab = selectedFeedTab
        let visibleCount = tabFeedState[tab.rawValue]?.items.count ?? followingWindow.items.count
        FeedPerformance.log("Home memory warning: visible tab=\(tab) items=\(visibleCount)")
    }

    /// Main tab Home visible — reload default feed tab if UI is empty without an active load.
    func ensureSelectedFeedTabLoaded(deps: AppDependencies, isGuestMode: Bool) {
        normalizeSelectedFeedTab(isGuestMode: isGuestMode, deps: deps)
        let tab = selectedFeedTab
        if isGuestMode && tab.requiresAuth { return }
        syncVisibleItemsForTab(tab)
        if loadedTabs.contains(tab.rawValue) {
            syncItemsForSelectedTab()
            return
        }
        if items.isEmpty, !isTabLoading(tab), !isTabLoadError(tab) {
            ensureTabLoaded(tab, deps: deps, isGuestMode: isGuestMode, force: false)
        }
    }

    func onGuestBrowseEntered(deps: AppDependencies, forceReset: Bool = true) {
        preferPublicBrowse = true
        deps.isGuestBrowseActive = true
        let huntTodayEmpty = tabFeedState[HomeFeedTabKeys.huntToday]?.isEmpty ?? true
        if !forceReset,
           loadedTabs.contains(HomeFeedTabKeys.huntToday),
           !huntTodayEmpty {
            normalizeSelectedFeedTab(isGuestMode: true, deps: deps)
            syncItemsForSelectedTab()
            tabsLoadError.remove(HomeFeedTabKeys.huntToday)
            tabsLoadStalled.remove(HomeFeedTabKeys.huntToday)
            if items.isEmpty {
                ensureTabLoaded(.huntToday, deps: deps, isGuestMode: true, force: false)
            }
            // Hunt Today may already be warm from launch — still ensure the featured rail.
            ensureFeaturedSellersLoaded(deps: deps, isGuestMode: true)
            return
        }
        if !forceReset,
           tabsLoading.contains(HomeFeedTabKeys.huntToday),
           huntTodayEmpty,
           !tabsLoadError.contains(HomeFeedTabKeys.huntToday) {
            normalizeSelectedFeedTab(isGuestMode: true, deps: deps)
            ensureFeaturedSellersLoaded(deps: deps, isGuestMode: true)
            return
        }
        let needsErrorRecovery = !forceReset
            && huntTodayEmpty
            && (tabsLoadError.contains(HomeFeedTabKeys.huntToday) || tabsLoadStalled.contains(HomeFeedTabKeys.huntToday))
        if !forceReset && !needsErrorRecovery {
            // Orphan empty state after a cancelled gate — kick a load without wiping shell chrome.
            if huntTodayEmpty,
               !tabsLoading.contains(HomeFeedTabKeys.huntToday),
               !loadedTabs.contains(HomeFeedTabKeys.huntToday) {
                normalizeSelectedFeedTab(isGuestMode: true, deps: deps)
                ensureTabLoaded(.huntToday, deps: deps, isGuestMode: true, force: false)
            }
            ensureFeaturedSellersLoaded(deps: deps, isGuestMode: true)
            return
        }
        // Stale-while-revalidate — keep any warm featured rail visible (Android onGuestBrowseEntered).
        if featuredSellers.isEmpty {
            featuredSellersLoading = true
        }
        deps.uxTabTracker.closeActiveTab()
        deps.feedEventReporter.flush()
        deps.feedEventReporter.clearPending()
        homeUxApplied = false
        homeUxPersonalization = HomeUxPersonalization()
        invalidateAllTabFeeds()
        selectedFeedTabKey = HomeFeedTabKeys.huntToday
        items = []
        errorMessage = nil
        followingWindow.reset(with: [])
        followingItemIds = []
        followingNextCursor = nil
        followingHasMore = false
        followingDuplicatePageCount = 0
        buyerStats = BuyerHomeStats()
        showSizingBanner = false
        ensureTabLoaded(.huntToday, deps: deps, isGuestMode: true, force: true)
        Task { await loadFeaturedSellers(deps: deps, isGuestMode: true) }
    }

    /// Kick public/auth featured-sellers fetch when the rail is empty and not already loading.
    func ensureFeaturedSellersLoaded(deps: AppDependencies, isGuestMode: Bool) {
        guard featuredSellers.isEmpty, !featuredSellersLoading else { return }
        featuredSellersLoading = true
        Task { await loadFeaturedSellers(deps: deps, isGuestMode: isGuestMode) }
    }

    func clearCachesForSignedOutUser(deps: AppDependencies) {
        preferPublicBrowse = true
        deps.isGuestBrowseActive = true
        deps.uxTabTracker.closeActiveTab()
        deps.uxTabTracker.flush()
        deps.feedEventReporter.flush()
        deps.feedEventReporter.clearPending()
        onGuestBrowseEntered(deps: deps)
        isShellLoading = false
        isRefreshing = false
        isLoadingMoreFollowing = false
        buyerStats = BuyerHomeStats()
        showSizingBanner = false
        HomeSizingBannerPreference.reset()
        lastSuccessfulRefreshAt = nil
    }

    /// Call after a successful login so Home stops using public browse attestation.
    func clearGuestBrowsePreference() {
        preferPublicBrowse = false
    }

    /// Prefer public browse for guest UI, sticky guest flag, or missing auth session (avoids 401 "Cần đăng nhập").
    private func resolvePublicBrowse(_ isGuestMode: Bool, deps: AppDependencies) -> Bool {
        if isGuestMode || preferPublicBrowse || deps.isGuestBrowseActive { return true }
        return deps.authSessionStore.read() == nil
    }

    func selectFeedTab(_ tab: HomeFeedTab, deps: AppDependencies, isGuestMode: Bool) {
        if selectedFeedTab == tab {
            requestScrollHomeToTop()
            ensureSelectedFeedTabLoaded(deps: deps, isGuestMode: isGuestMode)
            return
        }
        openFeedTab(tab, deps: deps, isGuestMode: isGuestMode)
    }

    private func openFeedTab(_ tab: HomeFeedTab, deps: AppDependencies, isGuestMode: Bool) {
        deps.uxTabTracker.onTabOpened(scope: "home", tabKey: UxPersonalizationMapping.uxTabKey(for: tab))
        selectedFeedTabKey = tab.rawValue
        syncVisibleItemsForTab(tab)
        requestScrollHomeFeedToTop()
        ensureTabLoaded(tab, deps: deps, isGuestMode: isGuestMode)
        homeTabBarScrollToken &+= 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard selectedFeedTab == tab else { return }
            prefetchAdjacentTabs(around: tab, deps: deps, isGuestMode: isGuestMode)
        }
    }

    /// Bottom-nav re-tap / same-tab reselect — scroll to full header top (Android `requestScrollHomeToTop`).
    func requestScrollHomeToTop() {
        homeScrollToTopToken &+= 1
        sectionTabTrimTask?.cancel()
        // Suppress the compensator for 1.2s so any stale restore token cannot push the viewport
        // back down after PinnedTabScrollOffsetFixer sets it to the true top.
        homeFeedCompensatorSuppressedUntil = Date.now + 1.2
        immediateRestoreCurrentSectionTabIfNeeded()
    }

    /// Called by blank-top detection when items exist but the masonry appears empty.
    /// Forces a full grid relayout without touching item data.
    func forceRepaintFeed() {
        guard !items.isEmpty else { return }
        homeFeedRepaintToken &+= 1
    }

    /// Called when the masonry layout rebuild detects blank chunks at visible positions.
    /// First response: force a full relayout. The blank-top detector in HomeFeedScrollCoordinator
    /// escalates to retryTab if the blank persists after the repaint settles.
    func onFeedLayoutGapDetected(_ gaps: [FeedLayoutGap]) {
        guard !gaps.isEmpty, !items.isEmpty else { return }
        FeedPerformance.log("[HomeFeed] GapDetected → forceRepaintFeed gaps=\(gaps.count)")
        forceRepaintFeed()
    }

    /// Horizontal swipe or different tab tap — align pinned tabs + first rows of that tab.
    func requestScrollHomeFeedToTop() {
        homeScrollToFeedTopToken &+= 1
        sectionTabTrimTask?.cancel()
        homeFeedCompensatorSuppressedUntil = Date.now + 1.2
        immediateRestoreCurrentSectionTabIfNeeded()
    }

    /// Restore all front-trimmed items for the current section tab without applying scroll compensation.
    /// Called on tab-bar tap-to-top and tab-switch so items 0..N are present before the scroll lands.
    /// No `homeFeedTrimToken` increment → `FeedScrollTrimCompensator` does not fire.
    private func immediateRestoreCurrentSectionTabIfNeeded() {
        let tab = selectedFeedTab
        guard tab != .following else { return }
        var state = tabFeedState[tab.rawValue] ?? HomeTabFeedState()
        guard state.window.logicalStartIndex > 0 else { return }
        guard let restore = state.restoreFromGlobal(
            targetGlobalStart: 0,
            columnWidth: max(1, lastKnownFeedColumnWidth),
            columnAssignments: [:]
        ) else { return }
        // Bidirectional: trim same count from back to keep window bounded.
        state.trimBack(count: restore.addedCount)
        tabFeedState[tab.rawValue] = state
        syncItemsForSelectedTab()
    }

    func normalizeSelectedFeedTab(isGuestMode: Bool, deps: AppDependencies) {
        if isGuestMode {
            if selectedFeedTab != .huntToday {
                deps.uxTabTracker.closeActiveTab()
                selectedFeedTabKey = HomeFeedTabKeys.huntToday
                syncItemsForSelectedTab()
            }
            return
        }
        let allowed = HomeFeedTab.tabsFor(isGuestBrowse: false)
        if !allowed.contains(selectedFeedTab) {
            resetToHuntToday(deps: deps, isGuestMode: isGuestMode, forceReload: true)
        }
    }

    /// Launch gate — prefetch active tab + shell chrome while the waiting screen is visible.
    func awaitLaunchReady(
        deps: AppDependencies,
        isGuestMode: Bool,
        launchProgress: LaunchWaitingProgress? = nil
    ) async {
        if isGuestMode {
            preferPublicBrowse = true
            deps.isGuestBrowseActive = true
        }
        normalizeSelectedFeedTab(isGuestMode: isGuestMode, deps: deps)
        await awaitSelectedFeedTab(deps: deps, isGuestMode: isGuestMode, force: true)
        launchProgress?.completeHomeStep()
        await loadShellEnrichment(deps: deps, isGuestMode: isGuestMode, launchProgress: launchProgress)
        prefetchAdjacentTabs(around: selectedFeedTab, deps: deps, isGuestMode: isGuestMode)
        lastSuccessfulRefreshAt = Date()
    }

    func loadShell(deps: AppDependencies, isGuestMode: Bool, skipIfFresh: Bool = false, launchProgress: LaunchWaitingProgress? = nil) async {
        if skipIfFresh, isLaunchShellFresh {
            normalizeSelectedFeedTab(isGuestMode: isGuestMode, deps: deps)
            ensureTabLoaded(selectedFeedTab, deps: deps, isGuestMode: isGuestMode)
            if featuredSellers.isEmpty, !featuredSellersLoading {
                await loadFeaturedSellers(deps: deps, isGuestMode: isGuestMode)
            }
            return
        }
        isShellLoading = true
        errorMessage = nil
        defer { isShellLoading = false }

        normalizeSelectedFeedTab(isGuestMode: isGuestMode, deps: deps)
        await awaitSelectedFeedTab(deps: deps, isGuestMode: isGuestMode, force: true)
        launchProgress?.completeHomeStep()
        await loadShellEnrichment(deps: deps, isGuestMode: isGuestMode, launchProgress: launchProgress)
        lastSuccessfulRefreshAt = Date()
    }

    private func scheduleShellEnrichment(deps: AppDependencies, isGuestMode: Bool) {
        Task { await loadShellEnrichment(deps: deps, isGuestMode: isGuestMode, launchProgress: nil) }
    }

    private func loadShellEnrichment(
        deps: AppDependencies,
        isGuestMode: Bool,
        launchProgress: LaunchWaitingProgress? = nil
    ) async {
        async let sellersTask: Void = loadFeaturedSellers(deps: deps, isGuestMode: isGuestMode)

        if !isGuestMode {
            async let ux: Void = {
                await loadUxPersonalization(deps: deps, isGuestMode: isGuestMode)
                await MainActor.run { launchProgress?.completeHomeStep() }
            }()
            async let sections: Void = {
                _ = await prefetchRecommendationSections(deps: deps, isGuestMode: isGuestMode)
                await MainActor.run { launchProgress?.completeHomeStep() }
            }()
            async let stats: Void = {
                _ = await loadBuyerHomeStats(deps: deps, isGuestMode: isGuestMode)
                await MainActor.run { launchProgress?.completeHomeStep() }
            }()
            async let sizing: Void = {
                await refreshSizingBannerState(deps: deps, isGuestMode: isGuestMode)
                await MainActor.run { launchProgress?.completeHomeStep() }
            }()
            _ = await (ux, sections, stats, sizing, sellersTask)
        } else {
            await sellersTask
        }
        launchProgress?.completeHomeStep()

        await loadPromoSlides(deps: deps, isGuestMode: isGuestMode)
        launchProgress?.completeHomeStep()

        prefetchAdjacentTabs(around: selectedFeedTab, deps: deps, isGuestMode: isGuestMode)
        launchProgress?.completeHomeStep()
    }

    func loadFeaturedSellers(deps: AppDependencies, isGuestMode: Bool) async {
        // Stale-while-revalidate — keep "Shop nên ghé" visible during nav re-tap / pull-to-refresh.
        let shouldShowLoadingShell = featuredSellers.isEmpty
        if shouldShowLoadingShell {
            featuredSellersLoading = true
        }
        defer {
            if shouldShowLoadingShell {
                featuredSellersLoading = false
            }
        }
        switch await fetchFeaturedSellersWithRetry(deps: deps, isGuestMode: isGuestMode) {
        case .success(let sellers):
            let ready = FeaturedSellerItem.shopReady(sellers)
            // Prefer shop-ready rows; if the API returned only sparse profiles, still show the rail.
            featuredSellers = ready.isEmpty ? sellers : ready
        case .failure:
            break
        }
    }

    private func fetchFeaturedSellersWithRetry(
        deps: AppDependencies,
        isGuestMode: Bool
    ) async -> Result<[FeaturedSellerItem], Error> {
        func fetchOnce() async -> Result<[FeaturedSellerItem], Error> {
            await deps.searchRepository.getFeaturedSellers(
                limit: 12,
                publicBrowse: resolvePublicBrowse(isGuestMode, deps: deps)
            )
        }
        var result = await fetchOnce()
        if case .failure = result {
            try? await Task.sleep(for: .milliseconds(400))
            result = await fetchOnce()
        }
        return result
    }

    private func awaitSelectedFeedTab(
        deps: AppDependencies,
        isGuestMode: Bool,
        force: Bool
    ) async {
        let tab = selectedFeedTab
        if isGuestMode && tab.requiresAuth { return }
        tabLoadTasks[tab.rawValue]?.cancel()
        tabLoadTasks[tab.rawValue] = nil
        beginTabLoad(tab)
        setTabError(tab, false)
        let generation = nextTabLoadGeneration(for: tab)
        var succeeded = false
        defer {
            // Ignore stale completions after ensureTabLoaded / continueLaunch advanced the generation.
            // Use if (not guard-return) — Swift forbids transferring control out of defer.
            if tabLoadGeneration[tab.rawValue] == generation {
                if Task.isCancelled {
                    // Response may have landed before cancel was observed — keep successful data.
                    if succeeded || !itemsForTab(tab).isEmpty {
                        finishTabLoad(tab, succeeded: true)
                    } else {
                        clearTabLoadingWithoutMarkingLoaded(tab)
                    }
                } else {
                    finishTabLoad(tab, succeeded: succeeded)
                }
                tabLoadTasks[tab.rawValue] = nil
            }
        }
        succeeded = await loadTab(tab, deps: deps, isGuestMode: isGuestMode, force: force)
    }

    /// After the splash home-gate times out, keep loading the visible tab in the background.
    func continueLaunchLoadIfNeeded(deps: AppDependencies, isGuestMode: Bool) {
        let tab = selectedFeedTab
        if isGuestMode && tab.requiresAuth { return }
        // Load finished (or cancelled after data arrived) — just bind UI.
        if !itemsForTab(tab).isEmpty {
            loadedTabs.insert(tab.rawValue)
            tabsLoadError.remove(tab.rawValue)
            tabsLoadStalled.remove(tab.rawValue)
            setTabLoading(tab, false)
            syncItemsForSelectedTab()
            ensureFeaturedSellersLoaded(deps: deps, isGuestMode: isGuestMode)
            return
        }
        if loadedTabs.contains(tab.rawValue) {
            ensureFeaturedSellersLoaded(deps: deps, isGuestMode: isGuestMode)
            return
        }
        // In-flight awaitLaunchReady / ensureTabLoaded — do not force-cancel and restart.
        if tabsLoading.contains(tab.rawValue) {
            ensureFeaturedSellersLoaded(deps: deps, isGuestMode: isGuestMode)
            return
        }
        if let existing = tabLoadTasks[tab.rawValue], !existing.isCancelled {
            ensureFeaturedSellersLoaded(deps: deps, isGuestMode: isGuestMode)
            return
        }
        isShellLoading = false
        ensureTabLoaded(tab, deps: deps, isGuestMode: isGuestMode, force: true)
        ensureFeaturedSellersLoaded(deps: deps, isGuestMode: isGuestMode)
    }

    /// End of maintenance — drop hung in-flight flags and fetch a fresh Home.
    func reloadAfterMaintenance(deps: AppDependencies, isGuestMode: Bool) {
        lastSuccessfulRefreshAt = nil
        isRefreshing = false
        isShellLoading = false
        invalidateAllTabFeeds()
        ensureTabLoaded(selectedFeedTab, deps: deps, isGuestMode: isGuestMode, force: true)
    }

    func pullToRefresh(deps: AppDependencies, isGuestMode: Bool = false) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let tabToReload = selectedFeedTab

        // Pinterest-style: refresh feed first so spinner dismisses when listings update; chrome loads after.
        await reloadFeedTab(tabToReload, deps: deps, isGuestMode: isGuestMode)
        if tabToReload == selectedFeedTab {
            syncItemsForSelectedTab()
        }
        lastSuccessfulRefreshAt = Date()

        Task { @MainActor in
            async let sellers: Void = loadFeaturedSellers(deps: deps, isGuestMode: isGuestMode)
            if !isGuestMode {
                async let stats: Void = loadBuyerHomeStats(deps: deps, isGuestMode: isGuestMode)
                async let sizing: Void = refreshSizingBannerState(deps: deps, isGuestMode: isGuestMode)
                _ = await (stats, sizing)
            }
            _ = await sellers
            await loadPromoSlides(deps: deps, isGuestMode: isGuestMode)
            try? await Task.sleep(for: .milliseconds(220))
            guard selectedFeedTab == tabToReload else { return }
            prefetchAdjacentTabs(around: selectedFeedTab, deps: deps, isGuestMode: isGuestMode)
        }
    }

    private func loadPromoSlides(deps: AppDependencies, isGuestMode: Bool) async {
        if isGuestMode {
            async let mainR = deps.advertisingRepository.getSlides(
                placement: AdvertisingPlacements.promoSliderMain,
                publicBrowse: true
            )
            async let bannerR = deps.advertisingRepository.getSlides(
                placement: AdvertisingPlacements.guestHomeBanner,
                publicBrowse: true
            )
            async let reengR = deps.advertisingRepository.getSlides(
                placement: AdvertisingPlacements.guestReengagement,
                publicBrowse: true
            )
            let main = (try? await mainR.get())?.items ?? []
            let banner = (try? await bannerR.get())?.items ?? []
            let reeng = (try? await reengR.get())?.items ?? []
            promoSlides = banner + main
            guestReengagementSlides = reeng
            if let first = reeng.first {
                GuestLocalReengagementScheduler.shared.updateReminderCopy(
                    title: first.title,
                    body: first.subtitle
                )
            }
        } else if case .success(let slides) = await deps.advertisingRepository.getSlides(publicBrowse: false) {
            promoSlides = slides.items
            guestReengagementSlides = []
        }
    }

    func retryTab(_ tab: HomeFeedTab, deps: AppDependencies, isGuestMode: Bool) {
        tabsLoadStalled.remove(tab.rawValue)
        loadedTabs.remove(tab.rawValue)
        if HomeFeedTab.recommendationSectionTabs.contains(tab) {
            recommendationSectionsFetched = false
            HomeFeedTab.recommendationSectionTabs.forEach { loadedTabs.remove($0.rawValue) }
        }
        ensureTabLoaded(tab, deps: deps, isGuestMode: isGuestMode, force: true)
    }

    func loadMoreFollowing(deps: AppDependencies, isGuestMode: Bool, fromScrollEdge: Bool = false) {
        guard !isGuestMode else { return }
        guard selectedFeedTab == .following else { return }
        guard !isLoadingMoreFollowing, followingHasMore else { return }
        guard !isShellLoading, !isRefreshing, !isTabLoading(.following) else { return }
        if !fromScrollEdge {
            guard homeScrollBoundary?.allowsFollowingLoadMore ?? true else { return }
        }
        if let last = lastFollowFeedLoadMoreAt, Date().timeIntervalSince(last) < FeedLoadMoreThrottle.followingInterval { return }
        if FeedLoadMoreThrottle.isBlocked(until: followFeedRateLimitUntil) { return }
        lastFollowFeedLoadMoreAt = Date()
        isLoadingMoreFollowing = true
        let cursor = followingNextCursor
        let offsetFallback = cursor == nil ? followingWindow.items.count : nil
        Task {
            defer { isLoadingMoreFollowing = false }
            let result = await FeedPerformance.measure("Home following loadMore cursor=\(cursor ?? "offset:\(offsetFallback ?? 0)")") {
                await fetchFollowingPage(deps: deps, cursor: cursor, offsetFallback: offsetFallback)
            }
            guard case .success(let page) = result else {
                if case .failure(let error) = result,
                   let blocked = FeedLoadMoreThrottle.blockedUntil(after: error) {
                    followFeedRateLimitUntil = blocked
                }
                return
            }
            followingHasMore = page.hasMore
            followingNextCursor = page.nextCursor
            if page.items.isEmpty {
                followingHasMore = false
                followingDuplicatePageCount = 0
                if selectedFeedTab == .following { syncItemsForSelectedTab() }
                return
            }
            let added = followingWindow.appendUnique(page.items, knownIds: &followingItemIds)
            guard added > 0 else {
                followingDuplicatePageCount += 1
                if followingDuplicatePageCount >= 2 || page.items.isEmpty {
                    followingHasMore = false
                }
                if selectedFeedTab == .following { syncItemsForSelectedTab() }
                return
            }
            followingDuplicatePageCount = 0
            if selectedFeedTab == .following {
                syncItemsForSelectedTab()
            }
            FeedPerformance.log("Home following append +\(added) window=\(followingWindow.items.count) hasMore=\(followingHasMore)")
        }
    }

    /// Idle sliding-window trim for Following (pagination is footer-only at scroll bottom).
    func notifyFollowingCellVisible(
        index: Int,
        columnWidth: CGFloat,
        deps: AppDependencies,
        isGuestMode: Bool
    ) {
        guard selectedFeedTab == .following else { return }
        scheduleFollowingWindowTrimDeferred(visibleIndex: index, columnWidth: columnWidth)
    }

    private func adaptiveSectionTabPolicy(columnWidth: CGFloat) -> FeedSlidingWindowPolicy {
        let vpH = UIScreen.main.bounds.height
        let itemH = max(120, columnWidth * 1.2)
        let itemsPerVP = max(4, Int(vpH / itemH * 2))
        let maxItems = min(300, max(80, itemsPerVP * 6))
        let buffer = max(24, itemsPerVP * 2)
        let backfill = max(10, itemsPerVP)
        return FeedSlidingWindowPolicy(
            maxItems: maxItems,
            bufferBefore: buffer,
            bufferAfter: buffer,
            backfillVisibleThreshold: backfill
        )
    }

    private func scheduleFollowingWindowTrimDeferred(visibleIndex: Int, columnWidth: CGFloat, columnAssignments: [String: Bool] = [:]) {
        followingTrimTask?.cancel()
        followingTrimTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            guard selectedFeedTab == .following else { return }
            guard let boundary = homeScrollBoundary, !boundary.isUserInteracting else { return }
            let assignments = columnAssignments
            guard let trim = followingWindow.trimFrontIfNeeded(
                visibleIndex: visibleIndex,
                columnWidth: columnWidth,
                policy: .homeFollowing,
                columnAssignments: assignments
            ) else { return }
            syncItemsForSelectedTab()
            homeFeedTrimSignedDeltaY = -trim.scrollDeltaY
            homeFeedTrimToken += 1
            FeedPerformance.log(
                "Home following trim -\(trim.removedCount) window=\(followingWindow.items.count)"
            )
        }
    }

    /// @deprecated — pagination is footer-only; trim via [scheduleFollowingWindowTrim].
    func requestLoadMoreFollowingIfNeeded(
        appearedIndex: Int,
        deps: AppDependencies,
        isGuestMode: Bool
    ) {
        guard selectedFeedTab == .following else { return }
        guard !isShellLoading, !isRefreshing, !isTabLoading(.following) else { return }
        guard FeedPaginationPolicy.shouldPrefetchNextPage(
            appearedIndex: appearedIndex,
            totalCount: followingWindow.items.count
        ) else { return }
        loadMoreFollowing(deps: deps, isGuestMode: isGuestMode)
    }

    /// Brand footer only when the active tab finished loading and has no more pages.
    func showsHomeBrandFooter(isGuestMode: Bool) -> Bool {
        let tab = selectedFeedTab
        if isGuestMode && tab.requiresAuth { return false }
        if items.isEmpty { return false }
        if isShellLoading || isTabLoading(tab) { return false }
        if tab == .following {
            return !followingHasMore && !isLoadingMoreFollowing
        }
        return hasMore(for: tab) == false && !isLoadingMore(for: tab) && loadedTabs.contains(tab.rawValue)
    }

    func recordView(item: ListingFeedItem, position: Int, surface: String, deps: AppDependencies) {
        deps.feedEventReporter.impression(listingId: item.id, surface: surface, position: position)
        Task { _ = await deps.listingRepository.recordView(listingId: item.id) }
    }

    func recordDwell(item: ListingFeedItem, surface: String, position: Int, dwellMs: Int, deps: AppDependencies) {
        guard dwellMs >= 800 else { return }
        deps.feedEventReporter.dwell(listingId: item.id, surface: surface, position: position, dwellMs: dwellMs)
    }

    func reportListingClick(item: ListingFeedItem, surface: String, position: Int, deps: AppDependencies) {
        deps.feedEventReporter.click(listingId: item.id, surface: surface, position: position)
    }

    func dismissSizingBanner() {
        HomeSizingBannerPreference.markDismissed()
        showSizingBanner = false
    }

    func refreshSizingBannerAfterProfileSave(deps: AppDependencies, isGuestMode: Bool) {
        // Fast path: use the canonical profile already in memory from the just-completed save.
        if let p = deps.canonicalUserProfile {
            applySizingBannerFromProfile(p, isGuestMode: isGuestMode)
            return
        }
        Task { await refreshSizingBannerState(deps: deps, isGuestMode: isGuestMode) }
    }

    /// Computes sizing banner visibility from an already-loaded profile — no network call.
    func applySizingBannerFromProfile(_ profile: ProfileInfo, isGuestMode: Bool) {
        guard !isGuestMode, !HomeSizingBannerPreference.isDismissed() else {
            showSizingBanner = false
            return
        }
        let hasSize = !(profile.referenceSize?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasMeasurement = [
            profile.referenceMeasurementChest,
            profile.referenceMeasurementHem,
            profile.referenceMeasurementLength,
            profile.referenceMeasurementShoulders,
            profile.referenceMeasurementSleeveLength,
        ].contains { ($0 ?? 0) > 0 }
        showSizingBanner = !hasSize && !hasMeasurement
    }

    func toggleLike(_ item: ListingFeedItem, surface: String, position: Int, deps: AppDependencies) {
        let snapshot = item
        guard deps.listingEngagement.beginLikeToggle(listingId: item.id) else { return }
        patchListingInFeeds(item.id) { _ in snapshot.toggledLike }
        Task {
            defer { deps.listingEngagement.endLikeToggle(listingId: item.id) }
            switch await deps.listingRepository.toggleLike(listingId: item.id) {
            case .success(let liked):
                patchListingInFeeds(item.id) { _ in snapshot.applyingLikeToggle(liked) }
                if liked {
                    deps.feedEventReporter.like(listingId: item.id, surface: surface, position: position)
                }
                deps.showSnackbar(FeedEngagementFeedback.likeMessage(liked: liked))
            case .failure(let error):
                patchListingInFeeds(item.id) { _ in snapshot }
                deps.showSnackbar(FeedEngagementFeedback.actionErrorMessage(for: error))
            }
        }
    }

    func toggleSave(_ item: ListingFeedItem, surface: String, position: Int, deps: AppDependencies, isGuestMode: Bool) {
        let snapshot = item
        guard deps.listingEngagement.beginSaveToggle(listingId: item.id) else { return }
        patchListingInFeeds(item.id) { _ in snapshot.toggledSave }
        Task {
            defer { deps.listingEngagement.endSaveToggle(listingId: item.id) }
            switch await deps.listingRepository.toggleSave(
                listingId: item.id,
                currentlySaved: snapshot.isSaved
            ) {
            case .success(let saved):
                patchListingInFeeds(item.id) { _ in snapshot.applyingSaveToggle(saved) }
                if saved {
                    deps.feedEventReporter.save(listingId: item.id, surface: surface, position: position)
                }
                deps.showSnackbar(FeedEngagementFeedback.saveMessage(saved: saved))
                if !isGuestMode {
                    Task { await loadBuyerHomeStats(deps: deps, isGuestMode: false) }
                }
            case .failure(let error):
                patchListingInFeeds(item.id) { _ in snapshot }
                deps.showSnackbar(FeedEngagementFeedback.actionErrorMessage(for: error))
            }
        }
    }

    // MARK: - Private

    /// Shell was prefetched on the launch waiting screen — skip duplicate network on first Home appear.
    private var isLaunchShellFresh: Bool {
        guard let lastSuccessfulRefreshAt else { return false }
        guard Date().timeIntervalSince(lastSuccessfulRefreshAt) < 120 else { return false }
        return !items.isEmpty || recommendationSectionsFetched || !(tabFeedState[HomeFeedTabKeys.huntToday]?.isEmpty ?? true)
    }

    private func invalidateAllTabFeeds() {
        tabLoadTasks.values.forEach { $0.cancel() }
        tabLoadTasks.removeAll()
        tabLoadGeneration.removeAll()
        loadedTabs.removeAll()
        recommendationSectionsFetched = false
        sections = HomeRecommendationSections()
        followingWindow.reset(with: [])
        followingItemIds = []
        followingNextCursor = nil
        followingHasMore = false
        followingDuplicatePageCount = 0
        followingTrimTask?.cancel()
        followingTrimTask = nil
        sectionTabTrimTask?.cancel()
        sectionTabTrimTask = nil
        tabFeedState = [:]
        sectionLoadMoreTasks.values.forEach { $0.cancel() }
        sectionLoadMoreTasks = [:]
        tabsLoading = []
        tabsLoadError = []
        tabsLoadStalled = []
        tabLoadErrorDetails = [:]
        tabStallWatch.cancelAll()
        syncItemsForSelectedTab()
    }

    private func resetToHuntToday(deps: AppDependencies, isGuestMode: Bool, forceReload: Bool) {
        let switched = selectedFeedTab != .huntToday
        if switched {
            deps.uxTabTracker.closeActiveTab()
            selectedFeedTabKey = HomeFeedTabKeys.huntToday
            syncItemsForSelectedTab()
        }
        if forceReload || switched {
            ensureTabLoaded(.huntToday, deps: deps, isGuestMode: isGuestMode, force: true)
        }
    }

    private func ensureTabLoaded(
        _ tab: HomeFeedTab,
        deps: AppDependencies,
        isGuestMode: Bool,
        force: Bool = false
    ) {
        if isGuestMode && tab.requiresAuth { return }
        if force {
            tabLoadTasks[tab.rawValue]?.cancel()
            tabLoadTasks[tab.rawValue] = nil
        }
        if !force && loadedTabs.contains(tab.rawValue) {
            if tab == selectedFeedTab {
                syncItemsForSelectedTab()
            }
            return
        }
        if let existing = tabLoadTasks[tab.rawValue] {
            if !existing.isCancelled { return }
            tabLoadTasks[tab.rawValue] = nil
        }
        if !force && tab == .huntToday && recommendationSectionsFetched && !(tabFeedState[HomeFeedTabKeys.huntToday]?.isEmpty ?? true) {
            loadedTabs.insert(tab.rawValue)
            syncItemsForSelectedTab()
            return
        }
        if !force && HomeFeedTab.recommendationSectionTabs.contains(tab) && recommendationSectionsFetched {
            if !itemsForTab(tab).isEmpty {
                loadedTabs.insert(tab.rawValue)
                if tab == selectedFeedTab {
                    syncItemsForSelectedTab()
                }
                return
            }
        }

        beginTabLoad(tab)
        if tab == selectedFeedTab {
            syncItemsForSelectedTab()
        }
        let generation = nextTabLoadGeneration(for: tab)
        tabLoadTasks[tab.rawValue] = Task {
            setTabError(tab, false)
            var ok = false
            defer {
                if tabLoadGeneration[tab.rawValue] == generation {
                    if Task.isCancelled {
                        if ok || !itemsForTab(tab).isEmpty {
                            finishTabLoad(tab, succeeded: true)
                        } else {
                            clearTabLoadingWithoutMarkingLoaded(tab)
                        }
                    } else {
                        finishTabLoad(tab, succeeded: ok)
                    }
                    tabLoadTasks[tab.rawValue] = nil
                }
            }
            ok = await loadTab(tab, deps: deps, isGuestMode: isGuestMode, force: force)
        }
    }

    private func prefetchAdjacentTabs(around tab: HomeFeedTab, deps: AppDependencies, isGuestMode: Bool) {
        let ux = homeUxPersonalization
        let tabs = orderedTabs(isGuestMode: isGuestMode)
        let prefetchKeys = ux.prefetchTabs.compactMap { UxPersonalizationMapping.homeFeedTab(from: $0) }.filter { tabs.contains($0) }
        let targets: [HomeFeedTab]
        if !prefetchKeys.isEmpty {
            targets = prefetchKeys.filter { $0 != tab }.prefix(2).map { $0 }
        } else if let idx = tabs.firstIndex(of: tab) {
            targets = [tabs[safe: idx - 1], tabs[safe: idx + 1]].compactMap { $0 }
        } else {
            targets = []
        }
        targets.forEach { ensureTabLoaded($0, deps: deps, isGuestMode: isGuestMode) }
    }

    private func loadTab(
        _ tab: HomeFeedTab,
        deps: AppDependencies,
        isGuestMode: Bool,
        force: Bool
    ) async -> Bool {
        switch tab {
        case .huntToday:
            return await loadHuntTodayTab(deps: deps, isGuestMode: isGuestMode, force: force)
        case .following:
            return await loadFollowingTab(deps: deps, isGuestMode: isGuestMode, force: force)
        case .forYou, .stylePicks, .similarSaved, .seasonalNearYou:
            return await loadRecommendationSections(deps: deps, isGuestMode: isGuestMode, force: force)
        }
    }

    private func loadUxPersonalization(deps: AppDependencies, isGuestMode: Bool) async {
        guard !isGuestMode else { return }
        let uid = deps.authSessionStore.read()?.userId
        if let local = UxPersonalizationLocalStore.readHomeDefaultTab(userId: uid),
           let tab = UxPersonalizationMapping.homeFeedTab(from: local),
           !homeUxApplied {
            applyPreferredHomeTab(tab, deps: deps, isGuestMode: isGuestMode)
        }
        let result = await deps.recommendationRepository.uxPersonalization(
            clientHour: UxPersonalizationLocalStore.currentClientHour()
        )
        guard case .success(let bundle) = result else { return }
        let previousOrder = homeUxPersonalization.tabOrder
        homeUxPersonalization = bundle.home
        if previousOrder != bundle.home.tabOrder {
            homeTabBarScrollToken &+= 1
        }
        UxPersonalizationLocalStore.writeHomeDefaultTab(userId: uid, tabKey: bundle.home.defaultTabKey)
        if let tab = UxPersonalizationMapping.homeFeedTab(from: bundle.home.defaultTabKey) {
            applyPreferredHomeTab(tab, deps: deps, isGuestMode: isGuestMode)
        }
        // Neighbor prefetch only — avoid loading every UX prefetch tab on cold start.
    }

    private func applyPreferredHomeTab(_ tab: HomeFeedTab, deps: AppDependencies, isGuestMode: Bool) {
        if isGuestMode && tab.requiresAuth { return }
        guard HomeFeedTab.tabsFor(isGuestBrowse: isGuestMode).contains(tab) else { return }
        if homeUxApplied && selectedFeedTab == tab { return }
        homeUxApplied = true
        selectedFeedTabKey = tab.rawValue
        syncVisibleItemsForTab(tab)
        homeTabBarScrollToken &+= 1
        deps.uxTabTracker.onTabOpened(scope: "home", tabKey: UxPersonalizationMapping.uxTabKey(for: tab))
        ensureTabLoaded(tab, deps: deps, isGuestMode: isGuestMode, force: !loadedTabs.contains(tab.rawValue))
    }

    private func beginTabLoad(_ tab: HomeFeedTab) {
        tabsLoadStalled.remove(tab.rawValue)
        setTabLoading(tab, true)
        scheduleTabStallWatch(for: tab)
    }

    private func finishTabLoad(_ tab: HomeFeedTab, succeeded: Bool) {
        tabStallWatch.cancel(key: tab.rawValue)
        tabsLoadStalled.remove(tab.rawValue)
        if succeeded {
            loadedTabs.insert(tab.rawValue)
            if HomeFeedTab.recommendationSectionTabs.contains(tab) {
                HomeFeedTab.recommendationSectionTabs.forEach { loadedTabs.insert($0.rawValue) }
            }
            if tab == selectedFeedTab {
                syncItemsForSelectedTab()
            }
        } else {
            setTabError(tab, true)
        }
        setTabLoading(tab, false)
    }

    private func clearTabLoadingWithoutMarkingLoaded(_ tab: HomeFeedTab) {
        tabStallWatch.cancel(key: tab.rawValue)
        tabsLoadStalled.remove(tab.rawValue)
        setTabLoading(tab, false)
    }

    private func nextTabLoadGeneration(for tab: HomeFeedTab) -> UInt {
        let next = (tabLoadGeneration[tab.rawValue] ?? 0) + 1
        tabLoadGeneration[tab.rawValue] = next
        return next
    }

    private func scheduleTabStallWatch(for tab: HomeFeedTab) {
        let key = tab.rawValue
        tabStallWatch.schedule(key: key) { [weak self] in
            guard let self else { return false }
            guard self.selectedFeedTab == tab else { return false }
            guard !self.loadedTabs.contains(key) else { return false }
            guard self.itemsForTab(tab).isEmpty else { return false }
            return true
        } onStalled: { [weak self] in
            guard let self else { return }
            self.setTabLoading(tab, false)
            self.tabsLoadStalled.insert(key)
        }
    }

    private func sectionLimit(for tab: HomeFeedTab, fallback: Int) -> Int {
        homeUxPersonalization.sectionLimits[UxPersonalizationMapping.uxTabKey(for: tab)] ?? fallback
    }

    private func huntTodaySizingMode(isGuestMode: Bool) -> String? {
        guard !isGuestMode else { return nil }
        return ExploreSizingPreference.activeSizingModeForRecommendations()
    }

    private func prefetchRecommendationSections(deps: AppDependencies, isGuestMode: Bool) async -> Bool {
        guard !isGuestMode else { return false }
        return await loadRecommendationSections(deps: deps, isGuestMode: isGuestMode, force: false)
    }

    private func reloadFeedTab(_ tab: HomeFeedTab, deps: AppDependencies, isGuestMode: Bool) async {
        tabLoadTasks[tab.rawValue]?.cancel()
        let showTabSpinner = !isRefreshing
        if showTabSpinner {
            setTabLoading(tab, true)
            setTabError(tab, false)
        }
        let ok = await loadTab(tab, deps: deps, isGuestMode: isGuestMode, force: true)
        if ok {
            loadedTabs.insert(tab.rawValue)
            if HomeFeedTab.recommendationSectionTabs.contains(tab) {
                HomeFeedTab.recommendationSectionTabs.forEach { loadedTabs.insert($0.rawValue) }
            }
            if tab == selectedFeedTab {
                syncItemsForSelectedTab()
            }
        } else if showTabSpinner {
            setTabError(tab, true)
        }
        if showTabSpinner {
            setTabLoading(tab, false)
        }
        tabLoadTasks[tab.rawValue] = nil
    }

    private func loadHuntTodayTab(deps: AppDependencies, isGuestMode: Bool, force: Bool) async -> Bool {
        if !force && loadedTabs.contains(HomeFeedTabKeys.huntToday) { return true }
        if !isGuestMode && !preferPublicBrowse && recommendationSectionsFetched && !(tabFeedState[HomeFeedTabKeys.huntToday]?.isEmpty ?? true) {
            if selectedFeedTab == .huntToday { syncItemsForSelectedTab() }
            return true
        }
        let publicBrowse = resolvePublicBrowse(isGuestMode, deps: deps)
        var result = await deps.recommendationRepository.exploreListings(
            publicBrowse: publicBrowse,
            limit: sectionLimit(for: .huntToday, fallback: HomeFeedConstants.huntTodayLimit),
            offset: 0,
            sizingMode: huntTodaySizingMode(isGuestMode: publicBrowse),
            surface: HomeFeedTab.huntToday.analyticsSurface
        )
        if case .failure = result, publicBrowse {
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return false
            }
            guard !Task.isCancelled else { return false }
            result = await deps.recommendationRepository.exploreListings(
                publicBrowse: true,
                limit: sectionLimit(for: .huntToday, fallback: HomeFeedConstants.huntTodayLimit),
                offset: 0,
                sizingMode: nil,
                surface: HomeFeedTab.huntToday.analyticsSurface
            )
        }
        guard !Task.isCancelled else { return false }
        guard case .success(let loaded) = result else {
            if case .failure(let error) = result {
                tabLoadErrorDetails[HomeFeedTabKeys.huntToday] = FashErrorPresentation.userMessage(for: error)
            }
            return false
        }
        applyFirstPageToTab(.huntToday, items: loaded)
        let limit = sectionLimit(for: .huntToday, fallback: HomeFeedConstants.huntTodayLimit)
        setTabHasMore(.huntToday, loaded.count == limit)
        if selectedFeedTab == .huntToday { syncItemsForSelectedTab() }
        return true
    }

    private func loadMoreSectionTab(
        _ tab: HomeFeedTab,
        deps: AppDependencies,
        isGuestMode: Bool
    ) {
        guard hasMore(for: tab), !isLoadingMore(for: tab) else { return }
        guard !isShellLoading, !isRefreshing, !isTabLoading(tab) else { return }
        guard sectionLoadMoreTasks[tab.rawValue] == nil else { return }
        if FeedLoadMoreThrottle.isBlocked(until: sectionTabRateLimitUntil[tab.rawValue]) { return }
        if let last = sectionTabLoadMoreAt[tab.rawValue],
           Date().timeIntervalSince(last) < FeedLoadMoreThrottle.defaultInterval { return }
        sectionTabLoadMoreAt[tab.rawValue] = Date()

        setTabLoadingMore(tab, true)
        // Use logical offset (trimmed items + current window size) so front-trim doesn't repeat pages.
        let offset = tabFeedState[tab.rawValue]?.loadMoreOffset ?? itemsForTab(tab).count
        sectionLoadMoreTasks[tab.rawValue] = Task {
            defer {
                sectionLoadMoreTasks[tab.rawValue] = nil
                setTabLoadingMore(tab, false)
            }
            let publicBrowse = resolvePublicBrowse(isGuestMode, deps: deps)
            let result = await deps.recommendationRepository.exploreListings(
                publicBrowse: publicBrowse,
                limit: HomeFeedConstants.tabLoadMorePageSize,
                offset: offset,
                sizingMode: huntTodaySizingMode(isGuestMode: publicBrowse),
                surface: tab.analyticsSurface
            )
            guard selectedFeedTab == tab else { return }
            switch result {
            case .success(let page):
                guard !page.isEmpty else {
                    setTabHasMore(tab, false)
                    return
                }
                let added = appendUniqueItems(page, to: tab)
                if added > 0 {
                    syncItemsForSelectedTab()
                    FeedListingImagePrefetch.prefetch(items: Array(page.prefix(8)))
                }
                setTabHasMore(
                    tab,
                    page.count == HomeFeedConstants.tabLoadMorePageSize && added > 0
                )
                FeedPerformance.log("Home \(tab) loadMore @\(offset) -> +\(added) total=\(itemsForTab(tab).count)")
            case .failure(let error):
                if let blocked = FeedLoadMoreThrottle.blockedUntil(after: error) {
                    sectionTabRateLimitUntil[tab.rawValue] = blocked
                }
            }
        }
    }

    private func setTabHasMore(_ tab: HomeFeedTab, _ hasMore: Bool) {
        if tab == .following {
            followingHasMore = hasMore
            return
        }
        var state = tabFeedState[tab.rawValue] ?? HomeTabFeedState()
        state.hasMore = hasMore
        tabFeedState[tab.rawValue] = state
    }

    private func setTabLoadingMore(_ tab: HomeFeedTab, _ loading: Bool) {
        if tab == .following {
            isLoadingMoreFollowing = loading
            return
        }
        var state = tabFeedState[tab.rawValue] ?? HomeTabFeedState()
        state.isLoadingMore = loading
        tabFeedState[tab.rawValue] = state
    }

    private func applyFirstPageToTab(_ tab: HomeFeedTab, items: [ListingFeedItem]) {
        guard tab != .following else { return }
        var state = tabFeedState[tab.rawValue] ?? HomeTabFeedState()
        state.setFirstPage(items)
        tabFeedState[tab.rawValue] = state
    }

    @discardableResult
    private func appendUniqueItems(_ page: [ListingFeedItem], to tab: HomeFeedTab) -> Int {
        guard tab != .following else { return 0 }
        var state = tabFeedState[tab.rawValue] ?? HomeTabFeedState()
        let added = state.appendUniquePage(page)
        if added > 0 { tabFeedState[tab.rawValue] = state }
        return added
    }

    private func loadFollowingTab(deps: AppDependencies, isGuestMode: Bool, force: Bool) async -> Bool {
        if isGuestMode { return true }
        if !force && loadedTabs.contains(HomeFeedTabKeys.following) && !followingWindow.items.isEmpty { return true }
        let result = await FeedPerformance.measure("Home following first page") {
            await fetchHomeFeedPageWithRetry(deps: deps, cursor: nil)
        }
        guard case .success(let page) = result else {
            if case .failure(let error) = result {
                tabLoadErrorDetails[HomeFeedTabKeys.following] = FashErrorPresentation.userMessage(for: error)
            }
            return false
        }
        followingWindow.reset(with: page.items)
        followingItemIds = Set(page.items.map(\.id))
        followingNextCursor = page.nextCursor
        followingHasMore = page.hasMore
        if selectedFeedTab == .following { syncItemsForSelectedTab() }
        FeedPerformance.log("Home following items=\(followingWindow.items.count) hasMore=\(followingHasMore)")
        return true
    }

    private func fetchHomeFeedPageWithRetry(
        deps: AppDependencies,
        cursor: String?
    ) async -> Result<HomeFeedPage, Error> {
        func once() async -> Result<HomeFeedPage, Error> {
            await deps.listingRepository.getHomeFeedPage(
                limit: HomeFeedConstants.followPageSize,
                cursor: cursor
            )
        }
        var result = await once()
        if case .failure = result {
            try? await Task.sleep(for: .milliseconds(400))
            result = await once()
        }
        return result
    }

    /// Cursor API first; offset fallback when backend returns legacy bare array (`next_cursor` nil).
    private func fetchFollowingPage(
        deps: AppDependencies,
        cursor: String?,
        offsetFallback: Int?
    ) async -> Result<HomeFeedPage, Error> {
        if cursor != nil {
            return await fetchHomeFeedPageWithRetry(deps: deps, cursor: cursor)
        }
        if let offset = offsetFallback {
            func onceOffset() async -> Result<HomeFeedPage, Error> {
                switch await deps.listingRepository.getHomeFeed(
                    limit: HomeFeedConstants.followPageSize,
                    offset: offset
                ) {
                case .success(let items):
                    return .success(HomeFeedPage(
                        items: items,
                        hasMore: items.count >= HomeFeedConstants.followPageSize,
                        nextCursor: nil
                    ))
                case .failure(let error):
                    return .failure(error)
                }
            }
            var result = await onceOffset()
            if case .failure = result {
                try? await Task.sleep(for: .milliseconds(400))
                result = await onceOffset()
            }
            return result
        }
        return await fetchHomeFeedPageWithRetry(deps: deps, cursor: nil)
    }

    private func loadRecommendationSections(deps: AppDependencies, isGuestMode: Bool, force: Bool) async -> Bool {
        if !force && recommendationSectionsFetched { return true }
        if force {
            recommendationSectionsFetched = false
        }
        let styleLimit = sectionLimit(for: .stylePicks, fallback: 12)
        let similarLimit = sectionLimit(for: .similarSaved, fallback: 12)
        let forYouLimit = sectionLimit(for: .forYou, fallback: 16)
        let seasonalLimit = sectionLimit(for: .seasonalNearYou, fallback: 12)
        let huntLimit = sectionLimit(for: .huntToday, fallback: HomeFeedConstants.huntTodayLimit)
        let publicBrowse = resolvePublicBrowse(isGuestMode, deps: deps)
        let result = await deps.recommendationRepository.homeSections(
            publicBrowse: publicBrowse,
            huntTodayLimit: huntLimit,
            forYouLimit: forYouLimit,
            sectionLimit: max(styleLimit, similarLimit),
            sizingMode: huntTodaySizingMode(isGuestMode: publicBrowse)
        )
        guard case .success(let loaded) = result else {
            if case .failure(let error) = result {
                let message = FashErrorPresentation.userMessage(for: error)
                for t in HomeFeedTab.recommendationSectionTabs {
                    tabLoadErrorDetails[t.rawValue] = message
                }
            }
            return false
        }
        if !loaded.huntToday.isEmpty {
            applyFirstPageToTab(.huntToday, items: loaded.huntToday)
            loadedTabs.insert(HomeFeedTabKeys.huntToday)
        }
        applyFirstPageToTab(.forYou, items: loaded.forYou)
        applyFirstPageToTab(.stylePicks, items: loaded.stylePicks)
        applyFirstPageToTab(.similarSaved, items: loaded.similarToSaved)
        applyFirstPageToTab(.seasonalNearYou, items: loaded.seasonalNearYou)
        sections.dailyOutfitDrop = loaded.dailyOutfitDrop
        sections.shoppingContext = loaded.shoppingContext ?? sections.shoppingContext
        recommendationSectionsFetched = true
        if !loaded.huntToday.isEmpty {
            setTabHasMore(.huntToday, loaded.huntToday.count == huntLimit)
        }
        setTabHasMore(.forYou, loaded.forYou.count == forYouLimit)
        setTabHasMore(.stylePicks, loaded.stylePicks.count == styleLimit)
        setTabHasMore(.similarSaved, loaded.similarToSaved.count == similarLimit)
        setTabHasMore(.seasonalNearYou, loaded.seasonalNearYou.count == seasonalLimit)
        syncItemsForSelectedTab()
        return true
    }

    func hasCachedItems(for tab: HomeFeedTab) -> Bool {
        !itemsForTab(tab).isEmpty
    }

    /// Immediate tab body swap from per-tab cache — avoids white flash while a tab reloads.
    func syncVisibleItemsForTab(_ tab: HomeFeedTab) {
        let cached = itemsForTab(tab)
        guard cached != items else { return }
        items = cached
    }

    private func syncItemsForSelectedTab() {
        let tab = selectedFeedTab
        let cached = itemsForTab(tab)
        if loadedTabs.contains(tab.rawValue), !tabsLoading.contains(tab.rawValue) {
            guard cached != items else {
                if !items.isEmpty { errorMessage = nil }
                return
            }
            items = cached
            if !items.isEmpty {
                errorMessage = nil
                FeedListingImagePrefetch.prefetch(items: items)
            }
            return
        }
        if !cached.isEmpty {
            guard cached != items else { return }
            items = cached
            return
        }
        if isRefreshing { return }
        if tabsLoading.contains(tab.rawValue) {
            if cached.isEmpty, !items.isEmpty {
                items = []
            } else if cached != items {
                items = cached
            }
        }
    }

    private func itemsForTab(_ tab: HomeFeedTab) -> [ListingFeedItem] {
        if tab == .following { return followingWindow.items }
        return tabFeedState[tab.rawValue]?.items ?? []
    }

    var shoppingContextChip: String? {
        sections.shoppingContext?.chipLabel()
    }

    private func setTabLoading(_ tab: HomeFeedTab, _ loading: Bool) {
        if loading {
            tabsLoading.insert(tab.rawValue)
        } else {
            tabsLoading.remove(tab.rawValue)
        }
    }

    private func setTabError(_ tab: HomeFeedTab, _ error: Bool, detail: String? = nil) {
        if error {
            tabsLoadError.insert(tab.rawValue)
            let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                tabLoadErrorDetails[tab.rawValue] = trimmed
            }
        } else {
            tabsLoadError.remove(tab.rawValue)
            tabLoadErrorDetails.removeValue(forKey: tab.rawValue)
        }
    }

    /// Realtime `feed.refresh` — Android HomeViewModel feed refresh hint.
    func handleFeedRefresh(deps: AppDependencies, isGuestMode: Bool) async {
        if !isGuestMode {
            await loadBuyerHomeStats(deps: deps, isGuestMode: false)
        }
        if selectedFeedTab == .following {
            loadedTabs.remove(HomeFeedTabKeys.following)
            ensureTabLoaded(.following, deps: deps, isGuestMode: isGuestMode, force: true)
        }
    }

    private func loadBuyerHomeStats(deps: AppDependencies, isGuestMode: Bool) async {
        guard !isGuestMode else {
            buyerStats = BuyerHomeStats()
            return
        }
        let previous = buyerStats
        async let ordersResult = deps.orderRepository.getBuyingOrders(limit: 50, offset: 0)
        async let summaryResult = deps.listingRepository.getMyListingsSummary()
        let orders = (try? await ordersResult.get()) ?? []
        let delivering = orders.filter { BuyerHomeStatsConstants.deliveringStatuses.contains($0.status.lowercased()) }.count

        var saved = previous.savedListingsCount
        var inReview = previous.listingsInReviewCount
        if case .success(let summary) = await summaryResult {
            saved = summary.wishlist
            inReview = summary.inReview
        } else {
            async let wishCount = deps.listingRepository.getWishlistSavedCount(limit: 1, offset: 0)
            async let inReviewList = deps.listingRepository.getMyListings(status: "in_review", limit: 50, offset: 0)
            if case .success(let count) = await wishCount { saved = count }
            if case .success(let list) = await inReviewList {
                inReview = list.filter { $0.isInReviewListing() }.count
            }
        }
        buyerStats = BuyerHomeStats(
            activeDeliveryOrders: delivering,
            savedListingsCount: saved,
            listingsInReviewCount: inReview
        )
    }

    private func refreshSizingBannerState(deps: AppDependencies, isGuestMode: Bool) async {
        guard !isGuestMode else {
            showSizingBanner = false
            return
        }
        if HomeSizingBannerPreference.isDismissed() {
            showSizingBanner = false
            return
        }
        guard deps.authSessionStore.read()?.userId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            showSizingBanner = false
            return
        }
        guard case .success(let profile) = await deps.userRepository.getMeProfile() else {
            showSizingBanner = false
            return
        }
        let hasSize = !(profile.referenceSize?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let measurements = [
            profile.referenceMeasurementChest,
            profile.referenceMeasurementHem,
            profile.referenceMeasurementLength,
            profile.referenceMeasurementShoulders,
            profile.referenceMeasurementSleeveLength,
        ]
        let hasMeasurement = measurements.contains { ($0 ?? 0) > 0 }
        showSizingBanner = !hasSize && !hasMeasurement
    }

    func patchListingEngagement(_ id: String, transform: (ListingFeedItem) -> ListingFeedItem) {
        patchListingInFeeds(id, transform: transform)
    }

    private func patchListingInFeeds(_ id: String, transform: (ListingFeedItem) -> ListingFeedItem) {
        // O(1) in-place patch through each tab's window — avoids full O(n) array maps.
        followingWindow.patchItem(withId: id, transform: transform)
        for tab in HomeFeedTab.allCases where tab != .following {
            guard var state = tabFeedState[tab.rawValue] else { continue }
            state.patchItem(withId: id, transform: transform)
            tabFeedState[tab.rawValue] = state
        }
        if !patchInPlace(&items, id: id, transform: transform) {
            syncItemsForSelectedTab()
        }
    }

    @discardableResult
    private func patchInPlace(
        _ array: inout [ListingFeedItem],
        id: String,
        transform: (ListingFeedItem) -> ListingFeedItem
    ) -> Bool {
        guard let idx = array.firstIndex(where: { $0.id == id }) else { return false }
        array[idx] = transform(array[idx])
        return true
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
