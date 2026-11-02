import SwiftUI
import UIKit
import Observation
import PeoplemapsCore

/// What the app is showing, for a report. `ExploreView` keeps it current with `.reportContext`.
struct ReportContext {
    var screen: String
    var mode: TravelMode
    var extraMinutes: Int
    var comparison: RouteComparison?
    var navigator: NavigationController?
    /// `SearchIndex.dataVersion`: which OpenStreetMap extract the app is using.
    var dataVersion = "osm-unknown"
}

/// Opens the report composer from anywhere (shake, About, Route details) and marks moments in guidance. The composer
/// is presented from the top view controller, so it works over any sheet. Nothing here uses the network.
@MainActor @Observable
final class ReportCenter {
    static let shared = ReportCenter()
    @ObservationIgnored var context: ReportContext?
    /// True for two seconds after a mark, for the guidance button.
    private(set) var justMarked = false
    /// Reports marked in the trip with this ID, newest last.
    @ObservationIgnored private var marks: (trip: UUID, ids: [String]) = (UUID(), [])
    private let library = ReportLibrary.shared

    func marked(in trip: UUID) -> [String] { marks.trip == trip ? marks.ids.filter { library[$0] != nil } : [] }

    // MARK: Opening

    /// A new report from what is on screen, or the saved one with `id`. `from` names the place the button was.
    func open(from: String? = nil, editing id: String? = nil) {
        guard let top = topController(), !isShowingComposer(top) else { return }
        let report: ProblemReport
        if let id, let saved = library[id] { report = saved } else { report = makeReport(from: from) }
        let host = ReportHost(rootView: ReportComposerView(report: report))
        host.modalPresentationStyle = .pageSheet
        top.present(host, animated: !Motion.off)
    }

    private func isShowingComposer(_ top: UIViewController) -> Bool {
        var vc: UIViewController? = top
        while let v = vc { if v is ReportHost { return true }; vc = v.presentingViewController }
        return false
    }

    private func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var vc = scene?.keyWindow?.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc is UIAlertController ? nil : vc
    }

    // MARK: Marking

    /// One tap in guidance: saves the moment with no sheet and no words. The user adds words after the trip.
    func mark(_ navigator: NavigationController) {
        guard navigator.isActive, let moment = navigator.moment() else { return }
        var report = makeReport(from: nil, navigator: navigator)
        report.moment = moment
        library.save(report)
        marks = (navigator.tripID, marked(in: navigator.tripID) + [report.id])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        justMarked = true
        Task { try? await Task.sleep(for: .seconds(2)); justMarked = false }
    }

    // MARK: Building

    private func makeReport(from: String?, navigator: NavigationController? = nil) -> ProblemReport {
        let c = context ?? ReportContext(screen: "unknown", mode: .drive, extraMinutes: 5)
        let screen = from.map { "\($0), over \(c.screen)" } ?? c.screen
        let guiding = (navigator ?? c.navigator).flatMap { $0.isActive ? $0 : nil }
        var report = ProblemReport(screen: screen, mode: c.comparison?.request.mode ?? c.mode,
                                   extraMinutes: c.comparison?.request.extraMinutes ?? c.extraMinutes,
                                   app: Self.app, dataVersion: c.dataVersion, device: Self.device)
        if let comparison = c.comparison {
            report.origin = Self.place(comparison.snappedOrigin, comparison.request.origin)
            report.destination = Self.place(comparison.snappedDestination, comparison.request.destination)
            report.routes = [Self.info(.fastest, comparison.fastest)] + (comparison.calmer.map { [Self.info(.calmer, $0)] } ?? [])
        }
        if let nav = guiding {
            report.chosen = nav.calmerRoute ? .calmer : .fastest
            report.rerouteCount = nav.rerouteCount
            report.moment = nav.moment()
            report.spoken = ReportSnapshot.spoken(nav.spokenLog, flaggedAt: Date(), destinationName: nav.destination?.shortName)
        }
        return report
    }

    private static func info(_ kind: Report.Chosen, _ route: Route) -> ProblemReport.RouteInfo {
        .init(kind: kind, minutes: route.minutes, seconds: route.metrics.seconds.rounded(), meters: route.metrics.meters.rounded(),
              streets: route.streetNames, edgeIDs: route.edgeIDs)
    }

    private static func place(_ snapped: Coordinate, _ exact: Place) -> ProblemReport.Place {
        .init(snapped: .init(lat: snapped.lat, lon: snapped.lon), exact: .init(lat: exact.lat, lon: exact.lon))
    }

    private static var app: Report.App {
        let info = Bundle.main.infoDictionary
        return .init(version: info?["CFBundleShortVersionString"] as? String ?? "?", build: info?["CFBundleVersion"] as? String ?? "?")
    }

    private static var device: Report.Device {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return .init(model: model, os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
    }
}

/// Marks the composer so a second shake does not stack another one.
final class ReportHost: UIHostingController<ReportComposerView> {}

// MARK: Context and shake

private struct ReportContextModifier: ViewModifier {
    let context: ReportContext
    private var key: Int { [context.screen, "\(context.mode)", "\(context.extraMinutes)", context.comparison?.fastest.id ?? "", context.comparison?.calmer?.id ?? ""].hashValue }
    func body(content: Content) -> some View {
        content
            .onAppear { ReportCenter.shared.context = context }
            .onChange(of: key) { ReportCenter.shared.context = context }
    }
}

extension View {
    /// Tells reports what this screen shows. One line in `ExploreView`.
    func reportContext(screen: String, mode: TravelMode, extraMinutes: Int, comparison: RouteComparison?, navigator: NavigationController, dataVersion: String) -> some View {
        modifier(ReportContextModifier(context: .init(screen: screen, mode: mode, extraMinutes: extraMinutes, comparison: comparison, navigator: navigator, dataVersion: dataVersion)))
    }
}

extension UIWindow {
    /// Shaking the phone opens a report from any screen.
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake { Task { @MainActor in ReportCenter.shared.open() } }
    }
}
