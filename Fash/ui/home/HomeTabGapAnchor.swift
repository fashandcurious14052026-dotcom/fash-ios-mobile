import SwiftUI
import UIKit

// MARK: - First Content Position Tracking

/// MinY of the first rendered product card in the named scroll coordinate space.
/// Produced only by the first chunk of `FeedMasonryChunkedGrid` when
/// `coordinateSpaceForFirstContent` is provided. Never fires on every cell.
struct HomeFeedFirstContentMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// MARK: - Gap Feed Context

/// Snapshot of feed state passed to the classifier at evaluation time.
struct HomeGapFeedContext {
    let isLoading: Bool
    let isRefreshing: Bool
    let isUserInteracting: Bool
    let itemCount: Int
    let timeSinceLastMutation: TimeInterval
    let timeSinceLastCollapse: TimeInterval
    let currentCollapseOffset: CGFloat
}

// MARK: - Gap Category

enum HomeGapCategory: Equatable {
    /// Gap is within normal tolerance — no action needed.
    case normal
    /// Feed is loading, refreshing, or user is actively scrolling — defer evaluation.
    case loading
    /// Layout recently mutated (trim/restore); re-schedule after grace period.
    case masonryReconstructing
    /// Confirmed abnormal gap — collapse by this many points.
    case abnormal(collapsePx: CGFloat)
}

// MARK: - Gap Classifier

enum HomeTabGapClassifier {
    /// Maximum gap considered "normal" between tab bar bottom and first product card.
    /// feedBodyContent has .padding(.top, spacing.spacing2 ≈ 8pt) + LazyVStack spacing before
    /// the first chunk (≈ 8pt for widthProbe→chunk0 spacing). Total expected ≈ 16–28pt.
    static let normalMaxGapPts: CGFloat = 36

    /// Excess above normal required before we classify as abnormal.
    /// Prevents false positives from minor layout fluctuations.
    static let abnormalThresholdPts: CGFloat = 72

    /// After a feed mutation, wait this long for layout to settle before evaluating.
    static let mutationGracePeriod: TimeInterval = 0.65

    /// After applying a collapse, suppress re-evaluation for this long to break potential loops.
    static let postCollapseSuppressionPeriod: TimeInterval = 3.0

    /// Maximum points we will collapse in a single correction pass.
    static let maxCollapsePts: CGFloat = 480

    static func classify(
        viewportGap: CGFloat,
        context: HomeGapFeedContext
    ) -> HomeGapCategory {
        // No valid measurement yet.
        guard viewportGap < .greatestFiniteMagnitude / 2, viewportGap > -500 else { return .normal }
        guard context.itemCount > 0 else { return .normal }

        // Compute how much excess there is beyond expected spacing.
        // Subtract already-applied collapse to avoid double-counting.
        let apparent = viewportGap + context.currentCollapseOffset
        let excess = apparent - normalMaxGapPts
        guard excess > abnormalThresholdPts else { return .normal }

        // Post-collapse suppression window — prevents animation loops.
        guard context.timeSinceLastCollapse > postCollapseSuppressionPeriod else { return .normal }

        if context.isLoading || context.isRefreshing { return .loading }
        if context.isUserInteracting { return .loading }

        // Layout recently mutated — give it time to settle before acting.
        if context.timeSinceLastMutation < mutationGracePeriod {
            return .masonryReconstructing
        }

        let collapsePx = min(excess - abnormalThresholdPts / 2, maxCollapsePts)
        return collapsePx > 4 ? .abnormal(collapsePx: collapsePx) : .normal
    }
}

// MARK: - Live Measurements (class — no SwiftUI invalidation on property update)

/// Non-reactive mutable container for viewport-space geometry.
/// Updated from `onPreferenceChange` closures without triggering SwiftUI redraws.
final class HomeGapMeasurements {
    /// MinY of in-scroll tab row in "homeFeedScroll" viewport space. Updated on every scroll frame.
    var tabRowMinY: CGFloat = .greatestFiniteMagnitude
    /// MinY of first product card in "homeFeedScroll" viewport space. Updated on every scroll frame.
    var firstContentMinY: CGFloat = .greatestFiniteMagnitude

    /// Content-space gap between tab bottom and first card. Constant during scrolling
    /// (both values shift by -contentOffset.y, so the difference is scroll-invariant).
    func contentSpaceGap(tabRowHeight: CGFloat) -> CGFloat {
        guard tabRowMinY < .greatestFiniteMagnitude / 2 else { return .greatestFiniteMagnitude }
        guard firstContentMinY < .greatestFiniteMagnitude / 2 else { return .greatestFiniteMagnitude }
        return firstContentMinY - (tabRowMinY + tabRowHeight)
    }
}

// MARK: - Gap Collapse Scroll Compensator

/// When gap collapse shrinks the top of the feed content (by applying negative top padding),
/// compensates the UIScrollView's contentOffset so users scrolled below the gap zone
/// don't experience a visual jump.
///
/// Users who are AT the gap (watching the animation) need no compensation — the cards
/// animate naturally upward toward the tabs.
struct HomeTabGapCollapseCompensator: UIViewRepresentable {
    /// Incremented when a new collapse is committed.
    var token: Int
    /// Negative delta: content shrank, offset must decrease to preserve viewport position.
    var signedDeltaY: CGFloat
    /// Content-space Y of the tab bar bottom. Only compensate if contentOffset.y exceeds this.
    var tabBottomContentY: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isHidden = true
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard token != context.coordinator.lastToken else { return }
        context.coordinator.lastToken = token
        guard abs(signedDeltaY) > 0.5 else { return }
        let delta = signedDeltaY
        let threshold = tabBottomContentY
        DispatchQueue.main.async {
            guard let sv = uiView.enclosingScrollView() else { return }
            let adjustedTop = -sv.adjustedContentInset.top
            let currentY = sv.contentOffset.y
            // Only compensate if the user is scrolled past the gap region.
            guard currentY > adjustedTop + threshold + 8 else { return }
            let newY = max(adjustedTop, currentY + delta)
            sv.setContentOffset(CGPoint(x: 0, y: newY), animated: false)
        }
    }

    final class Coordinator { var lastToken = 0 }
}

private extension UIView {
    func enclosingScrollView() -> UIScrollView? {
        var v: UIView? = superview
        while let candidate = v {
            if let sv = candidate as? UIScrollView { return sv }
            v = candidate.superview
        }
        return nil
    }
}
