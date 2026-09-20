# Home Feed — Cursor Pagination

TikTok-style infinite scroll for tab **Following** (`GET /listings/home`).
Masonry rendering / windowing is documented in [HOME_FEED_MASONRY.md](./HOME_FEED_MASONRY.md).

## Backend (core-service)

```
GET /listings/home?pagination=cursor&limit=20
GET /listings/home?pagination=cursor&limit=20&cursor={created_at_nano}:{listing_id}
```

Response:

```json
{
  "listings": [],
  "has_more": true,
  "next_cursor": "1718352000000000000:550e8400-e29b-41d4-a716-446655440000"
}
```

- Sort: `ORDER BY created_at DESC, id DESC` (stable keyset)
- Legacy `offset` still returns bare array for Android until migrated

## iOS

| Layer | Responsibility |
|-------|----------------|
| `ListingRepository.getHomeFeedPage` | Cursor API |
| `FeedGlobalItemStore` | Append-only, deduplicated logical feed per tab (never trimmed) |
| `FeedMasonryWindowedGrid` | Renders only the placements inside the viewport band |
| `HomeFeedScrollCoordinator` | Sticky tab chrome + `allowsFollowingLoadMore` gating |
| `HomeViewModel` | Single `isLoadingMoreFollowing` guard; append-only |

### Memory

Items are structs of a few hundred bytes; 3000 rows ≈ 1 MB. Decoded images are owned by the
Kingfisher cache (bounded, memory-warning aware) and only the ~40–80 windowed cells hold a live
`KFImage`. There is no item-array trimming.

### Prefetch

- Cell `onAppear` when `index >= count - 8` (`FeedPaginationPolicy`)
- Footer sentinel (`FeedLoadMoreFooter`) is in the hierarchy only while the render window reaches the
  end of the grid; one load per footer visit
