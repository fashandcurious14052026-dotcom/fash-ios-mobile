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
    @State private var homeScrollClampRevision = 0
    @State private var listingInteractionEnabled = true
    @State private var masonryColumnAssignmentsByTab: [String: [String: Bool]] = [:]

    // MARK: Tab gap anchor state
    /// Non-reactive measurements container — updated from onPreferenceChange without triggering redraws.
    @State private var gapMeasurements = HomeGapMeasurements()
    /// Negative top padding applied to feedBodyContent to collapse abnormal whitespace.
    @State private var gapCollapseOffset: CGFloat = 0
    /// Token that fires HomeTabGapCollapseCompensator for users scrolled below the gap.
    @State private var gapCollapseToken: Int = 0
    /// Content-space Y of tab bar bottom — passed to compensator.
    @State private var gapCollapseTabContentY: CGFloat = 0
    /// When the gap collapse was last applied — prevents re-evaluation loops.
    @State private var gapCollapsedAt: Date = .distantPast
    /// When the feed last mutated (trim / restore / item count change).
    @State private var lastFeedMutationAt: Date = .distantPast
    /// Debounce task for scheduled gap evaluation.
    @State private var gapEvalTask: Task<Void, Never>? = nil

    private var pinnedChromeHeight: CGFloat {
        max(0, homeHeaderHeight + homeTabRowHeight)
    }

    private func refreshHomeStickyTabs() {
        homeScrollBoundary.updateHomeStickyTabsVisibility(
            headerHeight: homeHeaderHeight,
            tabRowHeight: homeTabRowHeight
        )
    }

    private var masonryColumnWidth: CGFloat {
        ListingMasonryGrid.feedGridColumnWidth(
            containerWidth: UIScreen.main.bounds.width,
            spacing: spacing
        )
    }

    private var masonryColumnAssignments: Binding<[String: Bool]> {
        Binding(
            get: { masonryColumnAssignmentsByTab[viewModel.selectedFeedTabKey] ?? [:] },
            set: { masonryColumnAssignmentsByTab[viewModel.selectedFeedTabKey] = $0 }
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

                            feedBodyContent
                                .id(HomeScrollIds.feedContent)
                                .allowsHitTesting(listingInteractionEnabled)
                                .frame(minHeight: homeFeedMinHeight, alignment: .top)
                                // Gap collapse: negative padding draws cards closer to tabs.
                                // Animated via withAnimation in applyGapCollapse(_:).
                                // Reset to 0 on tab change / refresh / items cleared.
                                .padding(.top, -gapCollapseOffset)
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
                                clampRevision: homeScrollClampRevision,
                                headerHeight: pinnedChromeHeight,
                                suspendDuringPull: viewModel.isRefreshing
                            )
                            HomeFeedScrollCoordinator(
                                scrollBoundary: homeScrollBoundary,
                                scrollToTopToken: viewModel.homeScrollToTopToken,
                                homeHeaderHeight: homeHeaderHeight,
                                homeTabRowHeight: homeTabRowHeight,
                                itemCount: viewModel.items.count,
                                onBlankTopDetected: {
                                    // Blank detected at top after scroll settled — reload the tab
                                    // from the API to clear any stuck scroll/layout state.
                                    viewModel.retryTab(
                                        viewModel.selectedFeedTab,
                                        deps: deps,
                                        isGuestMode: isGuestMode
                                    )
                                }
                            )
                            FeedScrollTrimCompensator(
                                token: viewModel.homeFeedTrimToken,
                                signedDeltaY: viewModel.homeFeedTrimSignedDeltaY,
                                suppressUntil: viewModel.homeFeedCompensatorSuppressedUntil
                            )
                            // Compensates scroll offset after gap collapse so users below the
                            // gap region don't experience a visual jump.
                            HomeTabGapCollapseCompensator(
                                token: gapCollapseToken,
                                signedDeltaY: -gapCollapseOffset,
                                tabBottomContentY: gapCollapseTabContentY
                            )
                        }
                    }
                    .coordinateSpace(name: "homeFeedScroll")

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
                // Gap anchor: update measurements without triggering SwiftUI redraws.
                // Both keys fire on every scroll frame; storing into a class property avoids
                // view invalidation while keeping values accessible in evaluateGap().
                .onPreferenceChange(HomeTabRowMinYKey.self) { minY in
                    gapMeasurements.tabRowMinY = minY
                }
                .onPreferenceChange(HomeFeedFirstContentMinYKey.self) { minY in
                    gapMeasurements.firstContentMinY = minY
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
                    resetGapCollapse()
                    onHomeFeedTabChanged(to: newKey)
                }
                .onChange(of: viewModel.items.count) { oldCount, newCount in
                    if viewModel.selectedFeedTab == .following {
                        if newCount < oldCount, !viewModel.isRefreshing {
                            homeScrollClampRevision += 1
                        }
                    }
                    // Reset collapse when items are cleared; schedule evaluation on mutation.
                    if newCount == 0 {
                        resetGapCollapse()
                    } else if oldCount != newCount {
                        lastFeedMutationAt = Date.now
                        scheduleGapEvaluation()
                    }
                }
                .onChange(of: viewModel.homeFeedTrimToken) { _, _ in
                    lastFeedMutationAt = Date.now
                    scheduleGapEvaluation()
                }
                .onChange(of: viewModel.homeFeedRepaintToken) { _, _ in
                    lastFeedMutationAt = Date.now
                    scheduleGapEvaluation()
                }
                .onChange(of: viewModel.isRefreshing) { _, refreshing in
                    if refreshing { resetGapCollapse() }
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
    private func homeFeedTabsBar(sticky: Bool) -> some View {
        VStack(spacing: 0) {
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
        .shadow(color: sticky ? Color.black.opacity(0.08) : .clear, radius: 3, y: 1)
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
                FeedMasonryChunkedGrid(
                    items: viewModel.items,
                    columnAssignments: masonryColumnAssignments,
                    isLoadingTop: viewModel.homeFeedTopLoading,
                    repaintToken: viewModel.homeFeedRepaintToken,
                    onGapDetected: { gaps in
                        viewModel.onFeedLayoutGapDetected(gaps)
                    },
                    coordinateSpaceForFirstContent: "homeFeedScroll",
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
                            let tab = viewModel.selectedFeedTab
                            if tab == .following {
                                viewModel.scheduleFollowingWindowTrim(
                                    visibleIndex: index,
                                    columnWidth: masonryColumnWidth,
                                    columnAssignments: masonryColumnAssignmentsByTab[tab.rawValue] ?? [:]
                                )
                            } else {
                                viewModel.scheduleSectionTabTrim(
                                    visibleIndex: index,
                                    columnWidth: masonryColumnWidth,
                                    columnAssignments: masonryColumnAssignmentsByTab[tab.rawValue] ?? [:]
                                )
                            }
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

    // MARK: - Tab Gap Anchor

    /// Schedule a gap evaluation with a debounce delay to let the layout settle.
    private func scheduleGapEvaluation(delayMs: Int = 650) {
        gapEvalTask?.cancel()
        gapEvalTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            evaluateGap()
        }
    }

    /// Read current gap measurements and classify. Apply collapse if abnormal.
    private func evaluateGap() {
        // Only evaluate when the in-scroll tab bar is at or near the visible top.
        // If tabRowMinY is deeply negative the user is scrolled past the tabs,
        // meaning no visible gap exists and evaluation would produce false positives.
        let tabMinY = gapMeasurements.tabRowMinY
        guard tabMinY > -(homeTabRowHeight + 40) else { return }

        let viewportGap = gapMeasurements.contentSpaceGap(tabRowHeight: homeTabRowHeight)
        let context = HomeGapFeedContext(
            isLoading: viewModel.isShellLoading || viewModel.isTabLoading(viewModel.selectedFeedTab),
            isRefreshing: viewModel.isRefreshing,
            isUserInteracting: homeScrollBoundary.isUserInteracting,
            itemCount: viewModel.items.count,
            timeSinceLastMutation: Date.now.timeIntervalSince(lastFeedMutationAt),
            timeSinceLastCollapse: Date.now.timeIntervalSince(gapCollapsedAt),
            currentCollapseOffset: gapCollapseOffset
        )

        let category = HomeTabGapClassifier.classify(viewportGap: viewportGap, context: context)
        FeedPerformance.log("[HomeTabGap] gap=\(String(format: "%.1f", viewportGap)) state=\(category)")

        switch category {
        case .normal:
            break
        case .loading:
            break
        case .masonryReconstructing:
            scheduleGapEvaluation(delayMs: 500)
        case .abnormal(let collapsePx):
            applyGapCollapse(collapsePx)
        }
    }

    /// Apply the gap collapse: animate content upward, fire compensator for users below the gap.
    private func applyGapCollapse(_ collapsePx: CGFloat) {
        let tabContentY = homeHeaderHeight + homeTabRowHeight
        gapCollapseTabContentY = tabContentY
        gapCollapsedAt = Date.now

        // Fire compensator BEFORE animation so users below the gap see no jump.
        gapCollapseToken &+= 1

        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            gapCollapseOffset = collapsePx
        }
        FeedPerformance.log("[HomeTabGap] Collapsed \(String(format: "%.1f", collapsePx))pt tabContentY=\(String(format: "%.1f", tabContentY))")
    }

    /// Reset gap collapse immediately — called on tab change, refresh, and items cleared.
    private func resetGapCollapse() {
        gapEvalTask?.cancel()
        guard gapCollapseOffset > 0 else { return }
        gapCollapseOffset = 0
        gapCollapseToken = 0
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
