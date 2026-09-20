import Foundation

// MARK: - Gap Detection

/// Diagnostic record for a detected blank area in the masonry layout.
/// Produced post-mutation only — never on scroll events.
struct FeedLayoutGap {
    /// Chunk index (0-based) where the blank was found.
    let chunkIndex: Int
    /// Which column is blank (false = left, true = right, nil = entire chunk).
    let column: Bool?
    /// IDs of items adjacent to the gap, for debugging.
    let neighboringItemIds: [String]
    /// Human-readable cause (empty_chunk, stale_layout, mismatched_assignment).
    let reason: String
    /// 0.0–1.0 — how confident we are this is a real gap vs. a transient layout moment.
    let confidence: Float
    /// True when a native ad or promotional card can safely fill this gap.
    let isSafeForFallback: Bool
}

// MARK: - Native Ad Slot

/// Stable, session-scoped identity for a native ad position in the home feed.
/// Generated once per tab feed window, not per render.
struct FeedNativeAdSlot: Identifiable, Sendable {
    /// UUID stable for the lifetime of this feed session.
    let id: UUID
    /// 0-based index into the merged feed item list where this ad appears.
    let slotIndex: Int
    /// Opaque key combining tab + session generation, for cache keying.
    let sessionKey: String
    /// Ad content once loaded asynchronously; nil while pending.
    var content: FeedNativeAdContent?
    /// True once an ad has been confirmed loaded and renderable.
    var isReady: Bool { content != nil }
}

enum FeedNativeAdContent: Sendable {
    /// A promotional listing from FASH's own catalogue (safe, same card style).
    case promotionalListing(ListingFeedItem)
    /// A lightweight editorial card (brand banner, curated collection link).
    case editorialCard(title: String, imageUrl: String?, actionKey: String)
}

// MARK: - Frequency Policy

enum HomeFeedAdFrequency {
    /// Minimum number of listing items between two ad slots.
    static let minItemsBetweenAds = 12
    /// Maximum ad slots per full feed window.
    static let maxAdsPerWindow = 4
    /// Maximum cumulative ad slots per session (across pagination).
    static let maxAdsPerSession = 12
    /// Minimum item count before any ad is eligible.
    static let minItemsBeforeFirstAd = 8
}

// MARK: - Slot Generator

enum FeedNativeAdSlotGenerator {
    /// Generate stable ad slot positions for a feed window.
    /// Uses a deterministic shuffle seeded on `sessionSeed` so positions do not
    /// change on re-render but do vary between sessions.
    ///
    /// - Parameters:
    ///   - itemCount: Total items in the current window.
    ///   - sessionSeed: Stable seed (e.g. first-item id hash).
    ///   - tabKey: Feed tab key, baked into `FeedNativeAdSlot.sessionKey`.
    ///   - generation: Tab load generation, prevents stale slots after a reload.
    /// - Returns: Up to `HomeFeedAdFrequency.maxAdsPerWindow` slot positions.
    static func generate(
        itemCount: Int,
        sessionSeed: Int,
        tabKey: String,
        generation: UInt
    ) -> [FeedNativeAdSlot] {
        let minBefore = HomeFeedAdFrequency.minItemsBeforeFirstAd
        let minBetween = HomeFeedAdFrequency.minItemsBetweenAds
        let maxSlots = HomeFeedAdFrequency.maxAdsPerWindow
        guard itemCount > minBefore + minBetween else { return [] }

        var rng = SeededRNG(seed: UInt64(bitPattern: Int64(sessionSeed)))
        var slots: [FeedNativeAdSlot] = []
        var lastPosition = minBefore
        let sessionKey = "\(tabKey)_\(generation)"

        while slots.count < maxSlots {
            let spacing = minBetween + Int(rng.next() % 8)
            let position = lastPosition + spacing
            guard position < itemCount - 2 else { break }
            slots.append(FeedNativeAdSlot(
                id: UUID(),
                slotIndex: position,
                sessionKey: sessionKey
            ))
            lastPosition = position
        }
        return slots
    }
}

// MARK: - Seeded RNG

private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 6364136223846793005 : seed
    }

    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
