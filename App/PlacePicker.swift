import SwiftUI
import PeoplemapsCore

struct PlacePicker: View {
    let title: String
    let search: SearchIndex
    /// Nil while the field is empty ("Choose start").
    let selected: Place?
    let saved: SavedPlacesStore
    /// Set for the origin: offers "Current location" unless location is denied.
    let location: LocationPermission?
    let onSelect: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var access: LocationPermission.Access
    @State private var locating = false
    @State private var locationFailed = false

    init(title: String, search: SearchIndex, selected: Place?, saved: SavedPlacesStore, location: LocationPermission? = nil, onSelect: @escaping (Place) -> Void) {
        self.title = title; self.search = search; self.selected = selected; self.saved = saved; self.location = location; self.onSelect = onSelect
        _access = State(initialValue: location?.access ?? .denied)
    }

    private var results: [Place] { search.search(query, near: selected?.coordinate) }
    private var offersCurrentLocation: Bool { location != nil && access != .denied }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SearchField(text: $query, identifier: "place-search")
                    if query.isEmpty {
                        if offersCurrentLocation {
                            CurrentLocationRow(locating: locating, failed: locationFailed, selected: selected?.isCurrentLocation == true, action: useCurrentLocation)
                        }
                        if !saved.favourites.isEmpty { section("Favourites", saved.favourites, prefix: "place-favourite-") }
                        if !saved.recents.isEmpty { section("Recents", saved.recents, prefix: "place-recent-") }
                        if !offersCurrentLocation && saved.favourites.isEmpty && saved.recents.isEmpty {
                            Text("Search a place or address.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                                .accessibilityIdentifier("place-hint")
                        }
                    } else if results.isEmpty {
                        EmptySearch(count: search.count).padding(.top, 40)
                        AppleMapsLookup(query: query)
                    } else {
                        section("Matches", results, prefix: "place-")
                    }
                }.padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() }.accessibilityIdentifier("cancel-search") } }
        }.tint(.primary)
    }

    private func section(_ title: String, _ places: [Place], prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 16)
                .accessibilityAddTraits(.isHeader)
            PlaceList(places: places, query: query, selectedID: selected?.id, near: selected?.coordinate, identifier: { prefix + $0.id }) {
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
                CategoryBadge(badge: .currentLocation)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Current location").font(.body).foregroundStyle(.primary)
                    if locating || failed {
                        Text(failed ? "Couldn\u{2019}t find where you are. Try again." : "Finding where you are\u{2026}")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if locating { ProgressView() }
                else if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.primary) }
            }
            .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: 52).contentShape(Rectangle())
            .animation(Motion.content(reduceMotion), value: locating)
            .animation(Motion.content(reduceMotion), value: failed)
        }
        .buttonStyle(.plain)
        .background(.panelFill, in: RoundedRectangle(cornerRadius: Layout.groupRadius))
        .accessibilityIdentifier("place-current-location")
    }
}

/// Native-style search field: tertiary-fill capsule (no glass on the glass sheet), magnifier, clear button.
struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search places"
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
        .background(.fill.tertiary, in: Capsule())
    }

    @ViewBuilder private var field: some View {
        let base = TextField(placeholder, text: $text).autocorrectionDisabled().submitLabel(.search).accessibilityIdentifier(identifier)
        if let focused { base.focused(focused) } else { base }
    }
}

struct EmptySearch: View {
    let count: Int
    var body: some View {
        ContentUnavailableView {
            Label("No places match in this Seattle area", systemImage: "magnifyingglass")
        } description: {
            Text("PeopleMaps searches \(count.formatted()) places and addresses in this offline area.")
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("search-empty")
    }
}
