import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

private let teal = Color(red: 0.071, green: 0.42, blue: 0.369)
private let mint = Color(red: 0.55, green: 0.86, blue: 0.74)

/// Lock Screen and Dynamic Island card from 30 minutes before a shift until it's over, with Penny keeping you company.
/// Before the shift it counts down to the start; then the timer and progress bar run on their own, so the card
/// stays current without the app open.
struct LiveShiftWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveShiftAttributes.self) { context in
            let phase = ShiftPhase(context.state, stale: context.isStale)
            LiveShiftLockScreen(state: context.state, attributes: context.attributes, phase: phase)
                .widgetURL(phase == .ended ? context.state.finishURL : context.state.shiftURL)
                .activityBackgroundTint(Color(red: 0.06, green: 0.2, blue: 0.18))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let phase = ShiftPhase(state, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PennyFace(size: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.event).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(mint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.payText).font(.subheadline.weight(.bold)).monospacedDigit().padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        switch phase {
                        case .upcoming:
                            StartsRow(state: state).font(.subheadline)
                        case .working:
                            ProgressView(timerInterval: state.start...state.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                                .tint(mint)
                            TimeRow(state: state).font(.caption2).foregroundStyle(.secondary)
                        case .ended:
                            Text("Shift over. When did you finish?").font(.footnote).foregroundStyle(.secondary)
                        }
                        if phase != .upcoming { FinishButtons(attributes: context.attributes, ended: phase == .ended) }
                    }.padding(.horizontal, 4)
                }
            } compactLeading: {
                PennyFace(size: 26)
            } compactTrailing: {
                switch phase {
                case .upcoming:
                    // Counting down to the start, in white so it reads differently from time left (mint).
                    Text(timerInterval: Date()...max(Date(), state.start), countsDown: true).monospacedDigit()
                        .multilineTextAlignment(.trailing).frame(width: 66).foregroundStyle(.white)
                case .working:
                    Text(timerInterval: state.start...state.end, countsDown: true).monospacedDigit().multilineTextAlignment(.trailing).frame(width: 66).foregroundStyle(mint)
                case .ended:
                    Image(systemName: "checkmark.circle").foregroundStyle(mint)
                }
            } minimal: {
                PennyFace(size: 24)
            }
            .widgetURL(phase == .ended ? state.finishURL : state.shiftURL)
            .keylineTint(mint)
        }
    }
}

/// Where the shift is, worked out when iOS draws the card. iOS redraws it at its stale date: the start time while
/// counting down (the app and server then move the stale date to the end), and the end time while working.
private enum ShiftPhase {
    case upcoming, working, ended
    init(_ state: LiveShiftAttributes.ContentState, stale: Bool) {
        let now = Date()
        if now < state.start { self = .upcoming }
        else if stale && now >= state.end { self = .ended }
        else { self = .working }
    }
}

/// "Starts at 9:00 PM" and a countdown to it, before the shift begins.
private struct StartsRow: View {
    let state: LiveShiftAttributes.ContentState
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").foregroundStyle(mint)
            (Text("Starts at ") + Text(state.start, style: .time)).fontWeight(.semibold)
            Spacer(minLength: 4)
            // One piece of text, so "in" sits right beside the countdown rather than across a fixed-width gap.
            (Text("in ") + Text(timerInterval: Date()...max(Date(), state.start), countsDown: true).fontWeight(.semibold))
                .monospacedDigit().multilineTextAlignment(.trailing)
        }.foregroundStyle(.white)
    }
}

private struct LiveShiftLockScreen: View {
    let state: LiveShiftAttributes.ContentState
    let attributes: LiveShiftAttributes
    let phase: ShiftPhase
    private var ended: Bool { phase == .ended }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                PennyFace(size: 44)
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
            switch phase {
            case .upcoming:
                StartsRow(state: state).font(.subheadline)
            case .working:
                ProgressView(timerInterval: state.start...state.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(mint)
                TimeRow(state: state).font(.caption).foregroundStyle(.white.opacity(0.75))
            case .ended:
                Label("Shift over. When did you finish?", systemImage: "clock.badge.checkmark")
                    .font(.subheadline).foregroundStyle(mint)
            }
            if phase != .upcoming { FinishButtons(attributes: attributes, ended: ended) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

/// Penny, drawn by the app into the shared app group (the extension can't run her drawing code).
/// The briefcase stands in until she has been drawn on this iPhone.
private struct PennyFace: View {
    let size: CGFloat
    var body: some View {
        if let url = PennyWidgetFile.faceURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel(PennyWidgetFile.read()?.name ?? "Penny")
        } else {
            Image(systemName: "briefcase.fill").foregroundStyle(mint)
        }
    }
}

/// Start time, time left (centred) and end time under the progress bar.
private struct TimeRow: View {
    let state: LiveShiftAttributes.ContentState
    /// On a dimmed Lock Screen iOS hides a ticking clock's seconds as "--", so show the end time instead.
    @Environment(\.isLuminanceReduced) private var dimmed
    var body: some View {
        ZStack {
            HStack { Text(state.start, style: .time); Spacer(); Text(state.end, style: .time) }
            if dimmed {
                (Text("Ends ") + Text(state.end, style: .time)).fontWeight(.semibold)
            } else {
                HStack(spacing: 4) {
                    Text(timerInterval: state.start...state.end, countsDown: true).monospacedDigit()
                        .multilineTextAlignment(.trailing).frame(width: 64, alignment: .trailing)
                    Text("left")
                }.fontWeight(.semibold)
            }
        }
    }
}

/// "+30 min" while the shift is on (staying late), plus "Finished on time" once it's over.
/// Both run in HowMuch without opening it; staying later recalculates the shift's pay, overtime included.
private struct FinishButtons: View {
    let attributes: LiveShiftAttributes
    let ended: Bool
    var body: some View {
        HStack(spacing: 8) {
            if ended {
                Button(intent: FinishShiftOnTimeIntent(shiftID: attributes.shiftID, accountID: attributes.accountID)) {
                    Label("Finished on time", systemImage: "checkmark").frame(maxWidth: .infinity)
                }.tint(mint)
            }
            Button(intent: ExtendShiftIntent(shiftID: attributes.shiftID, accountID: attributes.accountID)) {
                Label(ended ? "+30 min" : "Staying late? +30 min", systemImage: "plus").frame(maxWidth: ended ? nil : .infinity)
            }.tint(.white)
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered).buttonBorderShape(.capsule)
        .controlSize(.small)
    }
}
