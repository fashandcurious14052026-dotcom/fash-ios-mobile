import SwiftUI

/// Chunked Pinterest grid for feeds inside a parent `ScrollView` — avoids nested `LazyVStack` showing one tile.
struct FeedMasonryChunkedGrid<Cell: View, Footer: View>: View {
    @Environment(\.fashSpacing) private var spacing

    let items: [ListingFeedItem]
    @Binding var columnAssignments: [String: Bool]
    var chunkSize: Int = ListingMasonryFeedPages.profileChunkPageSize
    var isLoadingTop: Bool = false
    /// Incremented externally to force a full relayout even if itemsSignature is unchanged.
    var repaintToken: Int = 0
    /// Called post-mutation when the layout rebuild finds blank chunks at visible positions.
    /// Never fired on scroll events; only after trim/restore/replace mutations settle.
    var onGapDetected: (([FeedLayoutGap]) -> Void)? = nil
    @ViewBuilder var footer: () -> Footer
    @ViewBuilder let cell: (ListingFeedItem, Int) -> Cell

    @State private var layout: ListingMasonryColumnLayout = .empty
    @State private var perChunkLayout: [Int: ChunkColumns] = [:]
    @State private var layoutedItemCount = 0
    @State private var containerWidth: CGFloat = 0
    @State private var layoutRefreshTask: Task<Void, Never>?

    private struct ChunkColumns {
        let left: [(index: Int, item: ListingFeedItem)]
        let right: [(index: Int, item: ListingFeedItem)]
    }

    // O(1) identity check — replaces O(n) items.map(\.id) on every state change.
    private struct ItemsSignature: Equatable {
        let count: Int
        let firstId: String
    }

    private var gap: CGFloat { spacing.spacing2 }

    private var columnWidth: CGFloat {
        ListingMasonryGrid.feedGridColumnWidth(
            containerWidth: containerWidth > 1 ? containerWidth : UIScreen.main.bounds.width,
            spacing: spacing
        )
    }

    private var itemsSignature: ItemsSignature {
        ItemsSignature(count: items.count, firstId: items.first?.id ?? "")
    }

