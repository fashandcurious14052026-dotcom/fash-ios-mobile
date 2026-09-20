import CoreGraphics
import Foundation

/// One placed tile in the two-column masonry.
///
/// A placement is immutable once made. The layout is append-only, so a listing keeps the same column,
/// `y` and `height` for as long as the feed prefix in front of it is unchanged — regardless of image
/// loading, view lifecycle, scroll position or pagination.
struct FeedMasonryPlacement: Equatable, Identifiable {
    /// Listing id — this is also the SwiftUI identity of the rendered cell.
    let id: String
    /// Index into the logical feed when placed. Verified against `items[index].id` before rendering.
    let index: Int
    /// 0 = left column, 1 = right column.
    let column: Int
    let y: CGFloat
    let height: CGFloat

    var maxY: CGFloat { y + height }
}

/// Deterministic two-column masonry geometry for a logical feed.
///
/// Geometry depends only on item order, cover aspect ratios and the metrics — never on measured views.
/// Appending never moves earlier placements, so content above the viewport is stable and the enclosing
/// `ScrollView` never needs scroll-offset compensation.
struct FeedMasonryLayout {
    struct Metrics: Equatable {
        var columnWidth: CGFloat
        var columnGap: CGFloat
        var verticalGap: CGFloat
        var leadingInset: CGFloat

        static let zero = Metrics(columnWidth: 0, columnGap: 0, verticalGap: 0, leadingInset: 0)
    }

    static let columnCount = 2

    let metrics: Metrics
    /// Bumped on every full rebuild; unchanged by appends. Lets logs prove which layout a window came from.
    let generation: Int
    private(set) var placements: [FeedMasonryPlacement] = []
    /// Bottom edge of the last tile in each column (no trailing gap).
    private(set) var columnBottoms: [CGFloat] = Array(repeating: 0, count: FeedMasonryLayout.columnCount)
    /// Indices into `placements` per column, ascending `y` (and ascending `maxY`).
    private(set) var columnMembers: [[Int]] = Array(repeating: [], count: FeedMasonryLayout.columnCount)

    static let empty = FeedMasonryLayout(metrics: .zero, generation: 0)

    init(metrics: Metrics, generation: Int) {
        self.metrics = metrics
        self.generation = generation
    }

    var count: Int { placements.count }
    var isEmpty: Bool { placements.isEmpty }
    var totalHeight: CGFloat { columnBottoms.max() ?? 0 }

    func x(forColumn column: Int) -> CGFloat {
        metrics.leadingInset + CGFloat(column) * (metrics.columnWidth + metrics.columnGap)
    }

    /// Shortest-column placement (tie → left). O(new items); existing placements are untouched.
    mutating func append(_ items: ArraySlice<ListingFeedItem>, startIndex: Int) {
        guard metrics.columnWidth > 0 else { return }
        placements.reserveCapacity(placements.count + items.count)
        var index = startIndex
        for item in items {
            let height = ListingMasonryGrid.tileHeight(columnWidth: metrics.columnWidth, item: item)
            let column = columnBottoms[0] <= columnBottoms[1] ? 0 : 1
            let y = columnMembers[column].isEmpty ? 0 : columnBottoms[column] + metrics.verticalGap
            placements.append(
                FeedMasonryPlacement(id: item.id, index: index, column: column, y: y, height: height)
            )
            columnMembers[column].append(placements.count - 1)
            columnBottoms[column] = y + height
            index += 1
        }
    }

    static func build(items: [ListingFeedItem], metrics: Metrics, generation: Int) -> FeedMasonryLayout {
        var layout = FeedMasonryLayout(metrics: metrics, generation: generation)
        layout.append(items[...], startIndex: 0)
        return layout
    }

