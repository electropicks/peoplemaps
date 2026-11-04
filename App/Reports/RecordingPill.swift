import SwiftUI

/// The compact capsule shown while a manual recording runs: a red dot, the time so far, and Stop. The dot is the one coloured
/// mark, because it says the phone is writing locations even when the app is not on screen.
struct RecordingPill: View {
    let startedAt: Date
    let stop: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Self.elapsed(context.date.timeIntervalSince(startedAt))).font(.footnote.weight(.medium)).monospacedDigit()
                    .accessibilityLabel("Recording")
                    .accessibilityValue(Self.spoken(context.date.timeIntervalSince(startedAt)))
                    .accessibilityIdentifier("record-time")
            }
            Button(action: stop) { Text("Stop").font(.footnote.weight(.semibold)).frame(minHeight: 44) }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
                .accessibilityIdentifier("record-stop")
        }
        .foregroundStyle(.primary)
        .padding(.leading, 14).padding(.trailing, 12)
        .floatingSurface(in: Capsule(), interactive: true)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record-pill")
    }

    /// "2:05", or "1:02:05" past an hour.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func spoken(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return Duration.seconds(s).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}