    init(
        items: [ListingFeedItem],
        columnAssignments: Binding<[String: Bool]>,
        chunkSize: Int = ListingMasonryFeedPages.profileChunkPageSize,
        isLoadingTop: Bool = false,
        repaintToken: Int = 0,
        onGapDetected: (([FeedLayoutGap]) -> Void)? = nil,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() },
        @ViewBuilder cell: @escaping (ListingFeedItem, Int) -> Cell
    ) {
        self.items = items
        self._columnAssignments = columnAssignments
        self.chunkSize = chunkSize
        self.isLoadingTop = isLoadingTop
        self.repaintToken = repaintToken
        self.onGapDetected = onGapDetected
        self.footer = footer
        self.cell = cell
    }

    // Stable namespace prefix for chunk view identity — incorporates first item id so LazyVStack
    // discards stale height caches when front-trim/restore swaps the leading items.
    private var chunkIdNamespace: String { items.first?.id ?? "empty" }

    var body: some View {
        LazyVStack(spacing: gap) {
            widthProbe
            ForEach(feedChunks) { chunk in
                feedChunkRow(chunk)
                    // Including chunkIdNamespace makes each chunk's SwiftUI identity unique to the
                    // current leading item. When a front-trim or restore changes items[0], LazyVStack
                    // creates fresh views for every chunk instead of reusing views whose cached heights
                    // belonged to a different set of items — eliminating the blank-area bug.
                    .id("masonry_chunk_\(chunk.id)_\(chunkIdNamespace)")
            }
            footer()
        }
        // Overlay keeps the spinner off the layout flow — no 52pt height jump when it appears/disappears.
        .overlay(alignment: .top) {
            if isLoadingTop {
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.ultraThinMaterial)
            }
        }
        .onAppear { refreshLayout(forceFull: true) }
        .onChange(of: itemsSignature) { old, new in
            guard old != new else { return }
            // Count grew and first item is unchanged → trailing pagination append.
            if new.count > old.count && new.firstId == old.firstId {
                refreshLayout(forceFull: false)
            } else {
                // firstId changed (front-trim, restore, or replace): clear stale perChunkLayout
                // immediately so chunks fall back to chunkFallbackColumns (correct current items)
                // instead of rendering wrong items from the previous column assignment.
                perChunkLayout = [:]
                refreshLayout(forceFull: true)
            }
        }
        .onChange(of: repaintToken) { _, _ in refreshLayout(forceFull: true) }
        .onDisappear { layoutRefreshTask?.cancel() }
    }

    private var feedChunks: [ListingMasonryFeedPages.FeedOrderChunk] {
        ListingMasonryFeedPages.feedOrderChunks(items: items, pageSize: chunkSize)
    }

    private var widthProbe: some View {
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
                guard width > 1, abs(width - containerWidth) > 0.5 else { return }
                containerWidth = width
                scheduleLayoutRefresh(forceFull: true)
            }
    }

    @ViewBuilder
    private func feedChunkRow(_ chunk: ListingMasonryFeedPages.FeedOrderChunk) -> some View {
        let gap = spacing.spacing2
        // O(1) dict lookup — perChunkLayout is pre-built in rebuildPerChunkLayout().
        // Falls back to alternating assignment so the first render shows tiles immediately
        // (before onAppear fires the full layout pass) instead of blank empty rows.
        let cols = perChunkLayout[chunk.id] ?? chunkFallbackColumns(chunk)
        HStack(alignment: .top, spacing: gap) {
            feedChunkColumn(entries: cols.left, gap: gap)
            feedChunkColumn(entries: cols.right, gap: gap)
        }
        .padding(.leading, spacing.editorialStart)
        .padding(.trailing, spacing.editorialEnd)
    }

    private func chunkFallbackColumns(_ chunk: ListingMasonryFeedPages.FeedOrderChunk) -> ChunkColumns {
        var left = [(index: Int, item: ListingFeedItem)]()
        var right = [(index: Int, item: ListingFeedItem)]()
        for (i, entry) in chunk.entries.enumerated() {
            if i.isMultiple(of: 2) { left.append(entry) } else { right.append(entry) }
        }
        return ChunkColumns(left: left, right: right)
    }

    @ViewBuilder
    private func feedChunkColumn(
        entries: [(index: Int, item: ListingFeedItem)],
        gap: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(entries, id: \.item.id) { entry in
                // O(1) index-based lookup picks up latest like/save state (e.g. after a like tap).
                // ID guard prevents showing wrong items during the 48ms layout-refresh delay window.
                let liveItem: ListingFeedItem = {
                    guard entry.index < items.count,
                          items[entry.index].id == entry.item.id else { return entry.item }
                    return items[entry.index]
                }()
                let tileHeight = ListingMasonryGrid.tileHeight(columnWidth: columnWidth, item: liveItem)
                cell(liveItem, entry.index)
                    .id(liveItem.id)
                    .environment(\.listingMasonryColumnWidth, columnWidth)
                    .frame(width: columnWidth, height: max(1, tileHeight), alignment: .top)
                    .clipped()
            }
        }
        .frame(width: columnWidth, alignment: .top)
    }

    private func scheduleLayoutRefresh(forceFull: Bool) {
        layoutRefreshTask?.cancel()
        layoutRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(forceFull ? 0 : 48))
            guard !Task.isCancelled else { return }
            refreshLayout(forceFull: forceFull)
        }
    }

    private func refreshLayout(forceFull: Bool) {
        guard !items.isEmpty else {
            layout = .empty
            perChunkLayout = [:]
            layoutedItemCount = 0
            return
        }
        // Append-only O(new items) path: new items added to the end without a front-trim.
        // The onChange handler calls forceFull=true whenever firstId changes (trim/replace),
        // so forceFull=false here reliably means a trailing pagination append.
        if !forceFull, !layout.isEmpty, columnWidth > 1, items.count > layoutedItemCount {
            let start = layoutedItemCount
            let newSlice = Array(items[start...])
            var assignments = columnAssignments
            layout = ListingMasonryGrid.extendStableColumnLayout(
                existing: layout,
                newItems: newSlice,
                startIndex: start,
                columnWidth: columnWidth,
                verticalGap: gap,
                assignedIsRightColumn: &assignments
            )
            if assignments != columnAssignments { columnAssignments = assignments }
            layoutedItemCount = items.count
            rebuildPerChunkLayout()
            return
        }
        // Full O(n) relayout — covers: forced, first load, column-width change, front-trim.
        var assignments = columnAssignments
        layout = ListingMasonryGrid.makeStableColumnLayout(
            items: items,
            columnWidth: columnWidth,
            verticalGap: gap,
            assignedIsRightColumn: &assignments
        )
        if assignments != columnAssignments { columnAssignments = assignments }
        layoutedItemCount = items.count
        rebuildPerChunkLayout()
    }

    // O(n) single-pass split: assigns each layout entry to its chunk without per-chunk filtering.
    private func rebuildPerChunkLayout() {
        let chunks = ListingMasonryFeedPages.feedOrderChunks(items: items, pageSize: chunkSize)
        // Build itemId → chunkId (Int) index in one pass over chunks.
        var itemToChunk: [String: Int] = [:]
        itemToChunk.reserveCapacity(items.count)
        for chunk in chunks {
            for entry in chunk.entries {
                itemToChunk[entry.item.id] = chunk.id
            }
        }
        // Single pass over layout columns to bucket entries by chunk.
        var leftByChunk: [Int: [(index: Int, item: ListingFeedItem)]] = [:]
        var rightByChunk: [Int: [(index: Int, item: ListingFeedItem)]] = [:]
        for entry in layout.left {
            if let cid = itemToChunk[entry.item.id] {
                leftByChunk[cid, default: []].append(entry)
            }
        }
        for entry in layout.right {
            if let cid = itemToChunk[entry.item.id] {
                rightByChunk[cid, default: []].append(entry)
            }
        }
        var result: [Int: ChunkColumns] = [:]
        result.reserveCapacity(chunks.count)
        for chunk in chunks {
            result[chunk.id] = ChunkColumns(
                left: leftByChunk[chunk.id] ?? [],
                right: rightByChunk[chunk.id] ?? []
            )
        }
        perChunkLayout = result
        validateLayoutGaps(chunks: chunks, perChunkLayout: result)
    }

    // O(visibleChunks) gap check — only inspects first 3 chunks (the viewport-visible zone).
    // Fires onGapDetected if items exist but visible chunks have empty columns.
    private func validateLayoutGaps(
        chunks: [ListingMasonryFeedPages.FeedOrderChunk],
        perChunkLayout: [Int: ChunkColumns]
    ) {
        guard let onGapDetected, !items.isEmpty else { return }
        let visibleChunks = chunks.prefix(3)
        var gaps: [FeedLayoutGap] = []
        for chunk in visibleChunks {
            guard let cols = perChunkLayout[chunk.id] else { continue }
            let leftEmpty = cols.left.isEmpty
            let rightEmpty = cols.right.isEmpty
            guard leftEmpty || rightEmpty else { continue }
            let neighborIds = chunk.entries.prefix(4).map { $0.item.id }
            gaps.append(FeedLayoutGap(
                chunkIndex: chunk.id,
                column: leftEmpty && !rightEmpty ? false : (rightEmpty && !leftEmpty ? true : nil),
                neighboringItemIds: Array(neighborIds),
                reason: leftEmpty && rightEmpty ? "empty_chunk" : "empty_column",
                confidence: leftEmpty && rightEmpty ? 1.0 : 0.7,
                isSafeForFallback: true
            ))
        }
        if !gaps.isEmpty {
            FeedPerformance.log("[HomeFeed] GapDetected count=\(gaps.count) chunks=\(gaps.map(\.chunkIndex))")
            onGapDetected(gaps)
        }
    }

}

extension FeedMasonryChunkedGrid where Footer == EmptyView {
    init(
        items: [ListingFeedItem],
        columnAssignments: Binding<[String: Bool]>,
        chunkSize: Int = ListingMasonryFeedPages.profileChunkPageSize,
        isLoadingTop: Bool = false,
        repaintToken: Int = 0,
        onGapDetected: (([FeedLayoutGap]) -> Void)? = nil,
        @ViewBuilder cell: @escaping (ListingFeedItem, Int) -> Cell
    ) {
        self.init(
            items: items,
            columnAssignments: columnAssignments,
            chunkSize: chunkSize,
            isLoadingTop: isLoadingTop,
            repaintToken: repaintToken,
            onGapDetected: onGapDetected,
            footer: { EmptyView() },
            cell: cell
        )
    }
}
