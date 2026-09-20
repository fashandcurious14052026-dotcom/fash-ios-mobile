import SwiftUI
import UIKit

/// Quantized viewport band in grid coordinates — the render window.
///
/// Edges snap to `FeedMasonryWindowPolicy.step`, so the window (and therefore the grid `body`) changes
/// at most once per `step` points of scrolling instead of on every scroll frame.
struct FeedMasonryRenderBand: Equatable {
    var minY: CGFloat
    var maxY: CGFloat

    var isValid: Bool { minY.isFinite && maxY.isFinite && maxY >= minY }
}

enum FeedMasonryWindowPolicy {
    /// Extra content kept alive above and below the viewport so cells (and their images) exist before
    /// they scroll into view.
    static func lead(viewportHeight: CGFloat) -> CGFloat {
        max(320, viewportHeight * 0.75)
    }

    /// Band edges snap to this grid.
    static let step: CGFloat = 256

    /// Window shown before the first geometry pass — covers the top of the feed so the first frame
    /// already has cards.
    static func initialBand(viewportHeight: CGFloat) -> FeedMasonryRenderBand {
        band(visibleMinY: 0, viewportHeight: viewportHeight)
    }

    /// `visibleMinY` is the grid-space y at the top of the viewport (positive once the grid scrolled up).
    /// Both edges derive from one quantized base so the band changes exactly once per `step`.
    static func band(visibleMinY: CGFloat, viewportHeight: CGFloat) -> FeedMasonryRenderBand {
        let lead = lead(viewportHeight: viewportHeight)
        let base = floor(visibleMinY / step) * step
        return FeedMasonryRenderBand(minY: base - lead, maxY: base + step + viewportHeight + lead)
    }
}

struct FeedMasonryViewportBandKey: PreferenceKey {
    static var defaultValue: FeedMasonryRenderBand? = nil

    static func reduce(value: inout FeedMasonryRenderBand?, nextValue: () -> FeedMasonryRenderBand?) {
        if let next = nextValue() { value = next }
    }
}

/// Two-column masonry inside a parent `ScrollView` that renders only the placements intersecting the
/// current render window.
///
/// Ownership model:
/// - **Logical feed** — `items`, owned by the caller; never trimmed by this view.
/// - **Layout state** — `FeedMasonryLayoutStore`; deterministic geometry keyed by listing id.
/// - **Render window** — `band`; derived from the viewport, quantized, and applied to the layout.
/// - **Scroll position** — untouched; content above the viewport never changes height, so there is
///   nothing to compensate.
///
/// The grid reserves its full deterministic height with an empty spacer and absolutely positions the
/// windowed cells, so `ScrollView` content size is exact from the first frame and never estimated.
struct FeedMasonryWindowedGrid<Cell: View, Footer: View>: View {
    @Environment(\.fashSpacing) private var spacing

    let items: [ListingFeedItem]
    /// Named coordinate space of the enclosing `ScrollView` (its frame is the viewport).
    let coordinateSpace: String
    @ViewBuilder var footer: () -> Footer
    @ViewBuilder let cell: (ListingFeedItem, Int) -> Cell

    @State private var store = FeedMasonryLayoutStore()
    @State private var containerWidth: CGFloat = 0
    @State private var band = FeedMasonryWindowPolicy.initialBand(viewportHeight: UIScreen.main.bounds.height)