    /// Placements whose vertical extent intersects `minY...maxY`, in feed order.
    /// O(log n + visible): per-column binary search on the monotonic `maxY`, then a linear walk.
    func placements(intersecting minY: CGFloat, maxY: CGFloat) -> [FeedMasonryPlacement] {
        guard !placements.isEmpty, maxY >= 0, minY <= totalHeight, minY <= maxY else { return [] }
        var result: [FeedMasonryPlacement] = []
        for members in columnMembers {
            var low = 0
            var high = members.count
            while low < high {
                let mid = (low + high) / 2
                if placements[members[mid]].maxY < minY {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            var cursor = low
            while cursor < members.count {
                let placement = placements[members[cursor]]
                if placement.y > maxY { break }
                result.append(placement)
                cursor += 1
            }
        }
        result.sort { $0.index < $1.index }
        return result
    }

    /// True when every placement still describes `items[index]` — i.e. `items` grew by appending only.
    /// O(count) id comparisons; only evaluated when a view body runs, never per scroll frame.
    func matchesPrefix(of items: [ListingFeedItem]) -> Bool {
        guard placements.count <= items.count else { return false }
        for placement in placements where items[placement.index].id != placement.id {
            return false
        }
        return true
    }

    /// Structural invariants that must hold before a layout may be committed for rendering.
    /// Returns human-readable issues; empty means valid.
    func validate(against items: [ListingFeedItem]) -> [String] {
        var issues: [String] = []
        if placements.count != items.count {
            issues.append("placement count \(placements.count) != item count \(items.count)")
        }
        guard metrics.columnWidth > 0, metrics.columnWidth.isFinite else {
            issues.append("invalid column width \(metrics.columnWidth)")
            return issues
        }
        var seen = Set<String>()
        seen.reserveCapacity(placements.count)
        for placement in placements {
            if !seen.insert(placement.id).inserted {
                issues.append("duplicate id \(placement.id)")
            }
            if placement.index >= items.count || items[placement.index].id != placement.id {
                issues.append("index/id mismatch at \(placement.index)")
            }
            if !placement.y.isFinite || !placement.height.isFinite || placement.height <= 0 || placement.y < 0 {
                issues.append("invalid geometry at \(placement.index): y=\(placement.y) h=\(placement.height)")
            }
            if placement.column < 0 || placement.column >= Self.columnCount {
                issues.append("invalid column \(placement.column) at \(placement.index)")
            }
            if issues.count >= 8 { break }
        }
        if !totalHeight.isFinite { issues.append("non-finite total height") }
        return issues
    }
}

/// Owns the committed layout for one feed.
///
/// A reference type held in view `@State` so the layout can be resolved *inside* `body`: the placements
/// rendered in a pass always belong to the `items` array rendered in that same pass. There is no frame
/// where geometry from one array is applied to items from another. Transitions are atomic — a candidate
/// layout is validated first and, if invalid, rejected in favour of the last valid layout.
///
/// Not `@Observable` on purpose: it is a cache consulted during `body`, not a source of truth that
/// should invalidate views.
final class FeedMasonryLayoutStore {
    enum Transition: String {
        case unchanged
        case appended
        case rebuilt
        case cleared
        case rejected
    }

    private(set) var layout: FeedMasonryLayout = .empty
    private(set) var lastTransition: Transition = .unchanged
    private var generation = 0

    /// Resolve the layout for `items`. Append-only growth extends the existing layout in O(new);
    /// any prefix or metrics change rebuilds in O(n). Never returns a layout that failed validation.
    func layout(for items: [ListingFeedItem], metrics: FeedMasonryLayout.Metrics) -> FeedMasonryLayout {
        guard !items.isEmpty, metrics.columnWidth > 0 else {
            if !layout.isEmpty {
                layout = .empty
                lastTransition = .cleared
            } else {
                lastTransition = .unchanged
            }
            return layout
        }

        // Full id-prefix comparison: a refresh that keeps the first and last ids but reorders the
        // middle must rebuild, otherwise the tile id guard would drop the mismatched cells.
        let prefixUnchanged = layout.metrics == metrics
            && !layout.isEmpty
            && layout.matchesPrefix(of: items)

        if prefixUnchanged && layout.count == items.count {
            lastTransition = .unchanged
            return layout
        }
        if prefixUnchanged {
            var candidate = layout
            candidate.append(items[layout.count...], startIndex: layout.count)
            commit(candidate, items: items, transition: .appended)
            return layout
        }
        generation += 1
        let candidate = FeedMasonryLayout.build(items: items, metrics: metrics, generation: generation)
        commit(candidate, items: items, transition: .rebuilt)
        return layout
    }

    private func commit(_ candidate: FeedMasonryLayout, items: [ListingFeedItem], transition: Transition) {
        let issues = candidate.validate(against: items)
        guard issues.isEmpty else {
            lastTransition = .rejected
            FeedPerformance.log(
                "[MasonryInvariantViolation] rejected \(transition.rawValue) layout gen=\(candidate.generation) "
                    + "items=\(items.count) placements=\(candidate.count): \(issues.prefix(3).joined(separator: "; "))"
            )
            assertionFailure("FeedMasonryLayout invariant violation: \(issues.first ?? "unknown")")
            return
        }
        layout = candidate
        lastTransition = transition
        FeedPerformance.log(
            "[HomeFeed] layout \(transition.rawValue) gen=\(candidate.generation) items=\(items.count) "
                + "height=\(Int(candidate.totalHeight)) columnWidth=\(Int(candidate.metrics.columnWidth))"
        )
    }
}
