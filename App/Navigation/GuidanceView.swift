import SwiftUI
import PeoplemapsCore

/// Guidance chrome, per the "navigation" rows of the design canvas: turn card with a "Then:" row, calm-note chip,
/// trip bar, rerouting state and arrival summary. Portrait floats cards at the top and bottom; landscape uses one
/// leading card like the rest of the app.
struct GuidanceOverlay: View {
    let navigator: NavigationController
    let landscape: Bool
    let cardWidth: CGFloat
    let attribution: AnyView
    @Binding var overview: Bool
    /// Space the chrome covers, in screen points, so the map can centre the puck in what is left.
    let onInsets: (UIEdgeInsets) -> Void
    let onEnd: () -> Void
    let onDone: () -> Void

    @State private var topEdge: CGFloat = 0
    @State private var bottomEdge: CGFloat = .infinity
    @State private var leadingEdge: CGFloat = 0
    @State private var screen: CGSize = .zero
    @ScaledMetric(relativeTo: .largeTitle) private var arrowSize = 52.0

    var body: some View {
        Group {
            if landscape { landscapeBody } else { portraitBody }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0; report() }
        .onChange(of: topEdge) { report() }
        .onChange(of: bottomEdge) { report() }
        .onChange(of: leadingEdge) { report() }
        .onChange(of: landscape) { report() }
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
                VStack(alignment: .leading, spacing: 8) {
                    if navigator.isRerouting { reroutingCard } else { turnCard }
                    HStack(alignment: .top) {
                        if !navigator.isRerouting, let note = navigator.calmNote { chip(note) }
                        Spacer(minLength: 0)
                        overviewButton
                    }
                }
                .padding(.horizontal, 8).padding(.top, 4)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topEdge = $0 }
            } else {
                HStack { Spacer(); overviewButton }.padding(.horizontal, 16).padding(.top, 8)
                    .onAppear { topEdge = 52 }
            }
            Spacer(minLength: 0)
            HStack { attribution; Spacer() }.padding(.horizontal, 12)
            if navigator.hasArrived { arrivalSheet } else { tripBar }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Landscape

    private var landscapeBody: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if navigator.hasArrived {
                            arrivalContent.padding(14)
                        } else {
                            if navigator.isRerouting { reroutingContent } else { turnContent }
                            if !navigator.isRerouting, let note = navigator.calmNote { chip(note).padding(.horizontal, 14).padding(.top, 10) }
                            tripContent.padding(14)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: cardWidth)
                .frame(maxHeight: geo.size.height + geo.safeAreaInsets.bottom - 24)
                .background(.panel, in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.14), radius: 16, y: 2)
                .padding(.vertical, 12).padding(.leading, 12)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { leadingEdge = $0 }
                Spacer(minLength: 16)
                VStack(alignment: .trailing) {
                    overviewButton
                    Spacer()
                    attribution
                }.padding(.vertical, 12).padding(.trailing, 16)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    // MARK: Turn card

    private var turnCard: some View {
        VStack(spacing: 0) { turnContent }
            .background(.panel, in: RoundedRectangle(cornerRadius: 20)).clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.14), radius: 16, y: 2)
    }

    private var turnContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: Self.symbol(navigator.currentStep?.maneuver ?? .depart))
                    .font(.system(size: arrowSize * 0.75, weight: .bold)).foregroundStyle(.calmerText)
                    .frame(width: arrowSize, height: arrowSize).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NavigationFormat.distance(navigator.distanceToManeuver)).font(.largeTitle.bold()).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .accessibilityIdentifier("guidance-distance")
                    Text(navigator.instruction).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("guidance-instruction")
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16).padding(.trailing, 18).padding(.vertical, 14)
            if navigator.thenStep != nil {
                HStack(spacing: 8) {
                    Text("Then:")
                    if let then = navigator.thenStep { Image(systemName: Self.symbol(then.maneuver)).font(.subheadline.weight(.bold)).accessibilityHidden(true) }
                    Text(navigator.thenText).fontWeight(.semibold).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(.panelFill)
                .accessibilityElement(children: .combine).accessibilityIdentifier("guidance-then")
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("guidance-card")
    }

    private func chip(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: Self.chipSymbol(text)).font(.footnote.weight(.semibold)).accessibilityHidden(true)
            Text(text).font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.calmerText)
        .padding(.horizontal, 12).frame(minHeight: 30)
        .background(.panel, in: Capsule()).shadow(color: .black.opacity(0.12), radius: 8, y: 1)
        .accessibilityElement(children: .combine).accessibilityIdentifier("guidance-calm-note")
    }

    private static func chipSymbol(_ text: String) -> String {
        text.localizedCaseInsensitiveContains("stop") ? "octagon" : "trafficlight"
    }

    // MARK: Rerouting

    private var reroutingCard: some View {
        VStack(spacing: 0) { reroutingContent }
            .background(.panel, in: RoundedRectangle(cornerRadius: 20)).clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.14), radius: 16, y: 2)
    }

    private var reroutingContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.calmerText)
                    .frame(width: 60, height: 60).background(.panelFill, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finding a calmer way…").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("You left the planned route").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16).padding(.trailing, 18).padding(.vertical, 14)
            Text("Works offline. No signal needed.").font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).background(.panelFill)
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("guidance-rerouting")
    }

    // MARK: Trip bar

    private var tripBar: some View {
        VStack(spacing: 0) { tripContent }
            .padding(14)
            .background(.panel, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.14), radius: 16, y: 2)
            .padding(.horizontal, 8).padding(.bottom, 4)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { bottomEdge = $0 }
    }

    /// Arrival time, minutes and distance left, End, and the estimate caveat.
    private var tripContent: some View {
        let waiting = navigator.isRerouting
        return VStack(alignment: .leading, spacing: 8) {
            if landscape {
                stats(waiting)
                Text(estimateNote(waiting)).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                endButton(fullWidth: true)
            } else {
                HStack(spacing: 12) { stats(waiting); endButton(fullWidth: false) }
                Text(estimateNote(waiting)).font(.caption).foregroundStyle(.secondary)
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
        return HStack(alignment: .top, spacing: 10) {
            stat(waiting ? "–" : arrival.formatted(date: .omitted, time: .shortened), "arrival", id: "trip-arrival", waiting: waiting)
            stat(waiting ? "–" : "\(NavigationFormat.minutes(navigator.remainingSeconds)) min", "left", id: "trip-minutes", waiting: waiting)
            stat(waiting ? "–" : NavigationFormat.distance(navigator.remainingMeters), "left", id: "trip-distance", waiting: waiting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ label: String, id: String, waiting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(waiting ? .secondary : .primary).accessibilityIdentifier(id)
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func endButton(fullWidth: Bool) -> some View {
        Button(action: onEnd) {
            Text("End").font(.body.weight(.semibold)).foregroundStyle(.primary)
                .padding(.horizontal, 20).frame(minWidth: 72, maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("end-navigation")
    }

    // MARK: Map button

    private var overviewButton: some View {
        Button { overview.toggle() } label: {
            Image(systemName: overview ? "location.fill" : "arrow.up.left.and.arrow.down.right").font(.system(size: 19))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 1)
        .accessibilityLabel(overview ? "Follow my position" : "Route overview").accessibilityIdentifier("guidance-overview")
    }

    // MARK: Arrival

    private var arrivalSheet: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color(uiColor: .systemGray3)).frame(width: 36, height: 5).accessibilityHidden(true)
            arrivalContent
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14).fill(.panel)
                .shadow(color: .black.opacity(0.08), radius: 12, y: -1).ignoresSafeArea(edges: .bottom)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { bottomEdge = $0 }
    }

    private var arrivalContent: some View {
        let name = navigator.destination?.shortName ?? "your destination"
        let minutes = NavigationFormat.minutes(navigator.tripSeconds)
        let summary = "\(NavigationFormat.distance(navigator.tripMeters)) · \(minutes) min · \(navigator.calmerRoute ? "Calmer route" : "Fastest route")"
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(Color(red: 0x1F / 255, green: 0x7A / 255, blue: 0x3A / 255), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You've arrived at \(name)").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("guidance-arrived")
                    Text(summary).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("arrival-summary")
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
                .background(.panelFill, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain).accessibilityIdentifier("arrival-notes")
            }
            Button(action: onDone) {
                Text("Done").font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 50)
                    .foregroundStyle(.directionsText).background(.directionsFill, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("done-navigation")
            Text("Times are estimates. No live traffic.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("arrival-card")
    }

    static func symbol(_ maneuver: Maneuver) -> String {
        switch maneuver {
        case .depart, .continueOnto: "arrow.up"
        case .cross: "figure.walk"
        case .arrive: "mappin.circle.fill"
        case let .turn(direction):
            switch direction {
            case .slightLeft: "arrow.up.left"
            case .left: "arrow.turn.up.left"
            case .sharpLeft: "arrow.turn.down.left"
            case .slightRight: "arrow.up.right"
            case .right: "arrow.turn.up.right"
            case .sharpRight: "arrow.turn.down.right"
            case .uTurn: "arrow.uturn.left"
            }
        }
    }
}
