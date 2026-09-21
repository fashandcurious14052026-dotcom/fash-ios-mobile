import SwiftUI
import UIKit

/// Pinterest-style pull header — ring fills while dragging; brief hold at threshold before refresh starts.
struct FashFeedPullRefreshIndicator: View {
    var progress: CGFloat
    var isRefreshing: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(FashColors.outlineMuted.opacity(0.35), lineWidth: 2.5)
                .frame(width: 28, height: 28)
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(FashColors.brandPrimary)
            } else {
                Circle()
                    .trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(
                        FashColors.brandPrimary,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .frame(width: 28, height: 28)
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(height: 36)
        .opacity(isRefreshing || progress > 0.04 ? 1 : 0)
        .scaleEffect(isRefreshing ? 1 : (0.82 + progress * 0.18))
        .animation(.easeOut(duration: 0.16), value: progress)
        .animation(.easeOut(duration: 0.16), value: isRefreshing)
    }
}

private struct FashFeedPullRefreshModifier: ViewModifier {
    @Binding var isRefreshing: Bool
    var onRefresh: () async -> Void

    @State private var pullProgress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                FashFeedPullRefreshHost(
                    isRefreshing: $isRefreshing,
                    pullProgress: $pullProgress,
                    onRefresh: onRefresh
                )
            }
            .overlay(alignment: .top) {
                FashFeedPullRefreshIndicator(progress: pullProgress, isRefreshing: isRefreshing)
                    .padding(.top, 8)
                    .offset(y: indicatorOffset)
                    .allowsHitTesting(false)
            }
    }

    private var indicatorOffset: CGFloat {
        if isRefreshing { return 10 }
        return max(-8, pullProgress * 52 - 24)
    }
}

/// Attaches to the enclosing `UIScrollView` — rubber-band pull progress without SwiftUI `.refreshable` jank.
private struct FashFeedPullRefreshHost: UIViewRepresentable {
    @Binding var isRefreshing: Bool
    @Binding var pullProgress: CGFloat
    var onRefresh: () async -> Void

