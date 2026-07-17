import SwiftUI
import UIKit

/// Pull distance via layout frames — iOS 17 fallback only.
struct HomePullOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Streams the pull-down distance from the scroll geometry on iOS 18+.
struct HomePullOffsetReader: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, pull in
                onChange(pull)
            }
        } else {
            content
        }
    }
}

// MARK: - Pull-down-to-force-loop

extension Home.RootView {
    /// Pull hint while dragging. Disappears once the loop triggers — the
    /// animated loop pill is the running feedback.
    @ViewBuilder var pullToRefreshIndicator: some View {
        if !isForcingLoop, pullOffset > 4 {
            let progress = min(pullOffset / HomeLayout.refreshTriggerDistance, 1)
            HStack(spacing: 8) {
                Image(systemName: "arrow.down")
                    .rotationEffect(.degrees(progress * 180))
                Text("Pull down to force loop")
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .opacity(progress)
            .frame(height: HomeLayout.refreshIndicatorHeight)
            .frame(maxWidth: .infinity)
        }
    }

    /// Arms once per pull at the threshold; re-arms after the pull settles.
    func handlePullChange(_ offset: CGFloat) {
        pullOffset = offset
        guard !isForcingLoop else { return }
        if offset >= HomeLayout.refreshTriggerDistance, !isRefreshArmed {
            isRefreshArmed = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            forceLoop()
        } else if offset <= 1, isRefreshArmed {
            isRefreshArmed = false
        }
    }

    /// Triggers the loop heartbeat; `isForcingLoop` guards against re-triggering
    /// while a forced run is still in flight (the loop pill shows the progress).
    private func forceLoop() {
        isForcingLoop = true
        state.runLoop()
        // Main actor: the poll reads observable state that mutates on main,
        // and it only sleeps between reads, so it never blocks the UI.
        Task { @MainActor in
            let start = Date()
            while !state.isLooping, Date().timeIntervalSince(start) < 3 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            while state.isLooping, Date().timeIntervalSince(start) < 30 {
                try? await Task.sleep(for: .milliseconds(200))
            }
            // Minimum guard duration so quick loops can't double-trigger.
            if Date().timeIntervalSince(start) < 1 {
                try? await Task.sleep(for: .seconds(1))
            }
            isForcingLoop = false
        }
    }
}
