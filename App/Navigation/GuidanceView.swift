import SwiftUI
import PeoplemapsCore

/// `floatingSurface` plus a hairline when Reduce Transparency makes it opaque, so a panel stays distinct from a dark map.
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.floatingSurface(in: shape)
            .overlay { if (reduceTransparency || GlassFlags.reduceTransparency) && contrast != .increased { shape.stroke(Color(uiColor: .separator), lineWidth: 1) } }
    }
}

private extension View {
    func glassSurface<S: Shape>(in shape: S) -> some View { modifier(GlassSurface(shape: shape)) }
}

/// Guidance chrome on Liquid Glass (`Docs/DESIGN.md` 4.7, 4.8): turn banner with a "Then:" row, calm-note chip,
/// trip bar, rerouting state and arrival card. Portrait floats glass at the top and bottom; landscape uses one
/// leading glass card. Text that must be read sits straight on glass only when short; notes sit on `panelFill`.
struct GuidanceOverlay: View {
    let navigator: NavigationController
    let landscape: Bool
    /// Landscape card width; the card is also capped at 40% of the screen width.
    let cardWidth: CGFloat
    let attribution: AnyView
    @Binding var camera: GuidanceCamera
    @Binding var muted: Bool
    /// Space the chrome covers, in screen points, so the map can centre the puck in what is left.
    let onInsets: (UIEdgeInsets) -> Void
    let onEnd: () -> Void
    let onDone: () -> Void