    fileprivate static let triggerDistance: CGFloat = 88
    fileprivate static let holdBeforeRefresh: Duration = .milliseconds(220)
    fileprivate static let refreshingInset: CGFloat = 46

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isRefreshing: $isRefreshing,
            pullProgress: $pullProgress,
            onRefresh: onRefresh
        )
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.onRefresh = onRefresh
        let wasRefreshing = context.coordinator.wasRefreshing
        context.coordinator.wasRefreshing = isRefreshing
        if isRefreshing, !wasRefreshing {
            // Nav re-tap / programmatic refresh — keep scroll at top; only user pull snaps inset open.
            if context.coordinator.refreshInitiatedByPull {
                context.coordinator.syncExternalRefreshingState()
            }
        } else if !isRefreshing, wasRefreshing {
            context.coordinator.clearRefreshingInsetIfNeeded(animated: true)
            context.coordinator.refreshInitiatedByPull = false
            context.coordinator.reportProgress(0)
        }
        uiView.coordinator = context.coordinator
        uiView.scheduleInstall()
    }

    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleInstall()
        }

        func scheduleInstall() {
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let coordinator else { return }
                coordinator.installIfNeeded(from: self)
            }
        }
    }

    @MainActor
    final class Coordinator {
        @Binding var isRefreshing: Bool
        @Binding var pullProgress: CGFloat
        var onRefresh: () async -> Void
        var wasRefreshing = false

        private weak var scrollView: UIScrollView?
        private var offsetObservation: NSKeyValueObservation?
        private var wasDragging = false
        private var refreshTask: Task<Void, Never>?
        private var refreshingInsetApplied = false
        private var baselineContentInsetTop: CGFloat = 0
        private var lastReportedProgress: CGFloat = -1
        fileprivate var refreshInitiatedByPull = false

        init(
            isRefreshing: Binding<Bool>,
            pullProgress: Binding<CGFloat>,
            onRefresh: @escaping () async -> Void
        ) {
            _isRefreshing = isRefreshing
            _pullProgress = pullProgress
            self.onRefresh = onRefresh
        }

        func installIfNeeded(from anchor: UIView) {
            guard let scrollView = anchor.enclosingScrollView() else { return }
            if self.scrollView === scrollView, offsetObservation != nil { return }

            offsetObservation?.invalidate()
            self.scrollView = scrollView
            scrollView.refreshControl = nil

            offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                // Already on the main thread for UIScrollView offset changes — skip the per-frame Task hop.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.handleContentOffsetChange(sv) }
                } else {
                    Task { @MainActor in self?.handleContentOffsetChange(sv) }
                }
            }
        }

        private func handleContentOffsetChange(_ scrollView: UIScrollView) {
            let dragging = scrollView.isDragging || scrollView.isTracking
            if wasDragging, !dragging, !isRefreshing {
                tryCommitRefresh(on: scrollView)
            }
            wasDragging = dragging

            guard !isRefreshing, !refreshingInsetApplied else { return }
            let pull = currentPullDistance(on: scrollView)
            if pull <= 0, lastReportedProgress <= 0 { return }
            let progress = min(1, pull / FashFeedPullRefreshHost.triggerDistance)
            reportProgress(progress)
        }

        private func currentPullDistance(on scrollView: UIScrollView) -> CGFloat {
            max(0, -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top))
        }

        fileprivate func reportProgress(_ progress: CGFloat) {
            guard abs(progress - lastReportedProgress) > 0.04 || progress == 0 else { return }
            lastReportedProgress = progress
            pullProgress = progress
        }

        private func tryCommitRefresh(on scrollView: UIScrollView) {
            guard !isRefreshing else { return }
            let pull = currentPullDistance(on: scrollView)
            guard pull >= FashFeedPullRefreshHost.triggerDistance else {
                reportProgress(0)
                return
            }

            refreshInitiatedByPull = true
            refreshTask?.cancel()
            refreshTask = Task { @MainActor in
                snapToRefreshingHold(on: scrollView, animated: true)
                try? await Task.sleep(for: FashFeedPullRefreshHost.holdBeforeRefresh)
                guard !Task.isCancelled, !isRefreshing else { return }
                await runRefresh(on: scrollView)
            }
        }

        func syncExternalRefreshingState() {
            guard let scrollView, !refreshingInsetApplied else { return }
            snapToRefreshingHold(on: scrollView, animated: true)
            reportProgress(1)
        }

        private func runRefresh(on scrollView: UIScrollView) async {
            if refreshInitiatedByPull {
                snapToRefreshingHold(on: scrollView, animated: false)
                reportProgress(1)
            }
            await onRefresh()
            if refreshInitiatedByPull {
                releaseRefreshingHold(on: scrollView, animated: true)
            }
            refreshInitiatedByPull = false
            reportProgress(0)
        }

        private func snapToRefreshingHold(on scrollView: UIScrollView, animated: Bool) {
            if baselineContentInsetTop == 0 {
                baselineContentInsetTop = scrollView.contentInset.top
            }
            let top = baselineContentInsetTop + FashFeedPullRefreshHost.refreshingInset
            let holdOffset = -top
            refreshingInsetApplied = true
            let adjust = {
                scrollView.contentInset.top = top
                var inset = scrollView.verticalScrollIndicatorInsets
                inset.top = top
                scrollView.verticalScrollIndicatorInsets = inset
                scrollView.contentOffset = CGPoint(x: 0, y: holdOffset)
            }
            if animated {
                UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    adjust()
                }
            } else {
                adjust()
            }
        }

        private func releaseRefreshingHold(on scrollView: UIScrollView, animated: Bool) {
            refreshTask?.cancel()
            refreshTask = nil
            guard refreshingInsetApplied else { return }
            refreshingInsetApplied = false
            let top = baselineContentInsetTop
            baselineContentInsetTop = 0
            let releaseOffset = top > 0.5 ? -top : 0
            let adjust = {
                scrollView.contentInset.top = top
                var inset = scrollView.verticalScrollIndicatorInsets
                inset.top = top
                scrollView.verticalScrollIndicatorInsets = inset
                if scrollView.contentOffset.y < releaseOffset - 1 {
                    scrollView.contentOffset = CGPoint(x: 0, y: releaseOffset)
                }
            }
            if animated {
                UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                    adjust()
                }
            } else {
                adjust()
            }
            reportProgress(0)
        }

        func clearRefreshingInsetIfNeeded(animated: Bool) {
            guard let scrollView, refreshingInsetApplied else { return }
            releaseRefreshingHold(on: scrollView, animated: animated)
        }
    }
}

extension View {
    /// Elastic pull-to-refresh — Pinterest-style hold at threshold, feed-first refresh callback.
    func fashFeedPullRefresh(
        isRefreshing: Binding<Bool>,
        onRefresh: @escaping () async -> Void
    ) -> some View {
        modifier(
            FashFeedPullRefreshModifier(
                isRefreshing: isRefreshing,
                onRefresh: onRefresh
            )
        )
    }
}

private extension UIView {
    func enclosingScrollView() -> UIScrollView? {
        var candidate: UIView? = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            candidate = view.superview
        }
        return nil
    }
}
