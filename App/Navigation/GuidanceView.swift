import SwiftUI
import PeoplemapsCore

/// Temporary guidance chrome for stage 2 (stage 3 restyles it to the canvas): top card, calm note, trip bar, reroute and arrival states.
struct GuidanceOverlay: View {
    let navigator: NavigationController
    let landscape: Bool
    let attribution: AnyView
    let onEnd: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if navigator.hasArrived { arrived } else { banner }
            Spacer(minLength: 0)
            HStack { attribution; Spacer() }.padding(.horizontal, 12)
            if !navigator.hasArrived { tripBar }
        }
        .padding(.horizontal, landscape ? 12 : 16).padding(.top, 8).padding(.bottom, landscape ? 8 : 4)
        .frame(maxWidth: landscape ? 460 : .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: Self.symbol(navigator.currentStep?.maneuver ?? .depart)).font(.system(size: 34, weight: .semibold))
                    .frame(width: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NavigationFormat.distance(navigator.distanceToManeuver)).font(.title2.bold())
                        .accessibilityIdentifier("guidance-distance")
                    Text(navigator.instruction).font(.body).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("guidance-instruction")
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.panel, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 2)
            .accessibilityElement(children: .contain).accessibilityIdentifier("guidance-card")
            if let note = navigator.calmNote {
                Text(note).font(.footnote.weight(.semibold)).foregroundStyle(.calmerText)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.panel, in: Capsule()).shadow(color: .black.opacity(0.1), radius: 6, y: 1)
                    .accessibilityIdentifier("guidance-calm-note")
            }
            if navigator.isRerouting {
                HStack(spacing: 8) { ProgressView(); Text("Finding a calmer way…").font(.subheadline) }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.panel, in: Capsule()).shadow(color: .black.opacity(0.1), radius: 6, y: 1)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("guidance-rerouting")
            }
        }
    }

    private var tripBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(NavigationFormat.minutes(navigator.remainingSeconds)) min").font(.title3.bold())
                    .accessibilityIdentifier("trip-minutes")
                Text(NavigationFormat.distance(navigator.remainingMeters)).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("trip-distance")
            }
            Spacer(minLength: 0)
            Button(action: onEnd) {
                Text("End").font(.body.weight(.semibold)).frame(width: 88, height: 44)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("end-navigation")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.panel, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.14), radius: 12, y: -1)
    }

    private var arrived: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "mappin.circle.fill").font(.system(size: 34)).foregroundStyle(.calmer).frame(width: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arrived").font(.title2.bold()).accessibilityIdentifier("guidance-arrived")
                    if let name = navigator.destination?.shortName { Text(name).font(.body).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            Button(action: onDone) {
                Text("Done").font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 50)
                    .foregroundStyle(.directionsText).background(.directionsFill, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("done-navigation")
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.panel, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 2)
    }

    static func symbol(_ maneuver: Maneuver) -> String {
        switch maneuver {
        case .depart, .continueOnto: "arrow.up"
        case .cross: "figure.walk"
        case .arrive: "mappin.circle.fill"
        case let .turn(direction):
            switch direction {
            case .slightLeft: "arrow.up.left"
            case .left: "arrow.turn.up.left"
            case .sharpLeft: "arrow.turn.down.left"
            case .slightRight: "arrow.up.right"
            case .right: "arrow.turn.up.right"
            case .sharpRight: "arrow.turn.down.right"
            case .uTurn: "arrow.uturn.left"
            }
        }
    }
}
