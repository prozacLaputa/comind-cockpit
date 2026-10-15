import SwiftUI

/// Small, shared motion vocabulary. Every call site respects Reduce Motion.
enum CockpitMotion {
    static let feedbackDuration = 0.12
    static let feedback = Animation.easeOut(duration: feedbackDuration)
    static let navigation = Animation.easeInOut(duration: 0.18)
    static let presentation = Animation.easeInOut(duration: 0.20)
    static let selection = Animation.spring(response: 0.24, dampingFraction: 0.9)
}

/// Active only while a loading indicator is mounted; no timer or background task.
struct CockpitSpinner: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false
    var body: some View {
        Circle().trim(from: 0.08, to: 0.78)
            .stroke(theme.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(turning && !reduceMotion ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.85).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .onDisappear { turning = false }
            .accessibilityHidden(true)
    }
}
