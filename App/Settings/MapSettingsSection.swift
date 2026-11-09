import SwiftUI
import PeoplemapsCore

/// The Map section of Settings: which map is on the phone, then the King County offer, its download, and switching to it.
/// Plain list rows; nothing on glass.
struct MapSettingsSection: View {
    /// No route is shown and the person is not navigating, so the map can change under the screen.
    let canSwitchNow: Bool
    @Environment(RegionModel.self) private var regions
    @State private var confirmRemove = false

    var body: some View {
        Section {
            SettingsValueRow(title: "On this phone", value: regions.usesCounty ? "King County" : "Seattle")
                .accessibilityElement(children: .combine).accessibilityIdentifier("region-current")
            if let offer = regions.offer {
                rows(offer)
                if regions.fellBack {
                    Text("The King County map couldn\u{2019}t be loaded, so PeopleMaps is showing Seattle. Remove it and download it again.")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("region-fallback")
                }
            }
        } header: { SettingsHeader("Map") } footer: {
            if let offer = regions.offer, let footer = footer(offer) { SettingsFooter(footer).accessibilityIdentifier("region-footer") }
        }
        .confirmationDialog("Remove King County from this phone?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { regions.remove() }
        } message: {
            Text(regions.usesCounty ? "PeopleMaps goes back to Seattle the next time it opens. You can download King County again." : "You can download it again.")
        }
    }

    /// One row that says where King County stands, then a row per thing to do about it.
    @ViewBuilder private func rows(_ offer: RegionModel.Offer) -> some View {
        switch regions.state {
        case .notDownloaded:
            download(offer)
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
            card { Text(message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("region-status") }
            Button("Retry") { regions.retry() }.accessibilityIdentifier("region-retry")
        case .verifying:
            LabeledContent {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Verifying").foregroundStyle(GuidanceOverlay.onGlass).accessibilityIdentifier("region-status")
                }
            } label: { Text("King County") }
        case .ready:
            card {
                Text(regions.usesCounty ? "Ready, in use" : regions.switchPending ? "Ready. Switches at next launch" : "Ready")
                    .accessibilityIdentifier("region-status")
            }
            if regions.switchPending && canSwitchNow {
                Button("Switch now") { regions.switchNow() }.accessibilityIdentifier("region-switch")
            }
            Button("Remove King County", role: .destructive) { confirmRemove = true }.accessibilityIdentifier("region-remove")
        }
    }

    /// The offer at rest: what a tap gets, and how big the download is.
    private func download(_ offer: RegionModel.Offer) -> some View {
        Button { regions.download() } label: {
            SettingsValueRow(title: regions.hasOlderRelease ? "Update King County" : "Download King County", value: offer.downloadLabel)
        }
        .accessibilityIdentifier("region-download")
    }

    /// King County over one line that says where it stands.
    private func card(@ViewBuilder _ status: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("King County")
            status().font(.subheadline).foregroundStyle(GuidanceOverlay.onGlass)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("region-card")
    }

    private func bar(_ progress: RegionProgress, status: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(status).foregroundStyle(GuidanceOverlay.onGlass).accessibilityIdentifier("region-status")
            } label: { Text("King County") }
            ProgressView(value: progress.fraction).accessibilityLabel(status).accessibilityValue("\(Int(progress.fraction * 100)) percent")
                .accessibilityIdentifier("region-progress")
            Text("\(RegionManifest.sizeLabel(progress.received)) of \(RegionManifest.sizeLabel(progress.total))").font(.footnote.monospacedDigit())
                .foregroundStyle(GuidanceOverlay.onGlass).accessibilityIdentifier("region-bytes")
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain).accessibilityIdentifier("region-card")
    }

    private func footer(_ offer: RegionModel.Offer) -> String? {
        switch regions.state {
        case .notDownloaded, .failed:
            "The whole county and 3 miles beyond, about \(offer.installedLabel) on your phone. Downloads over\u{00A0}Wi-Fi."
        case .waitingForWiFi: "Cellular is off for this download until you tap Use\u{00A0}cellular."
        case .ready where regions.switchPending && !canSwitchNow: "King County loads the next time the app opens. The map never changes during a\u{00A0}route."
        case .downloading, .paused, .verifying: "The download continues if you leave the app. Seattle stays on the map until King County is ready and the app has opened\u{00A0}again."
        case .ready: nil
        }
    }
}
