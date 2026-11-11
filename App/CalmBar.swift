import SwiftUI
import PeoplemapsCore

/// A rating as a system capacity gauge: the fill is the 0 to 100 calm score, its tint the level. Hidden from VoiceOver; whatever
/// holds it says the word and the score. Words and scores carry the meaning, colour only adds to it.
struct CalmMeter: View {
    let score: CalmScore
    /// Kept for callers. The system gauge has one thickness and ignores it.
    var height: CGFloat = 10

    var body: some View {
        Gauge(value: Double(score.value), in: 0...100) { EmptyView() }
            .gaugeStyle(.linearCapacity).tint(Color.calmFill(score.level))
            .accessibilityHidden(true)
    }
}

extension CalmScore {
    /// "Chill, 69 out of 100".
    var spoken: String { "\(level.title), \(value) out of 100" }
}

/// The calm rating where we explain a route: each route's word, score and bar. No number axis; the score is in text.
struct CalmBar: View {
    let comparison: RouteComparison

    private var fastest: CalmScore { comparison.fastestCalm }
    private var calmer: CalmScore? { comparison.calmerCalm }
    private var fastestName: String { calmer == nil ? "This route" : "Fastest" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let calmer { row("Calmer", calmer) }
            row(fastestName, fastest)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("calm-bar")
    }

    private var spoken: String {
        let scores = [spokenScore(fastestName, fastest), calmer.map { spokenScore("Calmer", $0) }].compactMap { $0 }.joined(separator: ". ")
        return "Calm estimate, from Breezy to Yikes. \(scores)."
    }
    private func spokenScore(_ name: String, _ score: CalmScore) -> String { "\(name): \(score.spoken)" }

    private func row(_ name: String, _ score: CalmScore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(name): \(Text(score.level.title).fontWeight(.semibold).foregroundStyle(Color.calmWord(score.level)))")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(score.value) of 100").monospacedDigit()
            }
            .font(.subheadline)
            CalmMeter(score: score)
        }
    }
}
