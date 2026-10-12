import SwiftUI
import PeoplemapsCore

private enum Sheet: String, Identifiable { case origin, destination, details, about; var id: String { rawValue } }

struct ExploreView: View {
    let graph: StreetGraph
    @State private var session: RouteSession
    @State private var origin: Place
    @State private var destination: Place
    @State private var mode: TravelMode = .drive
    @State private var budget = 5
    @State private var selectedCalmer = true
    @State private var sheet: Sheet?
    @State private var recenter = 0

    init(graph: StreetGraph) {
        self.graph = graph
        let router = NativeRouter(graph: graph)
        #if DEBUG
        let computing: any RouteComputing = ProcessInfo.processInfo.arguments.contains("--ui-testing") ? SlowTestRouter(base: router) : router
        #else
        let computing: any RouteComputing = router
        #endif
        _session = State(initialValue: RouteSession(router: computing))
        _origin = State(initialValue: graph.places.first { $0.id == "node/693337509" } ?? graph.places[0])
        _destination = State(initialValue: graph.places.first { $0.id == "relation/1047789" } ?? graph.places[1])
    }

    private var request: RouteRequest { .init(origin: origin, destination: destination, mode: mode, extraMinutes: budget) }
    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottom) {
                SeattleMap(comparison: session.comparison, selectedCalmer: selectedCalmer, recenter: recenter)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Seattle offline map. Routes are also described below.")
                VStack {
                    HStack {
                        Label("SEATTLE · OFFLINE", systemImage: "leaf")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                            .padding(.horizontal, 12).padding(.vertical, 9).background(Palette.paper.opacity(0.94), in: Capsule())
                        Spacer()
                        Button { recenter += 1 } label: { Image(systemName: "viewfinder").font(.system(size: 18)).frame(width: 44, height: 44).background(Palette.paper, in: Circle()) }
                            .accessibilityLabel("Fit routes on map").accessibilityIdentifier("recenter")
                    }
                    Spacer()
                    HStack {
                        Link("© OpenStreetMap contributors · ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                            .font(.system(size: 10)).foregroundStyle(Palette.ink)
                            .padding(6).background(Palette.paper.opacity(0.95), in: RoundedRectangle(cornerRadius: 5))
                        Spacer()
                    }
                }.padding(12)
            }.frame(minHeight: 150)
            comparisonPanel
        }
        .background(Palette.paper).foregroundStyle(Palette.ink)
        .task(id: request) { selectedCalmer = true; session.start(request) }
        .onDisappear { session.cancel() }
        .sheet(item: $sheet) { item in
            switch item {
            case .origin:
                PlacePicker(title: "Starting from", graph: graph, selected: origin) { origin = $0 }
            case .destination:
                PlacePicker(title: "Going to", graph: graph, selected: destination) { destination = $0 }
            case .details:
                if let comparison = session.comparison { RouteDetails(comparison: comparison) }
            case .about:
                AboutView(graph: graph)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 25, weight: .medium)).foregroundStyle(Palette.forest)
                    Text("Peoplemaps").font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-1)
                }
                Spacer()
                Button { sheet = .about } label: { Image(systemName: "info.circle").font(.system(size: 21)).frame(width: 44, height: 44) }
                    .accessibilityLabel("About this prototype").accessibilityIdentifier("about")
            }
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    placeButton(place: origin, label: "FROM", symbol: "circle", target: .origin)
                    Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, 30)
                    placeButton(place: destination, label: "TO", symbol: "mappin", target: .destination)
                }
                Button {
                    let previous = origin; origin = destination; destination = previous
                } label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 64) }
                    .accessibilityLabel("Swap start and destination").accessibilityIdentifier("swap")
            }.padding(.horizontal, 12).background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 18))
            HStack {
                ForEach(TravelMode.allCases) { travelMode in
                    Button { mode = travelMode } label: {
                        Label(travelMode.title, systemImage: travelMode.icon).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(mode == travelMode ? Palette.forest : Color.clear, in: Capsule())
                            .foregroundStyle(mode == travelMode ? .white : Palette.muted)
                    }.accessibilityIdentifier("mode-\(travelMode.rawValue)")
                        .accessibilityAddTraits(mode == travelMode ? .isSelected : [])
                }
            }.padding(3).background(Palette.line.opacity(0.5), in: Capsule())
        }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 14)
    }

    private func placeButton(place: Place, label: String, symbol: String, target: Sheet) -> some View {
        Button { sheet = target } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Palette.muted).tracking(1)
                    Text(place.shortName).font(.system(size: 15, weight: .medium)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(label == "FROM" ? "Starting from" : "Going to"), \(place.shortName)")
            .accessibilityIdentifier("choose-\(target.rawValue)")
    }

    private var comparisonPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("A little less rush.").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("How much extra time feels right?").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Text("UP TO +\(budget) MIN").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Palette.forest)
                    .accessibilityIdentifier("budget-label")
            }
            HStack(spacing: 8) {
                ForEach([0, 2, 5, 10], id: \.self) { value in
                    Button { budget = value } label: {
                        Text(value == 0 ? "No extra" : "+\(value) min").font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(budget == value ? Palette.forest.opacity(0.12) : .white, in: Capsule())
                            .overlay(Capsule().stroke(budget == value ? Palette.forest : Palette.line, lineWidth: 1))
                    }.accessibilityIdentifier("budget-\(value)").accessibilityAddTraits(budget == value ? .isSelected : [])
                }
            }
            stateContent
            Text("Estimates only · no live traffic · route comparison, not navigation")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
            .background(Palette.paper)
    }

    @ViewBuilder private var stateContent: some View {
        switch session.state {
        case .idle, .loading:
            HStack {
                ProgressView().padding(.trailing, 8)
                Text("Comparing Seattle streets…").font(.subheadline)
                Spacer()
                Button("Cancel") { session.cancel() }.font(.subheadline).accessibilityIdentifier("cancel-route")
            }.frame(height: 112)
        case .cancelled:
            status(title: "Comparison paused", message: "Your places are still here.", button: "Compare routes")
        case let .failed(message):
            status(title: "Try another route", message: message, button: "Try again")
        case let .ready(comparison):
            HStack(spacing: 10) {
                routeCard(comparison.fastest, title: "Fastest estimate", detail: "Baseline", selected: !selectedCalmer || comparison.calmer == nil, calmer: false)
                if let calmer = comparison.calmer {
                    routeCard(calmer, title: "Calmer candidate", detail: comparison.extraTimeLabel, selected: selectedCalmer, calmer: true)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Image(systemName: "equal.circle").font(.title3)
                        Text("One good option").font(.system(size: 14, weight: .semibold))
                        Text("No lower-cost alternative\nwithin this budget.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12).frame(minHeight: 105)
                        .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("no-alternative")
                }
            }
            Button { sheet = .details } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.bubble").font(.system(size: 14)).padding(.top, 1)
                    Text(comparison.reasons.first ?? "See what changed").font(.system(size: 12)).multilineTextAlignment(.leading).lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 13)).padding(.top, 2)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 35)
            }.buttonStyle(.plain).accessibilityLabel("Why these routes. \(comparison.reasons.first ?? "")").accessibilityIdentifier("route-details")
        }
    }

    private func routeCard(_ route: Route, title: String, detail: String, selected: Bool, calmer: Bool) -> some View {
        Button { selectedCalmer = calmer } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(calmer ? Palette.forest : Color.gray).frame(width: 6, height: 6)
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(route.duration).font(.system(size: 25, weight: .semibold, design: .rounded)).tracking(-0.5)
                    Text(route.distance).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).frame(minHeight: 105)
                .background(selected ? Palette.forest.opacity(0.07) : .white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Palette.forest : Palette.line, lineWidth: selected ? 1.5 : 1))
        }.buttonStyle(.plain).accessibilityIdentifier(calmer ? "route-calmer" : "route-fastest")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func status(title: String, message: String, button: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Button(button) { session.start(request) }.font(.subheadline.weight(.semibold)).accessibilityIdentifier("retry-route")
        }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 112)
    }
}
