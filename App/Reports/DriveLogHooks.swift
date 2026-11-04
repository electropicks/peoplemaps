import SwiftUI
import PeoplemapsCore

/// What the app is showing, as plain values, so a change between two of them is one line in the app-use file.
struct DriveLogSnapshot: Equatable {
    var screen: String
    var place: Place?
    var query: String
    var mode: TravelMode
    var budget: Int
    var sheet: String?
    var calmer: Bool
    /// Destination, mode and budget while a preview or guidance is up; nil otherwise.
    var request: String?
    var destination: Place?
    var routeReady: Bool
}

/// Turns changes of `DriveLogSnapshot` into app-use lines (`DriveLogger.use`). It reads the screen and decides nothing.
private struct DriveLogUseModifier: ViewModifier {
    let snapshot: DriveLogSnapshot
    @State private var routingStarted: Date?

    func body(content: Content) -> some View {
        content.onChange(of: snapshot) { old, new in
            guard DriveLogger.enabled else { return }
            diff(old, new)
        }
    }

    private func diff(_ old: DriveLogSnapshot, _ new: DriveLogSnapshot) {
        if old.screen != new.screen {
            if let place = new.place, old.place != place {
                DriveLogger.use("place_card", ["id": .string(place.id), "name": .string(place.name), "category": .string(place.category)])
            }
            if new.screen == "search" { DriveLogger.use("search_opened") }
            if old.screen == "search", !old.query.isEmpty, new.place == nil {
                DriveLogger.use("search_abandoned", ["query": .string(old.query)])
            }
            if old.screen == "preview", new.screen != "navigating" {
                DriveLogger.use("preview_abandoned", ["destination": .text(old.destination?.name), "mode": .string(old.mode.rawValue), "extraMinutes": .num(old.budget)])
            }
            if new.screen == "navigating" {
                DriveLogger.use("navigation_started", ["destination": .text(new.destination?.name), "mode": .string(new.mode.rawValue),
                                                       "extraMinutes": .num(new.budget), "calmer": .bool(new.calmer)])
            }
        }
        if old.mode != new.mode { DriveLogger.use("mode_changed", ["from": .string(old.mode.rawValue), "to": .string(new.mode.rawValue)]) }
        if old.budget != new.budget { DriveLogger.use("budget_changed", ["from": .num(old.budget), "to": .num(new.budget), "mode": .string(new.mode.rawValue)]) }
        if let sheet = new.sheet, old.sheet != sheet { DriveLogger.use("sheet_opened", ["name": .string(sheet)]) }
        if new.request != nil, old.request != new.request {
            routingStarted = Date()
            DriveLogger.use("preview", ["destination": .text(new.destination?.name), "destinationID": .text(new.destination?.id),
                                        "mode": .string(new.mode.rawValue), "extraMinutes": .num(new.budget)])
        }
        if new.routeReady, !old.routeReady, let began = routingStarted {
            DriveLogger.use("route_ready", ["ms": .num(Date().timeIntervalSince(began) * 1000), "mode": .string(new.mode.rawValue)])
        }
        if new.request != nil, new.request == old.request, old.calmer != new.calmer, new.screen == "preview" {
            DriveLogger.use("route_selected", ["calmer": .bool(new.calmer)])
        }
    }
}

extension View {
    /// One line in `ExploreView`: app use for the detailed log, off unless the switch in About is on.
    func driveLogUse(_ snapshot: DriveLogSnapshot) -> some View { modifier(DriveLogUseModifier(snapshot: snapshot)) }
}
