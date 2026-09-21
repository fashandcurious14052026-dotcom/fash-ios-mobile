import SwiftUI

struct HomeFeedContent: View {
    @Environment(\.fashSpacing) private var spacing
    @Environment(AppDependencies.self) private var deps
    @Bindable var viewModel: HomeViewModel
    @Bindable var router: AppRouter
    var isGuestMode: Bool
    var onOpenExplore: () -> Void = {}
    var onOpenFeaturedSellersAll: () -> Void = {}
    var onFeaturedSellerClick: (FeaturedSellerItem) -> Void = { _ in }
    var onRequestSignIn: (String) -> Void = { _ in }
    var onOpenSizingSetup: (() -> Void)? = nil
    var onOpenPersonalization: (() -> Void)? = nil
    var onDeliveringJourneyClick: () -> Void = {}
    var onSavedJourneyClick: () -> Void = {}
    var onInReviewJourneyClick: () -> Void = {}
    var onExploreShortcutClick: (HomeExploreShortcut) -> Void = { _ in }

    /// Named coordinate space of the Home `ScrollView` — the masonry derives its render window from it.
    private static let scrollSpace = "homeFeedScroll"

    private var tabs: [HomeFeedTab] {
        viewModel.orderedTabs(isGuestMode: isGuestMode)
    }

    private var showGuestGate: Bool {
        isGuestMode && viewModel.selectedFeedTab.requiresAuth
    }

    private var promoSlides: [FashPromoSlideDef] {
        viewModel.promoSlides.map(FashPromoSlideDef.fromAdvertising)
    }

    private var promoDockInset: CGFloat {
        promoSlides.isEmpty ? 0 : FashStickyPromoDockHeight
    }

    private var selectedTabIndex: Int {
        tabs.firstIndex(of: viewModel.selectedFeedTab) ?? 0
    }

    private var analyticsSurface: String {
        viewModel.selectedFeedTab.analyticsSurface
    }

    private var showJourneyRow: Bool {
        !isGuestMode
    }

    private var exploreShortcut: HomeExploreShortcut? {
        isGuestMode ? nil : viewModel.homeUxPersonalization.exploreShortcut
    }

    /// Skeleton min-height only when the active tab has no cached rows yet.
    private var homeFeedMinHeight: CGFloat {
        if !viewModel.items.isEmpty { return 0 }
        if viewModel.hasCachedItems(for: viewModel.selectedFeedTab) { return 0 }
        if viewModel.isRefreshing { return 0 }
        if viewModel.isShellLoading || viewModel.isTabLoading(viewModel.selectedFeedTab) {
            return 360
        }
        return 0
    }

    @State private var homeScrollBoundary = HomeFeedScrollBoundary()
    @State private var homeHeaderHeight: CGFloat = 0
    @State private var homeTabRowHeight: CGFloat = 48
    @State private var listingInteractionEnabled = true

    private var pinnedChromeHeight: CGFloat {
        max(0, homeHeaderHeight + homeTabRowHeight)
    }