    init(
        items: [ListingFeedItem],
        coordinateSpace: String,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() },
        @ViewBuilder cell: @escaping (ListingFeedItem, Int) -> Cell
    ) {
        self.items = items
        self.coordinateSpace = coordinateSpace
        self.footer = footer
        self.cell = cell
    }

    private var metrics: FeedMasonryLayout.Metrics {
        let width = containerWidth > 1 ? containerWidth : UIScreen.main.bounds.width
        return FeedMasonryLayout.Metrics(
            columnWidth: ListingMasonryGrid.feedGridColumnWidth(containerWidth: width, spacing: spacing),
            columnGap: spacing.spacing2,
            verticalGap: spacing.spacing2,
            leadingInset: spacing.editorialStart
        )
    }

    var body: some View {
        // Resolved inside body so placements and items always come from the same render pass.
        let layout = store.layout(for: items, metrics: metrics)
        let visible = layout.placements(intersecting: band.minY, maxY: band.maxY)
        VStack(spacing: spacing.spacing2) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: max(1, layout.totalHeight))
                ForEach(visible) { placement in
                    tile(placement, layout: layout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background { viewportProbe }

            // The footer joins the hierarchy only when the render window reaches the end of the grid,
            // so its `onAppear` pagination trigger means "near the bottom", not "exists".
            if band.maxY >= layout.totalHeight {
                footer()
            }
        }
        .onPreferenceChange(FeedMasonryViewportBandKey.self) { newBand in
            guard let newBand, newBand.isValid, newBand != band else { return }
            band = newBand
        }
        .onPreferenceChange(ListingMasonryContainerWidthKey.self) { width in
            guard width > 1, abs(width - containerWidth) > 0.5 else { return }
            containerWidth = width
        }
        .onChange(of: band) { oldBand, newBand in
            auditWindow(oldBand: oldBand, newBand: newBand)
        }
    }

    @ViewBuilder
    private func tile(_ placement: FeedMasonryPlacement, layout: FeedMasonryLayout) -> some View {
        // Live lookup picks up in-place patches (like/save). The id guard is defensive: the store only
        // commits layouts whose index/id pairs match `items`.
        if placement.index < items.count, items[placement.index].id == placement.id {
            cell(items[placement.index], placement.index)
                .environment(\.listingMasonryColumnWidth, layout.metrics.columnWidth)
                .frame(width: layout.metrics.columnWidth, height: max(1, placement.height), alignment: .top)
                .clipped()
                .offset(x: layout.x(forColumn: placement.column), y: placement.y)
        }
    }

    /// One zero-cost probe for the whole grid — reports container width and the viewport band.
    private var viewportProbe: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(coordinateSpace))
            let viewportHeight = geo.bounds(of: .named(coordinateSpace))?.height ?? UIScreen.main.bounds.height
            Color.clear
                .preference(key: ListingMasonryContainerWidthKey.self, value: geo.size.width)
                .preference(
                    key: FeedMasonryViewportBandKey.self,
                    value: FeedMasonryWindowPolicy.band(visibleMinY: -frame.minY, viewportHeight: viewportHeight)
                )
        }
        .allowsHitTesting(false)
    }

    /// Debug instrumentation (FEED_PERF_LOG=1). Logs every window transition and flags the invariant
    /// "items exist and the window overlaps the grid, yet nothing is rendered".
    private func auditWindow(oldBand: FeedMasonryRenderBand, newBand: FeedMasonryRenderBand) {
        let layout = store.layout
        let visible = layout.placements(intersecting: newBand.minY, maxY: newBand.maxY)
        FeedPerformance.log(
            "[HomeFeed] window \(Int(oldBand.minY))...\(Int(oldBand.maxY)) -> "
                + "\(Int(newBand.minY))...\(Int(newBand.maxY)) logicalFeedCount=\(items.count) "
                + "layoutGeneration=\(layout.generation) layoutCount=\(layout.count) visibleItems=\(visible.count) "
                + "anchor=\(visible.first?.id ?? "-") contentHeight=\(Int(layout.totalHeight))"
        )
        let overlapsContent = newBand.maxY >= 0 && newBand.minY <= layout.totalHeight
        if !items.isEmpty, overlapsContent, visible.isEmpty {
            FeedPerformance.log(
                "[MasonryInvariantViolation] logicalFeedCount=\(items.count) layoutCount=\(layout.count) "
                    + "visibleCount=0 window=\(Int(newBand.minY))...\(Int(newBand.maxY)) generation=\(layout.generation)"
            )
        }
    }
}

extension FeedMasonryWindowedGrid where Footer == EmptyView {
    init(
        items: [ListingFeedItem],
        coordinateSpace: String,
        @ViewBuilder cell: @escaping (ListingFeedItem, Int) -> Cell
    ) {
        self.init(items: items, coordinateSpace: coordinateSpace, footer: { EmptyView() }, cell: cell)
    }
}

#if DEBUG
/// Deterministic dataset for reproducing feed behaviour without a backend — mixed aspect ratios,
/// stable ids, seeded so every run produces the same geometry.
enum FeedMasonryDebugDataset {
    static func make(count: Int, seed: UInt64 = 0x5EED) -> [ListingFeedItem] {
        var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        let aspects: [(Int, Int)] = [(4, 5), (3, 4), (1, 1), (2, 3), (9, 16), (5, 4), (16, 9), (3, 5)]
        return (0..<count).map { index in
            let aspect = aspects[Int(next() % UInt64(aspects.count))]
            return ListingFeedItem(
                id: "debug_listing_\(index)",
                title: "Debug listing \(index)",
                coverImageWidth: aspect.0 * 200,
                coverImageHeight: aspect.1 * 200,
                priceVnd: Int64(50_000 + (next() % 200) * 10_000),
                condition: "good",
                likeCount: Int(next() % 500),
                saveCount: Int(next() % 60),
                sellerUsername: "debug_seller_\(index % 17)"
            )
        }
    }
}

#Preview("Windowed masonry — 3000 items") {
    ScrollView {
        FeedMasonryWindowedGrid(
            items: FeedMasonryDebugDataset.make(count: 3000),
            coordinateSpace: "previewScroll"
        ) { item, index in
            ListingGridCard(
                item: item,
                onTap: {},
                imageAspectRatio: ListingMasonryGrid.masonryAspectRatio(for: item)
            )
        }
    }
    .coordinateSpace(name: "previewScroll")
}
#endif
