import SwiftUI
import PeoplemapsCore

struct PlacePicker: View {
    let title: String
    let graph: StreetGraph
    let selected: Place
    let saved: SavedPlacesStore
    /// Set for the origin: offers "Current location" unless location is denied.
    let location: LocationPermission?
    let onSelect: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var access: LocationPermission.Access
    @State private var locating = false
    @State private var locationFailed = false

    init(title: String, graph: StreetGraph, selected: Place, saved: SavedPlacesStore, location: LocationPermission? = nil, onSelect: @escaping (Place) -> Void) {
        self.title = title; self.graph = graph; self.selected = selected; self.saved = saved; self.location = location; self.onSelect = onSelect
        _access = State(initialValue: location?.access ?? .denied)
    }

    private var featured: [Place] { ExploreView.featuredIDs.compactMap { id in graph.places.first { $0.id == id } } }
    private var results: [Place] { Array(graph.search(query).prefix(60)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SearchField(text: $query, identifier: "place-search")
                    if query.isEmpty {
                        if location != nil && access != .denied {
                            CurrentLocationRow(locating: locating, failed: locationFailed, selected: selected.isCurrentLocation, action: useCurrentLocation)
                        }
                        if !saved.favourites.isEmpty { section("Favourites", saved.favourites, prefix: "place-favourite-") }
                        section("Featured places", featured, prefix: "place-")
                        if !saved.recents.isEmpty { section("Recents", saved.recents, prefix: "place-recent-") }
                    } else if results.isEmpty {
                        EmptySearch(count: graph.places.count).padding(.top, 40)
                        AppleMapsLookup(query: query)
                    } else {
                        section("Matches", results, prefix: "place-")
                    }
                }.padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("cancel-search") } }
        }
    }

    private func section(_ title: String, _ places: [Place], prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).textCase(.uppercase).foregroundStyle(.secondary).padding(.leading, 16)
            PlaceList(places: places, query: query, selectedID: selected.id, identifier: { prefix + $0.id }) {
                onSelect($0); dismiss()
            }
        }
    }

    /// Asks for permission only here, on a tap. A refusal hides the row and is never raised again.
    private func useCurrentLocation() {
        guard let location, !locating else { return }
        locating = true; locationFailed = false
        Task {
            if access == .undecided { access = await location.request() }
            if access == .granted {
                if let c = await location.currentCoordinate() {
                    onSelect(.currentLocation(at: Coordinate(lat: c.latitude, lon: c.longitude))); dismiss()
                } else { locationFailed = true }
            }
            locating = false
        }
    }
}

/// "Current location" at the head of the origin list, with the blue of the location puck as in Apple Maps.
struct CurrentLocationRow: View {
    let locating: Bool
    let failed: Bool
    let selected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "location.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Color(uiColor: .systemBlue), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Current location").font(.body).foregroundStyle(.primary)
                    if locating || failed {
                        Text(failed ? "Couldn\u{2019}t find where you are. Try again." : "Finding where you are\u{2026}")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if locating { ProgressView() }
                else if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint) }
            }
            .padding(.horizontal, 14).frame(minHeight: 52).contentShape(Rectangle())
            .animation(Motion.content(reduceMotion), value: locating)
            .animation(Motion.content(reduceMotion), value: failed)
        }
        .buttonStyle(.plain)
        .background(.panelFill, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("place-current-location")
    }
}

/// Native-style search field: gray rounded field, magnifier, clear button.
struct SearchField: View {
    @Binding var text: String
    var identifier = "search-input"
    var focused: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var field: some View {
        let base = TextField("Search places", text: $text).autocorrectionDisabled().submitLabel(.search).accessibilityIdentifier(identifier)
        if let focused { base.focused(focused) } else { base }
    }
}

struct EmptySearch: View {
    let count: Int
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text("No places match in this Seattle area").font(.headline).multilineTextAlignment(.center)
            Text("PeopleMaps searches \(count) places in this offline area.").font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 24)
        .accessibilityElement(children: .combine).accessibilityIdentifier("search-empty")
    }
}
