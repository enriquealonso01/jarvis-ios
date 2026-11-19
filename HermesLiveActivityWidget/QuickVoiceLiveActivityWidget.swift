import SwiftUI
import WidgetKit

/// Quick Voice's recording pill: a red dot, the system-drawn elapsed timer, and one
/// message line. The tap target only exists once the send succeeded, so a recording or
/// sending pill taps nowhere and a done pill opens the chat the note created.
struct QuickVoiceLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuickVoiceActivityAttributes.self) { context in
            QuickVoicePillView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.state.destinationURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    QuickVoiceDot(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startedAt...Date(timeIntervalSinceNow: 86_400),
                         countsDown: false)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundColor(QuickVoiceDot.color(for: context.state))
                        .frame(maxWidth: 72, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.message)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(2)
                }
            } compactLeading: {
                QuickVoiceDot(state: context.state)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date(timeIntervalSinceNow: 86_400),
                     countsDown: false)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundColor(QuickVoiceDot.color(for: context.state))
                    .frame(maxWidth: 48)
            } minimal: {
                QuickVoiceDot(state: context.state)
            }
            .widgetURL(context.state.destinationURL)
            .keylineTint(QuickVoiceDot.color(for: context.state))
        }
    }
}

/// The lock-screen pill: dot, timer, one line.
private struct QuickVoicePillView: View {
    let state: QuickVoiceActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            QuickVoiceDot(state: state)
            Text(timerInterval: state.startedAt...Date(timeIntervalSinceNow: 86_400),
                 countsDown: false)
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundColor(.white)
                .frame(maxWidth: 88, alignment: .leading)
            Text(state.message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The pill's dot: red and pulsing-looking while recording (no continuously repainting
/// animation), JARVIS's tint once sent.
private struct QuickVoiceDot: View {
    let state: QuickVoiceActivityAttributes.ContentState

    static func color(for state: QuickVoiceActivityAttributes.ContentState) -> Color {
        switch state.phase {
        case .recording: return .red
        case .sending: return .orange
        case .done: return .green
        case .failed: return .red.opacity(0.7)
        }
    }

    var body: some View {
        Circle()
            .fill(Self.color(for: state))
            .frame(width: 10, height: 10)
    }
}
