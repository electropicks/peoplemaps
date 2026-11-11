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

/// What to avoid on calmer routes in one travel mode. Each change is written to the store straight away,
/// so the comparison behind the sheet recomputes while it is open.
struct RoutePreferencesView: View {
    let store: RoutePreferencesStore
    let mode: TravelMode
    /// Edited here and copied to the store on every change.
    @State private var draft: RoutePreferences
    @Environment(\.dismiss) private var dismiss

    init(store: RoutePreferencesStore, mode: TravelMode) {
        self.store = store; self.mode = mode
        _draft = State(initialValue: store[mode])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(RoutePreferences.Option.available(in: mode), id: \.self) { row($0) }
                }
                Section {
                    Button("Reset to defaults") { draft = .default(for: mode) }
                        .disabled(draft.isDefault(in: mode))
                        .accessibilityIdentifier("reset-preferences")
                } footer: {
                    Text("Times stay estimates.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Calmer means").navigationSubtitle(mode.activity).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() }.accessibilityIdentifier("preferences-done") }
            }
        }
        .tint(.primary).presentationDetents([.medium, .large])
        .onChange(of: draft) { store[mode] = draft }
    }

    private func row(_ option: RoutePreferences.Option) -> some View {
        Picker(selection: Binding(get: { draft[option] }, set: { draft[option] = $0 })) {
            ForEach(RoutePreferences.Level.allCases, id: \.self) { Text($0.title).tag($0) }
        } label: {
            Label(option.title, systemImage: symbol(option))
        }
        .accessibilityIdentifier("preference-\(option.rawValue)")
    }

    private func symbol(_ option: RoutePreferences.Option) -> String {
        switch option {
        case .trafficLights: "light.beacon.max"
        case .stopSigns: "octagon"
        case .unprotectedLefts: "arrow.turn.up.left"
        case .busyStreets: "car.2.fill"
        case .busyCrossings: mode == .walk ? "figure.walk.motion" : "arrow.left.and.right"
        case .hills: "mountain.2"
        case .turns: "arrow.triangle.turn.up.right.diamond"
        }
    }
}

private extension TravelMode {
    var activity: String { switch self { case .walk: "Walking"; case .bike: "Cycling"; case .drive: "Driving" } }
}
