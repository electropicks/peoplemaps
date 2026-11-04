import SwiftUI
import PeoplemapsCore

/// The Map area section of About: the King County offer, its download, and switching to it. Plain list rows; nothing on glass.
struct RegionAboutSection: View {
    /// No route is shown and the person is not navigating, so the map can change under the screen.
    let canSwitchNow: Bool
    @Environment(RegionModel.self) private var regions
    @State private var confirmRemove = false

    var body: some View {
        if let offer = regions.offer {
            Section {
                card(offer)
                controls(offer)
                if regions.fellBack {
                    Text("The King County map couldn\u{2019}t be loaded, so PeopleMaps is showing Seattle. Remove it and download it again.")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("region-fallback")
                }
            } header: {
                Text("Map area").font(.footnote.weight(.semibold)).foregroundStyle(GuidanceOverlay.onGlass).textCase(nil).accessibilityAddTraits(.isHeader)
            } footer: {
                Text(footer).accessibilityIdentifier("region-footer")
            }
            .confirmationDialog("Remove King County from this phone?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { regions.remove() }
            } message: {
                Text(regions.usesCounty ? "PeopleMaps goes back to Seattle the next time it opens. You can download King County again." : "You can download it again.")
            }
        }
    }

    private func card(_ offer: RegionModel.Offer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("King County: Seattle, Bellevue and the rest of the county, plus 3 miles").font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(offer.downloadLabel) to download. About \(offer.installedLabel) on your phone.").font(.subheadline)
                .foregroundStyle(GuidanceOverlay.onGlass).accessibilityIdentifier("region-size")
            Text(regions.usesCounty ? "On this phone now: King County" : "On this phone now: Seattle, included with the app").font(.footnote)
                .foregroundStyle(GuidanceOverlay.onGlass).accessibilityIdentifier("region-current")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("region-card")
    }

    @ViewBuilder private func controls(_ offer: RegionModel.Offer) -> some View {
        switch regions.state {
        case .notDownloaded:
            Button(regions.hasOlderRelease ? "Update" : "Download") { regions.download() }.accessibilityIdentifier("region-download")
        case let .downloading(progress):
            bar(progress, status: "Downloading")
            Button("Pause") { regions.pause() }.accessibilityIdentifier("region-pause")
        case .waitingForWiFi:
            bar(regions.progress ?? .init(received: 0, total: offer.download), status: "Waiting for Wi-Fi")
            Button("Use cellular") { regions.useCellular() }.accessibilityIdentifier("region-cellular")
            Button("Pause") { regions.pause() }.accessibilityIdentifier("region-pause")
        case .paused:
            bar(regions.progress ?? .init(received: 0, total: offer.download), status: "Paused")
            Button("Resume") { regions.resume() }.accessibilityIdentifier("region-resume")
        case let .failed(message):
            Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("region-status")
            Button("Retry") { regions.retry() }.accessibilityIdentifier("region-retry")
        case .verifying:
            HStack(spacing: 12) {
                ProgressView()
                Text("Verifying").accessibilityIdentifier("region-status")
            }
        case .ready:
            Text(regions.usesCounty ? "Ready, in use" : regions.switchPending ? "Ready. Switches at next launch" : "Ready")
                .accessibilityIdentifier("region-status")
            if regions.switchPending && canSwitchNow {
                Button("Switch now") { regions.switchNow() }.accessibilityIdentifier("region-switch")
            }
            Button("Remove", role: .destructive) { confirmRemove = true }.accessibilityIdentifier("region-remove")
        }
    }

    private func bar(_ progress: RegionProgress, status: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(status).font(.subheadline.weight(.medium)).accessibilityIdentifier("region-status")
            ProgressView(value: progress.fraction).accessibilityLabel(status).accessibilityValue("\(Int(progress.fraction * 100)) percent")
                .accessibilityIdentifier("region-progress")
            Text("\(RegionManifest.sizeLabel(progress.received)) of \(RegionManifest.sizeLabel(progress.total))").font(.footnote.monospacedDigit())
                .foregroundStyle(GuidanceOverlay.onGlass).accessibilityIdentifier("region-bytes")
        }
    }

    private var footer: String {
        switch regions.state {
        case .notDownloaded, .failed: "Downloads over Wi-Fi. On cellular it waits until you tap Use cellular. Seattle stays on the map until King County is ready and the app has opened again."
        case .waitingForWiFi: "Cellular is off for this download until you tap Use cellular."
        case .ready where regions.switchPending && !canSwitchNow: "King County loads the next time the app opens. The map never changes during a route."
        case .downloading, .paused, .verifying: "The download continues if you leave the app."
        case .ready: ""
        }
    }
}
