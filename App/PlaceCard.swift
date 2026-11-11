import SwiftUI
import UIKit
import PeoplemapsCore

/// The open place: its name, Directions with an estimate from where the route would start, and what the estimate leaves out.
struct PlaceCard: View {
    let model: ExploreModel
    let place: Place
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The place card's badge, as `CategoryBadge` scales it, for the Directions button's symbol column.
    @ScaledMetric private var badgeDiameter = 44.0

    var body: some View {
        SheetScroll {
            VStack(alignment: .leading, spacing: 14) {
                if typeSize.isAccessibilitySize {
                    // The name needs the full width at these sizes, or it breaks mid-word beside the buttons.
                    HStack(alignment: .top, spacing: 12) {
                        badge
                        Spacer(minLength: 0)
                        favouriteButton
                        CloseButton(label: "Close", id: "close-place") { model.show(.home) }
                    }
                    title
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        badge
                        title
                        Spacer(minLength: 0)
                        favouriteButton
                        CloseButton(label: "Close", id: "close-place") { model.show(.home) }
                    }
                }
                if model.graph.coverage.contains(place.coordinate) {
                    directionsButton.dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    estimateNotes
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Outside the area we cover yet").font(.headline)
                        Text(RegionSelection.usesCounty ? RegionSelection.coverageSentence : "PeopleMaps can route only inside its offline Seattle area for now.").font(.footnote).foregroundStyle(GuidanceOverlay.onGlass)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("outside-coverage")
                }
                if let source = place.source { Text(source).font(.caption).foregroundStyle(GuidanceOverlay.onGlass).accessibilityIdentifier("place-source") }
                if model.sharedMatchID == place.id { Text("Matched from a shared link").font(.caption).foregroundStyle(GuidanceOverlay.onGlass).accessibilityIdentifier("place-shared-match") }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        }
        .task(id: model.estimateRequest(for: place)) { await model.loadEstimate(model.estimateRequest(for: place)) }
    }

    private var badge: some View {
        CategoryBadge(badge: place.badge, raw: place.category, size: 44).dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(place.shortName).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(place.subtitle(near: model.placeNear)).font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("place-subtitle")
        }
    }

    /// "Directions", so the one action on the card says what it does, over the route Start will default to, never the fastest when a
    /// calmer one exists: "Calmer: 16–19 min, 6.2 mi". What the calmer route changes is a note under the button.
    private var directionsButton: some View {
        let ready = model.readyEstimate(for: place), estimating = model.estimating(place)
        return Button { model.startDirections(to: place) } label: {
            // The symbol under the badge and the words under the name, as the header above lays them out.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: ready != nil || estimating ? model.mode.symbol : "arrow.right").font(.body.weight(.semibold))
                    .frame(width: badgeColumn).padding(.leading, badgeColumn == nil ? 0 : -Self.buttonMargin)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Directions").font(.body.weight(.semibold))
                    // The second line is there from the start, so the card keeps its height when the estimate lands.
                    if let ready { Text(ready.comparison.startHeadline).font(.subheadline) }
                    else if estimating { Text("Estimating\u{2026}").font(.subheadline).opacity(0.75) }
                }
            }
            .monospacedDigit().multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.primaryActionText)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).padding(.vertical, 2)
        }
        .primaryAction(shape: typeSize.isAccessibilitySize ? .roundedRectangle(radius: Layout.groupRadius) : .capsule)
        .accessibilityLabel("Directions")
        .accessibilityValue(ready.map { spokenEstimate($0.comparison, mode: $0.request.mode) } ?? "")
        .accessibilityIdentifier("directions")
    }

    /// The badge's width, so the Directions button's symbol sits under the badge and its words start under the place's name. Nil at
    /// accessibility sizes, where the name has the full width and the symbol takes its own.
    private var badgeColumn: CGFloat? {
        guard !typeSize.isAccessibilitySize else { return nil }
        // `badge` stops growing at xxLarge.
        return min(badgeDiameter, UIFontMetrics.default.scaledValue(for: 44, compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraExtraLarge)))
    }
    /// What a large bordered button keeps clear on each side of its label.
    private static let buttonMargin: CGFloat = 20

    private func spokenEstimate(_ comparison: RouteComparison, mode: TravelMode) -> String {
        let route = comparison.calmer ?? comparison.fastest
        let name = comparison.calmer == nil ? "" : "Calmer route, "
        return "\(name)\(route.spokenTimeRange) \(mode.trip), \(DistanceFormat.distance(route.metrics.meters, spoken: true)), \(comparison.spokenCalmSummary), estimate without live traffic"
    }

    /// What the calmer route changes, on one line at standard sizes so the card's height doesn't depend on the words.
    private func calmNote(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.primary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.8)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What the button can't say: where the estimate starts when that isn't here, and that it is an estimate.
    private var estimateNotes: some View {
        VStack(alignment: .leading, spacing: 2) {
            let ready = model.readyEstimate(for: place)
            if let request = model.estimateRequest(for: place), ready != nil || model.estimating(place) {
                // Every line is there from the start, the calm note as a blank until the estimate lands (the button says
                // "Estimating…" meanwhile), so the card keeps its height when it does.
                if !request.origin.isCurrentLocation {
                    Text("From \(request.origin.shortName)").font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("place-estimate")
                }
                if let ready { calmNote(ready.comparison.calmSummary).accessibilityIdentifier("place-calm-summary") }
                else { calmNote("Comparing with the fastest route").hidden().accessibilityHidden(true) }
                Text("Estimate, no live traffic").font(.footnote).foregroundStyle(GuidanceOverlay.onGlass)
                    .accessibilityLabel(ready == nil ? "Estimating" : "Estimate, no live traffic")
                    .accessibilityIdentifier(ready == nil ? "place-estimate-loading" : "place-estimate-caveat")
            } else {
                Text("Compares the fastest route with a calmer one. Works offline.").font(.footnote).foregroundStyle(GuidanceOverlay.onGlass)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 4)
    }

    private var favouriteButton: some View {
        let on = model.saved.isFavourite(place)
        return Button { withAnimation(Motion.content(reduceMotion)) { model.saved.toggleFavourite(place) } } label: {
            Image(systemName: on ? "star.fill" : "star").font(.system(size: 14, weight: .semibold))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30).background(.glassWell, in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(on ? "Remove from Favourites" : "Add to Favourites")
            .accessibilityIdentifier("favourite")
    }
}