    private func refreshHomeStickyTabs() {
        homeScrollBoundary.updateHomeStickyTabsVisibility(
            headerHeight: homeHeaderHeight,
            tabRowHeight: homeTabRowHeight
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { scrollProxy in
                ZStack(alignment: .top) {
                    ScrollView {
                        // VStack (not LazyVStack) — lazy-unloaded header/tabs shrink contentSize when
                        // pinned, which blocks scrolling back up until many drag attempts.
                        VStack(spacing: 0) {
                            homeScrollAwayHeader

                            homeFeedTabsBar(sticky: false)
                                .id(HomeScrollIds.pinnedTabs)
                                .homeTabRowScrollReporting()

                            // Marquee suspension is applied by a tiny wrapper so the scroll-active
                            // toggle re-renders only the feed subtree, not the header/tab chrome.
                            HomeFeedScrollActivityGate(boundary: homeScrollBoundary) {
                                feedBodyContent
                            }
                            .id(HomeScrollIds.feedContent)
                            .allowsHitTesting(listingInteractionEnabled)
                            .frame(minHeight: homeFeedMinHeight, alignment: .top)
                        }
                        .padding(.bottom, promoDockInset + spacing.spacing2)
                        .fashScrollViewTabSwipe(
                            currentIndex: selectedTabIndex,
                            tabCount: tabs.count,
                            listingInteractionEnabled: $listingInteractionEnabled,
                            onHorizontalSwipeActive: { active in
                                if active {
                                    deps.listingPreview.close(deps: deps, animated: false)
                                }
                            }
                        ) { index in
                            viewModel.selectFeedTab(tabs[index], deps: deps, isGuestMode: isGuestMode)
                        }
                        .background {
                            PinnedTabScrollOffsetFixer(
                                resetToken: 0,
                                trueTopToken: viewModel.homeScrollToTopToken,
                                headerHeight: pinnedChromeHeight,
                                suspendDuringPull: viewModel.isRefreshing
                            )
                            HomeFeedScrollCoordinator(
                                scrollBoundary: homeScrollBoundary,
                                scrollToTopToken: viewModel.homeScrollToTopToken,
                                homeHeaderHeight: homeHeaderHeight,
                                homeTabRowHeight: homeTabRowHeight
                            )
                        }
                    }
                    .coordinateSpace(name: Self.scrollSpace)

                    if homeScrollBoundary.stickyTabsVisible {
                        homeFeedTabsBar(sticky: true)
                            .zIndex(20)
                            .transition(.opacity)
                    }
                }
                .onPreferenceChange(HomeTabRowHeightKey.self) { height in
                    guard height > 1, abs(height - homeTabRowHeight) > 0.5 else { return }
                    homeTabRowHeight = height
                    refreshHomeStickyTabs()
                }
                .animation(FashMotion.tabContent, value: homeScrollBoundary.stickyTabsVisible)
                .fashFeedPullRefresh(isRefreshing: $viewModel.isRefreshing) {
                    await viewModel.pullToRefresh(deps: deps, isGuestMode: isGuestMode)
                }
                .onChange(of: viewModel.homeScrollToTopToken) { _, _ in
                    applyHomeScrollToTop(using: scrollProxy)
                }
                .onChange(of: viewModel.homeScrollToFeedTopToken) { _, _ in
                    applyHomeScrollToFeedTop(using: scrollProxy)
                }
                .onChange(of: viewModel.selectedFeedTabKey) { oldKey, newKey in
                    guard oldKey != newKey else { return }
                    onHomeFeedTabChanged(to: newKey)
                }
            }

            if !promoSlides.isEmpty {
                FashPromoSliderAdFooterView(slides: promoSlides) { slide, _ in
                    router.handlePromoSlideClick(slide)
                }
            }
        }
        .task {
            viewModel.normalizeSelectedFeedTab(isGuestMode: isGuestMode, deps: deps)
            // Guest shell load is owned by launch warmup + onGuestBrowseEntered (Android parity).
            if isGuestMode {
                viewModel.ensureFeaturedSellersLoaded(deps: deps, isGuestMode: true)
                return
            }
            await viewModel.loadShell(deps: deps, isGuestMode: isGuestMode, skipIfFresh: true)
        }
        .task(id: viewModel.selectedFeedTabKey) {
            viewModel.ensureSelectedFeedTabLoaded(deps: deps, isGuestMode: isGuestMode)
        }
        .onAppear {
            viewModel.homeScrollBoundary = homeScrollBoundary
            viewModel.ensureSelectedFeedTabLoaded(deps: deps, isGuestMode: isGuestMode)
        }
        .onChange(of: isGuestMode) { _, guest in
            viewModel.normalizeSelectedFeedTab(isGuestMode: guest, deps: deps)
        }
    }

