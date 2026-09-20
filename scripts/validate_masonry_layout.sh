#!/usr/bin/env bash
# Sanity checks for incremental masonry layout APIs used by Home/Profile feeds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

fail=0

if ! grep -q 'extendStableColumnLayout' Fash/ui/feed/ListingMasonryGrid.swift; then
  echo "::error::ListingMasonryGrid.extendStableColumnLayout missing"
  fail=1
fi

if ! grep -q 'struct FeedMasonryLayout' Fash/ui/feed/FeedMasonryLayout.swift; then
  echo "::error::FeedMasonryLayout missing"
  fail=1
fi

if ! grep -q 'struct FeedMasonryWindowedGrid' Fash/ui/feed/FeedMasonryWindowedGrid.swift; then
  echo "::error::FeedMasonryWindowedGrid missing"
  fail=1
fi

# The Home feed must never trim its logical feed or compensate scroll offsets again — those were the
# root cause of the blank/reconstructing masonry (builds 381–393).
if grep -qE 'FeedSlidingWindow|FeedScrollTrimCompensator|homeFeedTrimToken|HomeTabGapCollapseCompensator' \
    Fash/ui/home/HomeViewModel.swift Fash/ui/home/HomeFeedContent.swift; then
  echo "::error::Home feed must not use sliding-window trimming or scroll compensation (see docs/HOME_FEED_MASONRY.md)"
  fail=1
fi

if ! grep -q 'parseFeedItems' Fash/data/listing/ListingFeedParseSupport.swift; then
  echo "::error::ListingFeedParseSupport.parseFeedItems missing"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi

echo "Masonry layout self-check passed."
