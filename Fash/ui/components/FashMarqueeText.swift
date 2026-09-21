import SwiftUI

private struct FashMarqueeSuspendedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the enclosing feed is actively scrolling. Marquees show their static label and run no
    /// animation, so dozens of off-screen ticker animations never compete with the scroll for frame time.
    /// They resume (after their initial delay) once the scroll settles.
    var fashMarqueeSuspended: Bool {
        get { self[FashMarqueeSuspendedKey.self] }
        set { self[FashMarqueeSuspendedKey.self] = newValue }
    }
}

/// Horizontal marquee when label overflows — Android `basicMarquee`.
struct FashMarqueeText: View {
    @Environment(\.fashMarqueeSuspended) private var suspended
    let text: String
    var font: Font = FashTypography.bodySmall
    var fontWeight: Font.Weight = .regular
    var color: Color = .white
    var lineHeight: CGFloat = 16
    var initialDelayMs: UInt64 = 900
    var repeatDelayMs: UInt64 = 1_200
    var velocity: CGFloat = 35
    /// When true, loops continuously with duplicated segments (ad-style ticker).
    var continuousLoop: Bool = false
    var segmentGap: CGFloat = 28

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var marqueeTask: Task<Void, Never>?

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    private var shouldScroll: Bool { !suspended && overflow > 1 && !text.isEmpty && containerWidth > 1 }
    private var loopTravel: CGFloat {
        continuousLoop ? textWidth + segmentGap : overflow
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: lineHeight, maxHeight: lineHeight)
            .overlay(alignment: .leading) {
                staticLabel
                    .opacity(shouldScroll ? 0 : 1)
            }
            .overlay(alignment: .leading) {
                if shouldScroll {
                    scrollingLabel
                        .offset(x: offset)
                }
            }
            .clipped()
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { containerWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, width in
                            containerWidth = width
                            restartMarquee()
                        }
                }
            }
            .background {
                Text(text)
                    .font(font.weight(fontWeight))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { textGeo in
                            Color.clear
                                .preference(key: FashMarqueeTextWidthKey.self, value: textGeo.size.width)
                        }
                    }
                    .hidden()
            }
            .onPreferenceChange(FashMarqueeTextWidthKey.self) { width in
                textWidth = width
                restartMarquee()
            }
            .onChange(of: text) { _, _ in
                restartMarquee()
            }
            .onChange(of: suspended) { _, isSuspended in
                if isSuspended {
                    marqueeTask?.cancel()
                    marqueeTask = nil
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { offset = 0 }
                } else {
                    restartMarquee()
                }
            }
            .onDisappear {
                marqueeTask?.cancel()
                marqueeTask = nil
                offset = 0
            }
    }

    private var staticLabel: some View {
        Text(text)
            .font(font.weight(fontWeight))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var scrollingLabel: some View {
        if continuousLoop {
            HStack(spacing: segmentGap) {
                marqueeSegment
                marqueeSegment
            }
            .fixedSize(horizontal: true, vertical: false)
        } else {
            marqueeSegment
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var marqueeSegment: some View {
        Text(text)
            .font(font.weight(fontWeight))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func restartMarquee() {
        marqueeTask?.cancel()
        offset = 0
        guard shouldScroll else { return }

        marqueeTask = Task { @MainActor in
            while !Task.isCancelled {
                offset = 0
                if !continuousLoop {
                    try? await Task.sleep(nanoseconds: initialDelayMs * 1_000_000)
                    guard !Task.isCancelled, shouldScroll else { continue }
                }

                let travel = loopTravel
                let duration = max(0.35, Double(travel / velocity))
                withAnimation(.linear(duration: duration)) {
                    offset = -travel
                }
                let scrollNs = UInt64(duration * 1_000_000_000)
                try? await Task.sleep(nanoseconds: scrollNs)
                guard !Task.isCancelled else { return }

                if !continuousLoop {
                    withAnimation(.none) { offset = 0 }
                    try? await Task.sleep(nanoseconds: repeatDelayMs * 1_000_000)
                }
            }
        }
    }
}

private struct FashMarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
