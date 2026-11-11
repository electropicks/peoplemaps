import SwiftUI
import PeoplemapsCore

/// The route preview's "Calmer means" button: opens the preferences sheet and says when anything differs from the defaults.
struct RoutePreferencesRow: View {
    let isCustom: Bool
    let action: () -> Void
    private var value: String { isCustom ? "Custom" : "Default" }

    var body: some View {
        Button(action: action) {
            Text(isCustom ? "Calmer means: Custom" : "Calmer means").multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(WellButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calmer means, \(value)")
        .accessibilityHint("Choose what to avoid on calmer routes")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("route-preferences")
    }
}

/// What to avoid on calmer routes, mode by mode. It opens on the mode being routed, and the switch at the top reaches the others.
/// Each change is written to the store straight away, so the comparison behind the sheet recomputes while it is open.
struct RoutePreferencesView: View {
    let store: RoutePreferencesStore
    @State private var mode: TravelMode
    @Environment(\.dismiss) private var dismiss

    init(store: RoutePreferencesStore, mode: TravelMode) {
        self.store = store
        _mode = State(initialValue: mode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(RoutePreferences.Option.available(in: mode), id: \.self) { row($0) }
                } header: {
                    Picker("Travel mode", selection: $mode) {
                        ForEach(TravelMode.displayOrder) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().textCase(nil)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                    .accessibilityIdentifier("preferences-mode")
                }
                Section {
                    Button("Reset \(mode.activity) to defaults") { store[mode] = .default(for: mode) }
                        .disabled(store[mode].isDefault(in: mode))
                        .accessibilityIdentifier("reset-preferences")
                } footer: {
                    Text("Times stay estimates.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Calmer means").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() }.accessibilityIdentifier("preferences-done") }
            }
        }
        .tint(.primary).presentationDetents([.medium, .large])
    }

    private func row(_ option: RoutePreferences.Option) -> some View {
        Picker(selection: Binding(get: { store[mode][option] }, set: { var p = store[mode]; p[option] = $0; store[mode] = p })) {
            ForEach(RoutePreferences.Level.allCases, id: \.self) { Text($0.title).tag($0) }
        } label: {
            Label {
                Text(option.title)
                if let detail = option.detail { Text(detail) }
            } icon: {
                Image(systemName: symbol(option))
            }
        }
        .accessibilityIdentifier("preference-\(option.rawValue)")
    }

    private func symbol(_ option: RoutePreferences.Option) -> String {
        switch option {
        case .stops: "hand.raised"
        case .trafficLights: "light.beacon.max"
        case .stopSigns: "octagon"
        case .unprotectedLefts: "arrow.turn.up.left"
        case .busyStreets: "car.2.fill"
        case .busyCrossings: mode == .walk ? "figure.walk.motion" : "arrow.left.and.right"
        case .hills: "mountain.2"
        case .steps: "stairs"
        case .highwayMerges: "arrow.merge"
        case .drawbridges: "water.waves"
        case .complexJunctions: "asterisk"
        case .narrowStreets: "arrow.right.and.line.vertical.and.arrow.left"
        case .roughSurfaces: "road.lanes"
        case .noSidewalks: "figure.walk.diamond"
        case .turns: "arrow.triangle.turn.up.right.diamond"
        }
    }
}

private extension TravelMode {
    var activity: String { switch self { case .walk: "walking"; case .bike: "cycling"; case .drive: "driving" } }
}