    @ViewBuilder
    private var homeScrollAwayHeader: some View {
        VStack(spacing: 0) {
            HomeFeedScrollOffsetAnchor()

            if let chip = viewModel.shoppingContextChip {
                HStack(spacing: 6) {
                    Image(systemName: "leaf.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FashColors.brandPrimary)
                    Text(chip)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FashColors.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FashColors.surfaceContainerLow)
                .clipShape(Capsule())
                .padding(.bottom, 4)
            }

            if showJourneyRow {
                BuyerHomeJourneyCompactBar(
                    stats: viewModel.buyerStats,
                    onDeliveringClick: onDeliveringJourneyClick,
                    onSavedClick: onSavedJourneyClick,
                    onInReviewClick: onInReviewJourneyClick
                )
            }

            if !isGuestMode, let openPersonalization = onOpenPersonalization,
               let canonProfile = deps.canonicalUserProfile {
                let completionState = ProfileCompletionState.from(canonProfile)
                if !completionState.isComplete {
                    ProfileCompletionCard(state: completionState, onAction: openPersonalization)
                        .padding(.top, spacing.spacing2)
                }
            }

            if viewModel.showSizingBanner, let onOpenSizingSetup {
                HomeSizingBanner(
                    onAddSizeClick: onOpenSizingSetup,
                    onDismiss: { viewModel.dismissSizingBanner() }
                )
            }

            if !viewModel.featuredSellers.isEmpty {
                HomeRecommendedSellersSection(
                    sellers: viewModel.featuredSellers,
                    onSellerClick: onFeaturedSellerClick,
                    onSeeAllClick: onOpenFeaturedSellersAll
                )
            } else if viewModel.featuredSellersLoading
                || (isGuestMode && viewModel.isShellLoading && viewModel.featuredSellers.isEmpty) {
                // Guest: reserve rail while shell warms so tabs are never the first row (Android parity).
                HomeRecommendedSellersSkeleton()
            }

            if !viewModel.dailyOutfitDrop.isEmpty {
                HomeDailyOutfitDropCtaBanner(
                    setCount: viewModel.dailyOutfitDrop.count,
                    onClick: { router.showDailyOutfitDropList = true }
                )
            }

            if let exploreShortcut {
                HomeExploreShortcutBanner(
                    shortcut: exploreShortcut,
                    onClick: { onExploreShortcutClick(exploreShortcut) }
                )
            }
        }
        .homeFeedHeaderHeightReporting()
        .onHomeHeaderHeightChange($homeHeaderHeight)
        .onChange(of: homeHeaderHeight) { _, _ in
            refreshHomeStickyTabs()
        }
    }

    /// Tab row — in-scroll copy; sticky overlay shown separately when scrolled off (Android parity).
    @ViewBuilder
    private func homeFeedTabsBar(sticky: Bool) -> some View {
        let bar = VStack(spacing: 0) {
            HomeFeedTabSwitcher(
                tabs: tabs,
                selectedTab: viewModel.selectedFeedTab,
                scrollToSelectedToken: viewModel.homeTabBarScrollToken,
                isGuestBrowse: isGuestMode,
                onSelect: { tab in
                    viewModel.selectFeedTab(tab, deps: deps, isGuestMode: isGuestMode)
                }
            )
            Divider()
                .overlay(FashColors.outlineMuted.opacity(0.35))
        }
        .background(FashColors.screen)

        // The in-scroll copy moves every frame; a shadow filter (even a clear one) forces an offscreen
        // render pass for it, so only the fixed sticky overlay gets the shadow.
        if sticky {
            bar.shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
        } else {
            bar
        }
    }

    @ViewBuilder
    private var feedBodyContent: some View {
        if showGuestGate {
            HomeFeedTabGuestGate(tab: viewModel.selectedFeedTab) {
                onRequestSignIn(guestLoginReason(for: viewModel.selectedFeedTab))
            }
            .padding(.vertical, spacing.spacing4)
        } else if viewModel.isTabLoadError(viewModel.selectedFeedTab), viewModel.items.isEmpty {
            FashEmptyStateView(
                title: L10n.feedLoadError,
                subtitle: viewModel.tabLoadErrorDetail(for: viewModel.selectedFeedTab),
                actionTitle: L10n.feedRetry
            ) {
                viewModel.retryTab(viewModel.selectedFeedTab, deps: deps, isGuestMode: isGuestMode)
            }
            .padding(.vertical, spacing.spacing4)
        } else if viewModel.isTabLoadStalled(viewModel.selectedFeedTab), viewModel.items.isEmpty {
            FashEmptyStateView(
                title: L10n.feedLoadError,
                subtitle: L10n.feedLoadStallSubtitle,
                actionTitle: L10n.feedRetry
            ) {
                viewModel.retryTab(viewModel.selectedFeedTab, deps: deps, isGuestMode: isGuestMode)
            }
            .padding(.vertical, spacing.spacing4)
        } else if (viewModel.isShellLoading || viewModel.isTabLoading(viewModel.selectedFeedTab))
            && viewModel.items.isEmpty
            && !viewModel.hasCachedItems(for: viewModel.selectedFeedTab) {
            FashSkeleton.listingGrid()
                .padding(.top, spacing.spacing2)
        } else if viewModel.items.isEmpty {
            HomeFeedTabGenericEmpty(tab: viewModel.selectedFeedTab)
                .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            VStack(spacing: 0) {
                FeedMasonryWindowedGrid(
                    items: viewModel.items,
                    coordinateSpace: Self.scrollSpace,
                    footer: {
                        let tab = viewModel.selectedFeedTab
                        if viewModel.hasMore(for: tab) || viewModel.isLoadingMore(for: tab) {
                            FeedLoadMoreFooter(
                                enabled: viewModel.hasMore(for: tab),
                                isLoadingMore: viewModel.isLoadingMore(for: tab),
                                anchorItemCount: viewModel.items.count,
                                loadingPresentation: .spinner
                            ) {
                                viewModel.loadMore(
                                    deps: deps,
                                    isGuestMode: isGuestMode,
                                    fromScrollEdge: true
                                )
                            }
                        }
                    },
                    cell: { item, index in
                        HomeFeedListingCell(
                            item: item,
                            index: index,
                            surface: analyticsSurface,
                            imageAspectRatio: ListingMasonryGrid.masonryAspectRatio(for: item),
                            onPrefetchLoadMore: {
                                if FeedPaginationPolicy.shouldPrefetchNextPage(
                                    appearedIndex: index,
                                    totalCount: viewModel.items.count
                                ) {
                                    viewModel.loadMore(
                                        deps: deps,
                                        isGuestMode: isGuestMode,
                                        fromScrollEdge: false
                                    )
                                }
                            },
                            onTap: {
                                viewModel.reportListingClick(
                                    item: item,
                                    surface: analyticsSurface,
                                    position: index,
                                    deps: deps
                                )
                                deps.presentListingPreview(
                                    item: item,
                                    router: router,
                                    publicBrowse: isGuestMode,
                                    surface: analyticsSurface,
                                    position: index
                                )
                            },
                            onLike: {
                                if isGuestMode {
                                    onRequestSignIn(L10n.guestLoginReasonLike)
                                } else {
                                    viewModel.toggleLike(
                                        item,
                                        surface: analyticsSurface,
                                        position: index,
                                        deps: deps
                                    )
                                }
                            },
                            onSave: {
                                if isGuestMode {
                                    onRequestSignIn(L10n.guestLoginReasonSaved)
                                } else {
                                    viewModel.toggleSave(
                                        item,
                                        surface: analyticsSurface,
                                        position: index,
                                        deps: deps,
                                        isGuestMode: isGuestMode
                                    )
                                }
                            },
                            onRecordView: {
                                viewModel.recordView(
                                    item: item,
                                    position: index,
                                    surface: analyticsSurface,
                                    deps: deps
                                )
                            },
                            onDwell: { dwellMs in
                                viewModel.recordDwell(
                                    item: item,
                                    surface: analyticsSurface,
                                    position: index,
                                    dwellMs: dwellMs,
                                    deps: deps
                                )
                            }
                        )
                    }
                )

                if viewModel.showsHomeBrandFooter(isGuestMode: isGuestMode) {
                    HomeBrandFooterStrip()
                }
            }
            .padding(.top, spacing.spacing2)
            .padding(.bottom, spacing.spacing4)
            // Per-tab identity: each tab owns its own layout store and render window.
            .id(viewModel.selectedFeedTabKey)
        }
    }

    private func guestLoginReason(for tab: HomeFeedTab) -> String {
        switch tab {
        case .forYou: return L10n.guestLoginReasonHomeForYou
        case .following: return L10n.guestLoginReasonHomeFollowing
        case .stylePicks: return L10n.guestLoginReasonHomeStyle
        case .similarSaved: return L10n.guestLoginReasonHomeSimilar
        default: return L10n.guestLoginSheetTitle
        }
    }

    private func onHomeFeedTabChanged(to tabKey: String) {
        let tab = HomeFeedTab(rawValue: tabKey) ?? viewModel.selectedFeedTab
        viewModel.syncVisibleItemsForTab(tab)
        viewModel.ensureSelectedFeedTabLoaded(deps: deps, isGuestMode: isGuestMode)
    }

    private func applyHomeScrollToTop(using scrollProxy: ScrollViewProxy) {
        homeScrollBoundary.forceHideHomeStickyTabs()
        HomeFeedScrollReset.scheduleScrollToTop(proxy: scrollProxy)
    }

    private func applyHomeScrollToFeedTop(using scrollProxy: ScrollViewProxy) {
        HomeFeedScrollReset.scheduleScrollToFeedTop(proxy: scrollProxy)
    }
}

/// Publishes `\.fashMarqueeSuspended` from the UIKit scroll boundary. Kept as its own view so the
/// scroll-active toggle (twice per gesture) invalidates only this subtree.
private struct HomeFeedScrollActivityGate<Content: View>: View {
    var boundary: HomeFeedScrollBoundary
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.fashMarqueeSuspended, boundary.isScrollActive)
    }
}

