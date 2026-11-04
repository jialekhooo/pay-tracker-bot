import SwiftUI
import WidgetKit
import ActivityKit

private let teal = Color(red: 0.071, green: 0.42, blue: 0.369)
private let mint = Color(red: 0.55, green: 0.86, blue: 0.74)

/// Lock Screen and Dynamic Island card while a shift is on.
/// The timer and progress bar run on their own, so the card stays current without the app open.
struct LiveShiftWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveShiftAttributes.self) { context in
            LiveShiftLockScreen(state: context.state, ended: context.isStale)
                .widgetURL(context.isStale ? context.state.finishURL : context.state.shiftURL)
                .activityBackgroundTint(Color(red: 0.06, green: 0.2, blue: 0.18))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(state.event, systemImage: "briefcase.fill").font(.subheadline.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(mint).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.payText).font(.subheadline.weight(.bold)).monospacedDigit().padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale {
                        Text("Shift over. Tap to confirm your finish time.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(timerInterval: state.start...state.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                                .tint(mint)
                            TimeRow(state: state).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                Image(systemName: "briefcase.fill").foregroundStyle(mint)
            } compactTrailing: {
                if context.isStale { Image(systemName: "checkmark.circle").foregroundStyle(mint) }
                else { Text(timerInterval: state.start...state.end, countsDown: true).monospacedDigit().multilineTextAlignment(.trailing).frame(width: 66).foregroundStyle(mint) }
            } minimal: {
                Image(systemName: "briefcase.fill").foregroundStyle(mint)
            }
            .widgetURL(context.isStale ? state.finishURL : state.shiftURL)
            .keylineTint(mint)
        }
    }
}

private struct LiveShiftLockScreen: View {
    let state: LiveShiftAttributes.ContentState
    let ended: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.event).font(.headline).lineLimit(1)
                    if !state.location.isEmpty { Text(state.location).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.payText).font(.title3.weight(.bold)).monospacedDigit()
                    Text(ended ? "booked pay" : "when you finish").font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            }
            if ended {
                Label("Shift over. Tap to confirm what time you finished.", systemImage: "clock.badge.checkmark")
                    .font(.subheadline).foregroundStyle(mint)
            } else {
                ProgressView(timerInterval: state.start...state.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(mint)
                TimeRow(state: state).font(.caption).foregroundStyle(.white.opacity(0.75))
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

/// Start time, time left (centred) and end time under the progress bar.
private struct TimeRow: View {
    let state: LiveShiftAttributes.ContentState
    var body: some View {
        ZStack {
            HStack { Text(state.start, style: .time); Spacer(); Text(state.end, style: .time) }
            HStack(spacing: 4) {
                Text(timerInterval: state.start...state.end, countsDown: true).monospacedDigit()
                    .multilineTextAlignment(.trailing).frame(width: 64, alignment: .trailing)
                Text("left")
            }.fontWeight(.semibold)
        }
    }
}
