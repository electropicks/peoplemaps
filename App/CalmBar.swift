import SwiftUI
import PeoplemapsCore

/// The calm rating where we explain a route: bands from Breezy to Yikes, with a marker for each route and the scores in
/// text. No number axis, since the score falls left to right. Words, markers and scores carry it; colour only adds to them.
struct CalmBar: View {
    let comparison: RouteComparison
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var bandHeight: CGFloat = 30
    @ScaledMetric(relativeTo: .caption) private var laneHeight: CGFloat = 30
    @ScaledMetric(relativeTo: .caption) private var labelHalfWidth: CGFloat = 26

    private var fastest: CalmScore { comparison.fastestCalm }
    private var calmer: CalmScore? { comparison.calmerCalm }
    private var fastestName: String { calmer == nil ? "This route" : "Fastest" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if typeSize.isAccessibilitySize { stacked } else { bar }
            VStack(alignment: .leading, spacing: 2) {
                scoreLine(fastestName, fastest)
                if let calmer { scoreLine("Calmer", calmer).foregroundStyle(.calmerText) }
            }
            .font(.subheadline.monospacedDigit())
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
    private func spokenScore(_ name: String, _ score: CalmScore) -> String { "\(name): \(score.level.title), \(score.value) out of 100" }

    private func scoreLine(_ name: String, _ score: CalmScore) -> some View {
        Text("\(Text(name).fontWeight(.semibold)): \(score.level.title), \(score.value) of 100")
            .fixedSize(horizontal: false, vertical: true)
    }

    private func landed(_ level: CalmLevel) -> Bool { fastest.level == level || calmer?.level == level }

    /// The fastest marker sits above the bands and the calmer one below, so they never collide.
    private var bar: some View {
        VStack(spacing: 2) {
            lane(fastestName, fastest, color: .primary, above: true)
            HStack(spacing: 2) {
                ForEach(CalmLevel.allCases) { level in
                    Text(level.title)
                        .font(.caption.weight(landed(level) ? .bold : .regular))
                        .foregroundStyle(landed(level) ? Color.calmBandText : Color.primary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: bandHeight)
                        .background(Color.calmBand(level).opacity(landed(level) ? 1 : 0.28), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if let calmer { lane("Calmer", calmer, color: .calmerText, above: false) }
        }
    }

    private func lane(_ name: String, _ score: CalmScore, color: Color, above: Bool) -> some View {
        GeometryReader { geo in
            let x = geo.size.width * score.barPosition
            let labelX = min(max(x, labelHalfWidth), geo.size.width - labelHalfWidth)
            Image(systemName: above ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill").font(.system(size: 9))
                .foregroundStyle(color)
                .position(x: min(max(x, 5), geo.size.width - 5), y: above ? geo.size.height - 5 : 5)
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(color).fixedSize()
                .position(x: labelX, y: above ? (geo.size.height - 10) / 2 : geo.size.height - (geo.size.height - 10) / 2)
        }
        .frame(height: laneHeight)
    }

    /// At accessibility sizes the words don't fit side by side: one row per level, each saying which route landed there.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(CalmLevel.allCases) { level in
                let here = [fastest.level == level ? fastestName : nil, calmer?.level == level ? "Calmer" : nil].compactMap { $0 }.joined(separator: ", ")
                VStack(alignment: .leading, spacing: 0) {
                    Text(level.title).font(.body.weight(landed(level) ? .bold : .regular))
                    if !here.isEmpty { Text(here).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true) }
                }
                .foregroundStyle(landed(level) ? Color.calmBandText : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.calmBand(level).opacity(landed(level) ? 1 : 0.28), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