private struct HomeFeedListingCell: View {
    let item: ListingFeedItem
    let index: Int
    let surface: String
    let imageAspectRatio: CGFloat
    var onPrefetchLoadMore: (() -> Void)? = nil
    let onTap: () -> Void
    let onLike: () -> Void
    var onSave: (() -> Void)? = nil
    let onRecordView: () -> Void
    let onDwell: (Int) -> Void

    @State private var appearedAt: Date?
    @State private var recordViewTask: Task<Void, Never>?

    var body: some View {
        ListingGridCard(
            item: item,
            onTap: onTap,
            imageAspectRatio: imageAspectRatio,
            showQuickActions: true,
            statusOverlayLabel: ListingStatusUi.overlayLabel(for: item.listingStatus, suppressActive: true),
            onLike: onLike,
            onSave: onSave
        )
        // Pagination appends re-run the grid body for every visible cell; the card compares its data
        // fields (not closures) so unchanged cards skip their body entirely.
        .equatable()
        .onAppear {
            appearedAt = Date()
            recordViewTask?.cancel()
            recordViewTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                onRecordView()
            }
            onPrefetchLoadMore?()
        }
        .onDisappear {
            recordViewTask?.cancel()
            recordViewTask = nil
            if let appearedAt {
                let dwellMs = Int(Date().timeIntervalSince(appearedAt) * 1_000)
                onDwell(dwellMs)
            }
            self.appearedAt = nil
        }
    }
}