    private let reports = ReportCenter.shared
    @State private var topEdge: CGFloat = 0
    @State private var bottomEdge: CGFloat = .infinity
    @State private var leadingEdge: CGFloat = 0
    @State private var screen: CGSize = .zero
    @ScaledMetric(relativeTo: .largeTitle) private var scaledArrow = 52.0
    /// Capped with the rest of the chrome (the environment cap below doesn't reach this view's own metrics).
    private var arrowSize: CGFloat { min(scaledArrow, 80) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var glassNS
    /// Heading the map was turned to when a free look began; the map stays there, so the compass does too.
    @State private var frozenHeading: Double?
    /// The compass angle on screen, unwrapped so it always turns the short way round.
    @State private var shownAngle = 0.0
    /// Cards slide in from their edges once the overlay is on screen.
    @State private var shown = false

    var body: some View {
        Group {
            if landscape { landscapeBody } else { portraitBody }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0; report() }
        .onChange(of: topEdge) { report() }
        .onChange(of: bottomEdge) { report() }
        .onChange(of: leadingEdge) { report() }
        .onChange(of: landscape) { report() }
        .animation(Motion.content(reduceMotion), value: navigator.isRerouting)
        .animation(Motion.content(reduceMotion), value: navigator.calmNote)
        .animation(Motion.panel(reduceMotion), value: navigator.hasArrived)
        .animation(Motion.content(reduceMotion), value: camera)
        .animation(Motion.content(reduceMotion), value: shownAngle)
        .onChange(of: camera.mode) { _, mode in frozenHeading = mode == .free ? navigator.heading : nil }
        .onChange(of: compassTarget) { _, target in
            var delta = (target - shownAngle).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
            shownAngle += delta
        }
        .onAppear { shownAngle = compassTarget; withAnimation(Motion.panel(reduceMotion)) { shown = true } }
        .sensoryFeedback(.success, trigger: navigator.hasArrived) { _, arrived in arrived }
        // Banner and trip bar stacked are taller than the screen past this size, so the chrome stops growing here.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// Where the compass should point: against the map's heading while the map is turned, upright otherwise. A free look
    /// that began heading-up keeps the heading the map was left at.
    private var compassTarget: Double {
        guard camera.isTurned else { return 0 }
        return -((camera.mode == .free ? frozenHeading : nil) ?? navigator.heading ?? 0)
    }

    private func report() {
        guard screen.height > 0 else { return }
        if landscape {
            onInsets(UIEdgeInsets(top: 0, left: leadingEdge + 12, bottom: 0, right: 72))
        } else {
            let bottom = bottomEdge.isFinite ? max(0, screen.height - bottomEdge) : 0
            onInsets(UIEdgeInsets(top: topEdge + 8, left: 0, bottom: bottom + 8, right: 0))
        }
    }

    // MARK: Portrait

    private var portraitBody: some View {
        VStack(spacing: 8) {
            if !navigator.hasArrived {
                GlassEffectContainer(spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        if shown {
                            ZStack(alignment: .top) {
                                if navigator.isRerouting { reroutingCard.transition(.opacity) } else { turnCard.transition(.opacity) }
                            }
                            .transition(Motion.edge(.top, reduce: reduceMotion))
                        }
                        HStack(alignment: .top) {
                            if !navigator.isRerouting, let note = navigator.calmNote {
                                chip(note).id(note).glassEffectID("calm-note", in: glassNS).transition(.opacity)
                            }
                            Spacer(minLength: 0)
                            mapButtons
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 4)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topEdge = $0 }
                .transition(.opacity)
            } else {
                HStack { Spacer(); mapButtons }.padding(.horizontal, 16).padding(.top, 8)
                    .onAppear { topEdge = 52 }
            }
            Spacer(minLength: 0)
            if camera.mode == .free, !navigator.hasArrived { recenterPill.padding(.bottom, 8).transition(.opacity.combined(with: .scale(scale: 0.9))) }
            HStack { attribution; Spacer() }.padding(.horizontal, 12)
            ZStack(alignment: .bottom) {
                if navigator.hasArrived { arrivalSheet.transition(Motion.edge(.bottom, reduce: reduceMotion)) }
                else if shown { tripBar.transition(Motion.edge(.bottom, reduce: reduceMotion)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Landscape

    private var landscapeBody: some View {
        GeometryReader { geo in
            let width = min(cardWidth, geo.size.width * 0.4)
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        ZStack(alignment: .top) {
                            if navigator.hasArrived {
                                arrivalContent.padding(16).transition(.opacity)
                            } else {
                                VStack(alignment: .leading, spacing: 0) {
                                    ZStack(alignment: .top) {
                                        if navigator.isRerouting { reroutingContent.transition(.opacity) } else { turnContent.transition(.opacity) }
                                    }
                                    if !navigator.isRerouting, let note = navigator.calmNote { chip(note, onGlass: true).id(note).padding(.horizontal, 16).padding(.top, 10).transition(.opacity) }
                                    tripContent.padding(16)
                                }
                                .transition(.opacity)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: width)
                    .frame(maxHeight: geo.size.height + geo.safeAreaInsets.bottom - 24)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .padding(.vertical, 12).padding(.leading, 12)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { leadingEdge = $0 }
                    .offset(x: shown || reduceMotion ? 0 : -(width + 24)).opacity(shown ? 1 : 0)
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing) {
                        mapButtons
                        if camera.mode == .free, !navigator.hasArrived { recenterPill.padding(.top, 8).transition(.opacity.combined(with: .scale(scale: 0.9))) }
                        Spacer()
                        attribution
                    }.padding(.vertical, 12).padding(.trailing, 16)
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
    }

    // MARK: Turn card

    private var turnCard: some View {
        turnContent.glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var turnContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: Self.symbol(navigator.currentStep?.maneuver ?? .depart))
                    .font(.system(size: arrowSize * 0.75, weight: .bold)).foregroundStyle(.calmerText)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .frame(width: arrowSize, height: arrowSize).accessibilityHidden(!Self.exposesArrow)
                    .accessibilityLabel("Arrow").accessibilityValue(Self.symbol(navigator.currentStep?.maneuver ?? .depart))
                    .accessibilityIdentifier("guidance-arrow")
                VStack(alignment: .leading, spacing: 2) {
                    Text(NavigationFormat.distance(navigator.distanceToManeuver)).font(.largeTitle.bold()).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .contentTransition(.numericText(value: -navigator.distanceToManeuver))
                        .accessibilityIdentifier("guidance-distance")
                    Text(navigator.instruction).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("guidance-instruction")
                }
                .animation(Motion.content(reduceMotion), value: navigator.instruction)
                .animation(Motion.content(reduceMotion), value: NavigationFormat.distance(navigator.distanceToManeuver))
                Spacer(minLength: 0)
            }
            .padding(.leading, 16).padding(.trailing, 18).padding(.vertical, 14)
            if navigator.thenStep != nil {
                Divider().padding(.horizontal, 16)
                HStack(spacing: 8) {
                    Text("Then:")
                    if let then = navigator.thenStep { Image(systemName: Self.symbol(then.maneuver)).font(.subheadline.weight(.bold)).accessibilityHidden(true) }
                    Text(navigator.thenText).fontWeight(.semibold).lineLimit(typeSize.isAccessibilitySize ? 4 : 2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.subheadline).foregroundStyle(Self.onGlass)
                .padding(.horizontal, 18).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .accessibilityElement(children: .combine).accessibilityIdentifier("guidance-then")
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("guidance-card")
    }

    /// A glass capsule, or with `onGlass` (inside the landscape card) a `panelFill` capsule, since glass doesn't go on glass.
    @ViewBuilder private func chip(_ text: String, onGlass: Bool = false) -> some View {
        let label = HStack(spacing: 7) {
            Image(systemName: Self.chipSymbol(text)).font(.footnote.weight(.semibold)).accessibilityHidden(true)
            Text(text).font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.calmerText)
        .padding(.horizontal, 12).frame(minHeight: 34)
        if onGlass {
            label.background(.panelFill, in: Capsule()).accessibilityElement(children: .combine).accessibilityIdentifier("guidance-calm-note")
        } else {
            label.glassSurface(in: Capsule()).accessibilityElement(children: .combine).accessibilityIdentifier("guidance-calm-note")
        }
    }

    private static func chipSymbol(_ text: String) -> String {
        text.localizedCaseInsensitiveContains("stop") ? "octagon" : "light.beacon.max"
    }

    // MARK: Rerouting

    private var reroutingCard: some View {
        reroutingContent.glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var reroutingContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.calmerText).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finding a calmer way…").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("You left the planned route").font(.subheadline).foregroundStyle(Self.onGlass)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16).padding(.trailing, 18).padding(.vertical, 14)
            Divider().padding(.horizontal, 16)
            Text("Works offline. No signal needed.").font(.subheadline).foregroundStyle(Self.onGlass)
                .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("guidance-rerouting")
    }

    // MARK: Trip bar

    private var tripBar: some View {
        tripContent
            .padding(16)
            .glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 8).padding(.bottom, 4)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { bottomEdge = $0 }
    }

    /// Arrival time, minutes and distance left, End, and the estimate caveat.
    private var tripContent: some View {
        let waiting = navigator.isRerouting
        return VStack(alignment: .leading, spacing: 8) {
            if landscape {
                stats(waiting)
                Text(estimateNote(waiting)).font(.caption).foregroundStyle(Self.onGlass).padding(.top, 6)
                endButton(fullWidth: true)
            } else if typeSize.isAccessibilitySize {
                stats(waiting)
                endButton(fullWidth: true)
                Text(estimateNote(waiting)).font(.caption).foregroundStyle(Self.onGlass)
            } else {
                HStack(spacing: 12) { stats(waiting); endButton(fullWidth: false) }
                Text(estimateNote(waiting)).font(.caption).foregroundStyle(Self.onGlass)
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("trip-bar")
    }

    private func estimateNote(_ waiting: Bool) -> String {
        if waiting { return "Estimate returns once a new route is found" }
        switch navigator.mode {
        case .drive: return "Estimate, no live traffic"
        case .bike: return "Cycling estimate at an easy pace"
        case .walk: return "Walking estimate at an easy pace"
        }
    }

    private func stats(_ waiting: Bool) -> some View {
        let arrival = Date().addingTimeInterval(navigator.remainingSeconds)
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            stat(waiting ? "–" : arrival.formatted(date: .omitted, time: .shortened), "arrival", id: "trip-arrival", waiting: waiting)
            stat(waiting ? "–" : "\(NavigationFormat.minutes(navigator.remainingSeconds)) min", "left", id: "trip-minutes", waiting: waiting)
            stat(waiting ? "–" : NavigationFormat.distance(navigator.remainingMeters), "left", id: "trip-distance", waiting: waiting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ label: String, id: String, waiting: Bool) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 1))
        return layout {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(waiting ? Self.onGlass : Color.primary).accessibilityIdentifier(id)
                .contentTransition(.numericText()).animation(Motion.content(reduceMotion), value: value)
            Text(label).font(.footnote).foregroundStyle(Self.onGlass)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func endButton(fullWidth: Bool) -> some View {
        Button(role: .destructive, action: onEnd) {
            Text("End").font(.body.weight(.semibold)).foregroundStyle(Self.endRed).padding(.horizontal, 8)
                .frame(minWidth: 48, maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.red)
        .accessibilityIdentifier("end-navigation")
    }

    // MARK: Map buttons

    /// Mute, compass and overview in one glass capsule (vertical in landscape), 44 pt plain buttons with dividers.
    private var mapButtons: some View {
        let layout = landscape ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            muteButton
            mapDivider
            compassButton
            mapDivider
            overviewButton
            mapDivider
            markButton
        }
        .glassSurface(in: Capsule())
    }

    private var mapDivider: some View {
        Divider().frame(width: landscape ? 24 : nil, height: landscape ? nil : 24)
    }

    private func mapButton(_ action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) { label().font(.system(size: 19)).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.primary)
    }

    private var muteButton: some View {
        mapButton({ withAnimation(Motion.content(reduceMotion)) { muted.toggle() } }) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(muted ? "Unmute voice" : "Mute voice").accessibilityIdentifier("guidance-mute")
    }

    /// A compass that points north on screen, so it reads upright when the map is north-up and turns with it heading-up.
    /// In the overview the tap only leaves the overview; it doesn't also flip the orientation.
    private var compassButton: some View {
        mapButton({
            withAnimation(Motion.content(reduceMotion)) {
                if camera.mode == .overview { camera.toggleOverview() } else { camera.toggleHeading() }
            }
        }) {
            Image(systemName: "location.north.line.fill").rotationEffect(.degrees(shownAngle))
        }
        .accessibilityLabel(camera.courseUp ? "Heading up" : "North up")
        .accessibilityHint(camera.mode == .overview ? "Leaves the route overview" : camera.courseUp ? "Turns the map north up" : "Turns the map to face your heading")
        .accessibilityIdentifier("guidance-compass")
    }

    private var overviewButton: some View {
        let overview = camera.mode == .overview
        return mapButton({ withAnimation(Motion.content(reduceMotion)) { camera.toggleOverview() } }) {
            Image(systemName: overview ? "location.fill" : "arrow.up.left.and.arrow.down.right").contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(overview ? "Follow my position" : "Route overview").accessibilityIdentifier("guidance-overview")
    }

    /// One tap saves the moment on this phone, with a light confirmation and no sheet; the user describes it after the trip.
    private var markButton: some View {
        let marked = reports.justMarked
        return Button { reports.mark(navigator) } label: {
            Group {
                if marked { Label("Marked", systemImage: "checkmark").font(.body.weight(.semibold)).padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44) }
                else { Image(systemName: "flag").font(.system(size: 19)).frame(width: 44, height: 44) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(marked ? Color.calmerText : .primary)
        .animation(Motion.content(reduceMotion), value: marked)
        .accessibilityLabel(marked ? "Marked" : "Mark this moment").accessibilityHint("Saves where you are on this phone, to report later")
        .accessibilityIdentifier("mark-moment")
    }

    /// Shown after the user pans or pinches; returns to the follow mode they left, as Apple Maps does.
    private var recenterPill: some View {
        Button { withAnimation(Motion.content(reduceMotion)) { camera.recenter() } } label: {
            Label("Re-centre", systemImage: "location").font(.body.weight(.semibold)).padding(.horizontal, 6)
        }
        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large).foregroundStyle(.primary)
        .accessibilityLabel("Re-centre").accessibilityHint("Follows your position again").accessibilityIdentifier("guidance-recenter")
    }

    // MARK: Arrival

    private var arrivalSheet: some View {
        arrivalContent
            .padding(16)
            .glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 8).padding(.bottom, 4)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { bottomEdge = $0 }
    }

    private var arrivalContent: some View {
        let name = navigator.destination?.shortName ?? "your destination"
        let minutes = NavigationFormat.minutes(navigator.tripSeconds)
        let summary = "\(NavigationFormat.distance(navigator.tripMeters)) · \(minutes) min · \(navigator.calmerRoute ? "Calmer route" : "Fastest route")"
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(.directionsFill, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You've arrived at \(name)").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("guidance-arrived")
                    Text(summary).font(.subheadline).foregroundStyle(Self.onGlass).accessibilityIdentifier("arrival-summary")
                }
                Spacer(minLength: 0)
            }
            if !navigator.tripNotes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(navigator.tripNotes.enumerated()), id: \.offset) { index, note in
                        if index > 0 { Divider().padding(.leading, 48) }
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(.calmerText).frame(width: 22).accessibilityHidden(true)
                            Text(note).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 14).padding(.vertical, 12).frame(minHeight: 52)
                    }
                }
                .background(.panelFill, in: RoundedRectangle(cornerRadius: Layout.groupRadius, style: .continuous))
                .accessibilityElement(children: .contain).accessibilityIdentifier("arrival-notes")
            }
            Button(action: onDone) {
                Text("Done").font(.body.weight(.semibold)).foregroundStyle(.directionsText).frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(.directionsFill).controlSize(.large)
            .accessibilityIdentifier("done-navigation")
            let marks = reports.marked(in: navigator.tripID)
            if let last = marks.last {
                Button { reports.open(editing: last) } label: {
                    Text(marks.count == 1 ? "Add words to your marked moment" : "Add words to your \(marks.count) marked moments").font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("add-words")
            }
            Text("Times are estimates. No live traffic.").font(.footnote).foregroundStyle(Self.onGlass).padding(.horizontal, 4)
            VoiceUpgradeTip()
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("arrival-card")
    }

    #if DEBUG
    /// UI tests read the arrow the card really draws; release builds keep it out of VoiceOver, which reads the instruction.
    static let exposesArrow = true
    #else
    static let exposesArrow = false
    #endif

    /// Secondary text on glass: `.secondary` measures under 4.5:1 on it.
    static let onGlass = Color.primary.opacity(0.75)
    /// Red label for End: a darker red in light, a lighter one in dark, so it clears 4.5:1 on its tinted capsule over glass.
    static let endRed = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.5, blue: 0.47, alpha: 1) : UIColor(red: 0.69, green: 0.07, blue: 0.09, alpha: 1) })

    static func symbol(_ maneuver: Maneuver) -> String { maneuver.symbolName }
}
