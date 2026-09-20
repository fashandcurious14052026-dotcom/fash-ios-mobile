# Home Feed — Masonry Architecture (iOS)

Two-column Pinterest-style feed on the Home tabs (`Hunt today`, `Picked for you`, `Following`, …).
This document is the contract for `Fash/ui/home/HomeFeedContent.swift`,
`Fash/ui/feed/FeedMasonryLayout.swift` and `Fash/ui/feed/FeedMasonryWindowedGrid.swift`.

## Why this exists

Builds 381–393 shipped a "sliding window" that physically trimmed and re-prepended the item array bound
to a `LazyVStack` of chunk rows, keyed every chunk's identity to `items[0]`, and then moved the
`UIScrollView.contentOffset` by an *estimated* height on the next run-loop tick. Every window shift
therefore destroyed the whole lazy hierarchy and guessed a new scroll offset. The user saw a blank
masonry, then cards reappearing at a different position, and sometimes item 0 rendered halfway down the
screen. Six follow-up builds added gap classifiers, negative padding, repaint tokens and a "blank-top"
reload; none addressed the lifecycle. Build 394 replaces the mechanism.

## Four concepts, four owners

| Concept | Owner | Mutations |
|---|---|---|
| **Logical feed** | `HomeTabFeedState.store` / `followingStore` (`FeedGlobalItemStore`) → `HomeViewModel.items` | append (pagination), in-place patch (like/save), reset (refresh / tab reload). **Never trimmed.** |
| **Pagination** | `HomeViewModel.loadMore*` | offset = items ever loaded; cursor for Following |
| **Masonry layout state** | `FeedMasonryLayoutStore` (per tab, in view `@State`) | append-only extension in O(new); full rebuild only when the prefix or column width changes |
| **Render window** | `FeedMasonryWindowedGrid.band` | derived from the viewport, quantized to 256 pt steps |

Scroll position is not a concept the feed manipulates. Content above the viewport never changes
height, so the anchor is trivially preserved and no compensation exists.

## Layout model

```
item id  →  column (shortest at placement, tie → left)
         →  height = columnWidth / clamp(coverW / coverH, 0.3, 2.5)   (4:5 when unknown)
         →  y      = previous tile in that column + 8 pt
```

* Geometry depends only on item order, cover aspect ratios and metrics — never on image decoding.
* `FeedMasonryLayout.generation` increments on every full rebuild and is logged with each window.
* `FeedMasonryLayout.validate(against:)` checks unique ids, index/id agreement, finite positive
  geometry and valid columns. `FeedMasonryLayoutStore.commit` refuses an invalid candidate and keeps the
  last valid layout (`[MasonryInvariantViolation]` in the log).
* The store is resolved **inside `body`** so placements and items always come from the same render pass.

## Render window

```
visibleMinY = -grid.frame(in: .named("homeFeedScroll")).minY
lead        = max(320, viewportHeight * 0.75)
base        = floor(visibleMinY / 256) * 256
band        = [base - lead, base + 256 + viewportHeight + lead]
```

One `GeometryReader` on the whole grid emits the band as a `PreferenceKey`; `@State` is only written
when the quantized band changes, so `body` runs roughly once per 256 pt of scrolling, not per frame.
Visible placements are found with a per-column binary search on the monotonic `maxY`.

The grid reserves its full deterministic height with an empty spacer and absolutely positions windowed
cells with `.offset`. `ScrollView` content size is therefore exact from the first frame; `LazyVStack`
height estimation is no longer involved.

The pagination footer joins the hierarchy only while the band reaches the end of the grid, so its
`onAppear` means "near the bottom".

## Identity

* Cells: `ForEach(visible)` keyed by `FeedMasonryPlacement.id` == listing id.
* Grid subtree: `.id(selectedFeedTabKey)` so each tab owns its own layout store and band.
* Image state transitions never touch identity or geometry.

## Instrumentation (`FEED_PERF_LOG=1`)

```
[HomeFeed] layout appended gen=3 items=120 height=18240 columnWidth=167
[HomeFeed] window 2304...5120 -> 2560...5376 logicalFeedCount=120 layoutGeneration=3 layoutCount=120 visibleItems=34 anchor=<id> contentHeight=18240
[MasonryInvariantViolation] logicalFeedCount=… layoutCount=… visibleCount=0 window=… generation=…
```

## Rules (enforced by `scripts/validate_masonry_layout.sh`)

* Home must not use `FeedSlidingWindow`, `FeedScrollTrimCompensator`, trim tokens or gap compensators.
* Do not "fix" whitespace with negative padding, delays, repeated `scrollTo`, `.id(UUID())` or reloads.
* Column imbalance between the two columns is a valid masonry state, not a gap.

## Debug dataset

`FeedMasonryDebugDataset.make(count:)` (DEBUG only) produces seeded items with mixed aspect ratios;
the `#Preview` in `FeedMasonryWindowedGrid.swift` renders 3000 of them.
