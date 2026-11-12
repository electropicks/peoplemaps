import SwiftUI
import PeoplemapsCore

/// The calmer route beside the fastest. Scrolls at any text size, with Why this route, the modes and Start pinned under it, so none is
/// ever clipped. All of it sits straight on the panel's glass, separated by hairlines.
struct RoutePreview: View {
    @Bindable var model: ExploreModel
    /// Start: guidance on the chosen route.
    let onStart: (RouteComparison) -> Void
    @Environment(\.landscapeCard) private var landscape
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The calm word is `.largeTitle`, held to 48 pt so at accessibility sizes the time under it stays in view.
    @ScaledMetric(relativeTo: .largeTitle) private var scaledWord = 34.0
    /// One line of the preview header's destination and start, to size their tap targets around.
    @ScaledMetric(relativeTo: .subheadline) private var destinationLine = 20.0
    @ScaledMetric(relativeTo: .footnote) private var originLine = 18.0

    private var session: RouteSession { model.session }
    private var request: RouteRequest? { model.request }

    var body: some View {
        VStack(spacing: 0) {
            SheetScroll { previewBody.dynamicTypeSize(...DynamicTypeSize.accessibility2) }
            actions
        }
    }

    private var previewBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    if request == nil { needsPlace } else { stateContent }
                }.id(request == nil ? "needs-place" : stateID).transition(.opacity)
            }
            .animation(Motion.content(reduceMotion), value: request == nil ? "needs-place" : stateID)
            if landscape || model.stop == .raised || model.stop == .large || typeSize.isAccessibilitySize {
                Hairline()
                swapRow
                Hairline()
                extraTime.sensoryFeedback(.selection, trigger: model.budget)
            }
        }
    }

    /// Where to, how far, and from where; the two places open their pickers. Times stay estimates, so that's said here too.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                let line = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                line {
                    placeButton(place: model.destination, target: .destination).padding(.top, -headerReach.up)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if let chosenRoute = model.chosenRoute { Text(chosenRoute.distance).font(.subheadline.weight(.medium)).monospacedDigit().accessibilityIdentifier("preview-distance") }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        placeButton(place: model.origin, target: .origin).fixedSize().padding(.bottom, -headerReach.down)
                        Spacer(minLength: 0)
                        estimateCaveat.lineLimit(1).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        // Stacked, the start's target reaches down behind the caveat, so the two lines stay together.
                        placeButton(place: model.origin, target: .origin).fixedSize(horizontal: false, vertical: true).padding(.bottom, -headerReach.stacked)
                        estimateCaveat.fixedSize(horizontal: false, vertical: true).allowsHitTesting(false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CloseButton(label: "Close routes", id: "close-preview") { model.show(.home) }
                .padding(.top, -7).padding(.trailing, -7)
        }
    }

    /// The two lines stay close while each has a full-size target: the destination's reaches up into the margin above the header, the
    /// start's down into the gap before the rating. How far each reaches past its own line, held to the room there is. At
    /// accessibility sizes the lines wrap and are tall enough.
    private var headerReach: (up: CGFloat, down: CGFloat, stacked: CGFloat) {
        guard !typeSize.isAccessibilitySize else { return (0, 0, 0) }
        // The landscape card has no height to spare: there the destination's target runs past the card's top inset and is cut off at
        // its edge, so the fastest row and its meter stay in view.
        let above = landscape ? CGFloat.infinity : Layout.sheetTop, below = max(Layout.target - Self.headerGap - originLine, 0)
        return (min(above, max(Layout.target - Self.headerGap - destinationLine, 0)), min(10, below), below)
    }
    /// From each header line to the edge of its target that faces the other line.
    private static let headerGap: CGFloat = 3

    private var estimateCaveat: some View {
        Text("Estimate, no live traffic").font(.footnote).foregroundStyle(GuidanceOverlay.onGlass)
    }

    private func placeButton(place: Place?, target: Sheet) -> some View {
        let origin = target == .origin
        let empty = origin ? "Choose start" : "Choose destination"
        let shown = place.map { origin ? "From \($0.shortName)" : $0.shortName } ?? empty
        return Button { model.sheet = target } label: {
            Text(shown)
                .font(origin && place != nil ? .footnote : .subheadline.weight(place == nil ? .semibold : .medium))
                .foregroundStyle(origin && place != nil ? GuidanceOverlay.onGlass : .primary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .padding(origin ? .top : .bottom, Self.headerGap)
                .frame(minWidth: Layout.target, minHeight: Layout.target, alignment: origin ? .topLeading : .bottomLeading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(place.map { "\(origin ? "Starting from" : "Going to"), \($0.shortName)" } ?? empty)
            .accessibilityAddTraits(origin ? [] : .isHeader)
            .accessibilityIdentifier("choose-\(target.rawValue)")
    }

    private var swapRow: some View {
        Button {
            withAnimation(Motion.content(reduceMotion)) { let previous = model.origin; model.origin = model.destination; model.destination = previous }
        } label: {
            Label("Swap start and destination", systemImage: "arrow.up.arrow.down").font(.subheadline).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("swap")
    }

    private func extraLabel(_ minutes: Int) -> String { minutes == 0 ? "None" : "\(minutes) min" }

    private var extraTime: some View {
        let title = "Most extra time for a calmer route"
        return Menu {
            Picker("Extra time", selection: $model.budget) {
                ForEach([10, 5, 2, 0], id: \.self) { Text(extraLabel($0)).tag($0) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(.primary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(extraLabel(model.budget)).foregroundStyle(GuidanceOverlay.onGlass).monospacedDigit()
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass)
            }
            .font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(title).accessibilityValue(extraLabel(model.budget)).accessibilityIdentifier("extra-time-menu")
    }

    /// Identity of the comparison state, so loading, results and errors crossfade.
    private var stateID: String {
        switch session.state {
        case .idle, .loading: "loading"
        case .cancelled: "cancelled"
        case let .failed(message): "failed-\(message)"
        case let .ready(comparison): "ready-\(comparison.fastest.id)-\(comparison.calmer?.id ?? "none")"
        }
    }

    /// Every state of the preview takes about the same room, so the panel doesn't jump when routes arrive.
    private var stateHeight: CGFloat { landscape ? 90 : 150 }

    /// No start (location off or unavailable), a start outside the area we cover, or no destination yet: say what to do, and show no route.
    private var needsPlace: some View {
        let outside = model.origin.map { !model.graph.coverage.contains($0.coordinate) } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            Text(outside ? "Your start is outside the area we cover" : model.origin == nil ? "Choose a start to compare routes." : "Choose a destination to compare routes.")
                .font(outside ? .headline : .subheadline).foregroundStyle(outside ? .primary : GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
            if outside {
                Text(RegionSelection.usesCounty ? "\(RegionSelection.coverageSentence) Choose a start inside it." : "PeopleMaps can route only inside its offline Seattle area for now. Choose a start inside it.")
                    .font(.footnote).foregroundStyle(GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
                Button("Choose start") { model.sheet = .origin }.font(.subheadline.weight(.semibold)).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: stateHeight, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(outside ? "start-outside-coverage" : "needs-place")
    }

    @ViewBuilder private var stateContent: some View {
        switch session.state {
        case .idle, .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("Comparing \(RegionSelection.areaName) streets…").font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { session.cancel() }.font(.subheadline.weight(.semibold)).accessibilityIdentifier("cancel-route")
            }.frame(minHeight: stateHeight, alignment: .top)
        case .cancelled:
            status(title: "Comparison paused", message: "Your places are still here.", button: "Compare routes")
        case let .failed(message):
            status(title: "Try another route", message: message, button: "Try again")
        case let .ready(comparison):
            let calmerChosen = model.selectedCalmer
            if let calmer = comparison.calmer, let score = comparison.calmerCalm {
                routeButton(calmer, title: "Calmer", score: score, spoken: "\(comparison.extraTimeLabel), \(comparison.spokenCalmSummary)", selected: calmerChosen, calmer: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        rating(score, route: calmer, chosen: calmerChosen)
                        Text(comparison.reasonLine).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Hairline()
                routeButton(comparison.fastest, title: "Fastest", score: comparison.fastestCalm, spoken: "Estimate, no live traffic", selected: !calmerChosen, calmer: false, reach: 8) {
                    fastestRow(comparison, selected: !calmerChosen)
                }
            } else {
                routeButton(comparison.fastest, title: "Fastest", score: comparison.fastestCalm, spoken: "Estimate, no live traffic", selected: true, calmer: false) {
                    rating(comparison.fastestCalm, route: comparison.fastest)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(comparison.noCalmer.title).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text(comparison.noCalmer.detail).font(.footnote).foregroundStyle(GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("no-alternative")
            }
            if let note = comparison.tollNote(calmer: calmerChosen && comparison.calmer != nil) {
                // The route Start takes, said before Start: the details sheet is a tap away.
                Text(note).font(.footnote).foregroundStyle(GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("toll-note")
            }
        }
    }

    /// The big word and time over the rating bar. `chosen` adds the mark that pairs it with the fastest row; nil when it is the only route.
    private func rating(_ score: CalmScore, route: Route, chosen: Bool? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let line = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            line {
                Text(score.level.title).font(.system(size: min(scaledWord, 48), weight: .semibold)).tracking(-0.5).foregroundStyle(Color.calmWord(score.level))
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(route.timeRange).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
                    if let chosen { ChoiceMark(chosen: chosen) }
                }
            }
            CalmMeter(score: score)
        }
    }

    /// The fastest route under the calmer one, smaller, with its own bar.
    private func fastestRow(_ comparison: RouteComparison, selected: Bool) -> some View {
        let score = comparison.fastestCalm
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Fastest: \(Text(score.level.title).fontWeight(.semibold).foregroundStyle(Color.calmWord(score.level)))")
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(comparison.fastest.timeRange).monospacedDigit()
                ChoiceMark(chosen: selected)
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            CalmMeter(score: score, height: 6)
        }
    }

    /// Picks which route the map shows and Start takes. VoiceOver hears the route, its time and distance, then the rating in words and score.
    /// `reach` grows a short row's target into the gaps above and below it without moving anything.
    private func routeButton<Label: View>(_ route: Route, title: String, score: CalmScore, spoken: String, selected: Bool, calmer: Bool, reach: CGFloat = 0,
                                          @ViewBuilder label: () -> Label) -> some View {
        Button { withAnimation(Motion.content(reduceMotion)) { model.selectedCalmer = calmer } } label: {
            label().padding(.vertical, reach).frame(minHeight: Layout.target).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.vertical, -reach)
            .accessibilityLabel("\(title) route, \(route.spokenTimeRange), \(DistanceFormat.distance(route.metrics.meters, spoken: true)). \(spoken)")
            .accessibilityValue(score.spoken)
            .accessibilityIdentifier(calmer ? "route-calmer" : "route-fastest")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func status(title: String, message: String, button: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(message).font(.footnote).foregroundStyle(GuidanceOverlay.onGlass).fixedSize(horizontal: false, vertical: true)
            Button(button) { if let request { session.start(request) } }.font(.subheadline.weight(.semibold)).padding(.top, 2)
                .accessibilityIdentifier("retry-route")
        }.frame(maxWidth: .infinity, minHeight: stateHeight, alignment: .topLeading)
    }

    // MARK: Pinned under the preview

    /// Why this route and Calmer means, then the modes beside Start.
    private var actions: some View {
        let comparison = request != nil ? session.comparison : nil
        // The landscape card has no height to spare, so the modes and Start stay side by side at a capped size.
        let stacked = typeSize.isAccessibilitySize && !landscape
        let line = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        let custom = !model.preferences[model.mode].isDefault(in: model.mode)
        return VStack(spacing: 6) {
            Hairline()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    whyButton(comparison)
                    Spacer(minLength: 8)
                    RoutePreferencesRow(isCustom: custom) { model.sheet = .preferences }
                }
                VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 6 : 0) {
                    whyButton(comparison)
                    RoutePreferencesRow(isCustom: custom) { model.sheet = .preferences }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            line {
                modePicker(fullWidth: stacked)
                if let comparison {
                    Button { onStart(comparison) } label: {
                        Text(model.selectedCalmer || comparison.calmer == nil ? "Start" : "Start fastest").font(.body.weight(.semibold)).foregroundStyle(.primaryActionText)
                            .frame(maxWidth: .infinity, minHeight: landscape ? 28 : 34)
                    }
                    .primaryAction()
                    .accessibilityIdentifier("start-navigation")
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .dynamicTypeSize(...(landscape ? DynamicTypeSize.xxLarge : .accessibility2))
        .padding(.horizontal, Layout.inset(landscape: landscape)).padding(.bottom, landscape ? Layout.cardInset : 8)
    }

    @ViewBuilder private func whyButton(_ comparison: RouteComparison?) -> some View {
        if let comparison {
            Button { model.sheet = .details } label: { Text("Why this route").multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true) }
            .wellButton()
            .accessibilityHint(comparison.spokenCalmSummary)
            .accessibilityIdentifier("route-details")
        }
    }

    /// Icon-only: each says its name to VoiceOver, and in the large content viewer at the largest text sizes.
    private func modePicker(fullWidth: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(TravelMode.displayOrder) { choice in
                Button { model.mode = choice } label: {
                    Image(systemName: choice.symbol).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        .frame(maxWidth: fullWidth ? .infinity : nil).frame(width: fullWidth ? nil : 46, height: landscape ? 38 : 46)
                        .background { if model.mode == choice { Capsule().fill(.glassChosen) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityShowsLargeContentViewer { Label(choice.title, systemImage: choice.symbol) }
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(model.mode == choice ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.glassWell, in: Capsule())
        .sensoryFeedback(.selection, trigger: model.mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Travel mode")
    }
}
