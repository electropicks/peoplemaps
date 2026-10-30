import SwiftUI
import PeoplemapsCore

/// The route preview's "Calmer means" row: opens the preferences sheet and says whether anything differs from the defaults.
struct RoutePreferencesRow: View {
    let isCustom: Bool
    let action: () -> Void
    private var value: String { isCustom ? "Custom" : "Default" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary).frame(width: 22)
                Text("Calmer means").foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.body)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(.panelFill, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(store: RoutePreferencesStore, mode: TravelMode) {
        self.store = store; self.mode = mode
        _draft = State(initialValue: store[mode])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(RoutePreferences.Option.available(in: mode), id: \.self) { row($0) }
                } header: {
                    Text(mode.activity).textCase(nil).font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Button("Reset to defaults") { draft = .default(for: mode) }
                        .disabled(draft.isDefault(in: mode))
                        .accessibilityIdentifier("reset-preferences")
                } footer: {
                    Text("Times stay estimates.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Calmer means")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("preferences-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: draft) { store[mode] = draft }
    }

    private func row(_ option: RoutePreferences.Option) -> some View {
        let label = HStack(spacing: 12) {
            Image(systemName: symbol(option)).foregroundStyle(.secondary).frame(width: 24)
            Text(option.title)
        }.accessibilityHidden(true)
        let level: Binding<RoutePreferences.Level> = $draft[dynamicMember: \.[option]]
        let picker = Picker(option.title, selection: level) {
            ForEach(RoutePreferences.Level.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .accessibilityLabel(option.title)
        .accessibilityIdentifier("preference-\(option.rawValue)")
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { label; picker }
            } else {
                HStack(spacing: 12) { label; Spacer(minLength: 0); picker.fixedSize() }
            }
        }.padding(.vertical, 4)
    }

    private func symbol(_ option: RoutePreferences.Option) -> String {
        switch option {
        case .trafficLights: "trafficlight"
        case .stopSigns: "octagon"
        case .unprotectedLefts: "arrow.turn.up.left"
        case .busyStreets: "car.2"
        case .busyCrossings: mode == .walk ? "figure.walk.motion" : "arrow.left.and.right"
        case .hills: "mountain.2"
        case .turns: "arrow.triangle.turn.up.right.diamond"
        }
    }
}

private extension TravelMode {
    var activity: String { switch self { case .walk: "Walking"; case .bike: "Cycling"; case .drive: "Driving" } }
}
