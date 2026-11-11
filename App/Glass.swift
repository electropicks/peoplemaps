import SwiftUI
import PeoplemapsCore

/// Shared spacing for the glass redesign (Docs/DESIGN.md section 3).
enum Layout {
    /// Corner radius of an opaque content group in a modal sheet.
    static let groupRadius: CGFloat = 22
    /// The sheet's corners. The system floats it at its partial stops, so it never needs a device-concentric radius there.
    static let sheetRadius: CGFloat = 38
    /// Sheet content inset.
    static let inset: CGFloat = 16
    /// Landscape card content inset.
    static let cardInset: CGFloat = 12
    /// Space above and below the content of a portrait sheet.
    static let sheetTop: CGFloat = 20
    static let sheetBottom: CGFloat = 12
    /// The least height of a tap target on the sheet. The system draws the sheet about 4% smaller at its partial stops
    /// (it floats 8 pt in from each side), so 46 here is 44 on screen.
    static let target: CGFloat = 46
}

enum GlassFlags {
    /// `--reduce-transparency` forces the opaque fallback in debug builds, so it can be screenshotted without Settings.
    static let reduceTransparency: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--reduce-transparency")
        #else
        return false
        #endif
    }()
    /// The Liquid Glass every floating surface uses (Docs/DESIGN.md, principle 4). `--glass-regular` swaps it in debug builds, to compare on the real map.
    static let variant: Glass = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--glass-regular") { return .regular }
        #endif
        return .clear
    }()
    /// The sheet's glass, which is UIKit's: always `.regular`, under `glassVeil`. The sheet is read at a glance with the map moving
    /// behind it, and `.clear` let the map's labels print across its rows (Docs/DESIGN.md, principle 4).
    static let sheetStyle: UIGlassEffect.Style = .regular
}

/// How much veil a surface carries over its glass.
enum GlassVeil {
    /// Controls floating on the map: glass alone. They hold a word or a symbol, which `.primary` keeps legible.
    case none
    /// A panel with a few short lines on it.
    case light
    /// A panel read at length, or at a glance while driving.
    case dense

    var color: Color? {
        switch self {
        case .none: nil
        case .light: Color(uiColor: .glassVeil)
        case .dense: Color(uiColor: .glassVeilDense)
        }
    }
}

private struct FloatingSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let veil: GlassVeil
    let legible: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let opaque = reduceTransparency || GlassFlags.reduceTransparency
        let base: Glass = legible ? .regular : GlassFlags.variant
        let glass: Glass = opaque ? .identity : interactive ? base.interactive() : base
        content
            .background {
                if opaque { shape.fill(Color.panel) }
                else if let veil = (contrast == .increased ? GlassVeil.dense : veil).color { shape.fill(veil) }
            }
            .glassEffect(glass, in: shape)
            .overlay { if opaque || contrast == .increased { shape.stroke(Color(uiColor: .separator), lineWidth: 1) } }
    }
}

/// Gives the UIKit sheet this view is in our glass at its partial stops, where the system floats it. SwiftUI has no modifier for a
/// detent's effect, and the system's own glass draws under any `presentationBackground`. Large stays the system's: it's read at length.
/// With Reduce Transparency the system's own effect stays too, since it frosts itself.
/// `detents` and `screen` are inputs only so this runs again when SwiftUI swaps the sheet's detents, which come back with the system glass.
struct SheetGlass: UIViewRepresentable {
    let detents: Set<PresentationDetent>
    let screen: String
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeUIView(context: Context) -> UIView { let view = UIView(); view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ view: UIView, context: Context) {
        let plain = reduceTransparency || GlassFlags.reduceTransparency
        // After this update, since SwiftUI may have just replaced the detents.
        DispatchQueue.main.async { [weak view] in
            guard let view,
                  let controller = sequence(first: view as UIResponder, next: \.next).lazy.compactMap({ $0 as? UIViewController }).first,
                  let sheet = controller.sheetPresentationController else { return }
            for detent in sheet.detents where detent.identifier != .large {
                if plain { if detent.backgroundEffect is UIGlassEffect { detent.backgroundEffect = nil } }
                else if !(detent.backgroundEffect is UIGlassEffect) { detent.backgroundEffect = UIGlassEffect(style: GlassFlags.sheetStyle) }
            }
        }
    }
}

extension View {
    /// Draws the view on Liquid Glass in `shape`, responding to touch when `interactive`. With Reduce Transparency it switches glass
    /// off and fills `.panel`, which in dark mode is nearly the colour of the map's land, so the outline Increase Contrast adds comes
    /// on there too. Increase Contrast also takes the dense veil. `legible` swaps `.clear` for `.regular` on surfaces read at a glance
    /// over the route line (guidance banner, trip bar), so the line doesn't show through the text (Docs/DESIGN.md, principle 4).
    func floatingSurface<S: Shape>(in shape: S, interactive: Bool = false, veil: GlassVeil = .none, legible: Bool = false) -> some View {
        modifier(FloatingSurface(shape: shape, interactive: interactive, veil: veil, legible: legible))
    }

    /// The style of a primary action (Start, Directions, Done): a solid `primaryActionFill` button with dark text. Every one sits on a
    /// glass panel, where a glass button would be glass on glass (Docs/DESIGN.md, principle 3).
    func primaryAction(shape: ButtonBorderShape = .capsule) -> some View { modifier(PrimaryAction(shape: shape)) }

    /// The track of a switch when on. The app's tint is `.primary`, which is white in dark mode: a white track under a white knob,
    /// with nothing to tell on from off. Dusk blue (`switchOn`, a deeper value than the map's in dark) is the one hue a control may take (Docs/DESIGN.md, principle 5).
    func switchTint() -> some View { tint(Color(uiColor: .switchOn)) }

    /// A secondary action on a glass panel ("Why this route", "Calmer means"): the system's bordered capsule in the label colour,
    /// since glass doesn't go on glass and no control takes an accent (Docs/DESIGN.md, principles 3 and 5), in a full-size target.
    func wellButton() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule).font(.subheadline.weight(.semibold)).tint(.primary)
            .frame(minHeight: Layout.target).contentShape(Rectangle())
    }
}

private struct PrimaryAction: ViewModifier {
    let shape: ButtonBorderShape
    @Environment(\.solidSurface) private var solid
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// White on a solid white panel wouldn't show.
    private var fill: Color { solid || reduceTransparency || GlassFlags.reduceTransparency ? .primaryActionSolidFill : .primaryActionFill }
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent).buttonBorderShape(shape).tint(fill).controlSize(.large)
    }
}

/// The hand-built twin of `wellButton()`, drawn to match the system's bordered capsule. A `ButtonStyle` can't wrap a system style,
/// so this stays only for the call sites not yet moved: they should move to `wellButton()`, and then this goes.
struct WellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.primary.opacity(0.17), in: Capsule())
            .opacity(configuration.isPressed ? 0.5 : 1)
            .frame(minHeight: Layout.target).contentShape(Rectangle())
    }
}

/// Which of two routes is chosen: a radio mark in the label colour, there before it is tapped so the row reads as a choice.
struct ChoiceMark: View {
    let chosen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
            .font(.body.weight(.medium)).foregroundStyle(chosen ? Color.primary : GuidanceOverlay.onGlass)
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

/// A hairline between rows on glass or in a modal list.
struct Hairline: View {
    var body: some View { Rectangle().fill(.glassHairline).frame(height: 1).accessibilityHidden(true) }
}

extension EnvironmentValues {
    /// The panel is solid here, at the large stop: no glass behind the content.
    @Entry var solidSurface = false
    /// The content is straight on a glass panel: no opaque groups, and secondary text uses `GuidanceOverlay.onGlass`.
    @Entry var onGlassPanel = false
}

/// A group of rows: straight on the panel's glass, or on `panelFill` in a modal sheet.
private struct RowGroup: ViewModifier {
    @Environment(\.onGlassPanel) private var onGlass
    func body(content: Content) -> some View {
        if onGlass { content } else { content.background(.panelFill, in: RoundedRectangle(cornerRadius: Layout.groupRadius)) }
    }
}

extension View {
    func rowGroup() -> some View { modifier(RowGroup()) }
}

/// A filled circle with a glyph: a place's category, or one of the fixed kinds. Hidden from VoiceOver; the row's label
/// carries the category word.
struct CategoryBadge: View {
    let badge: PlaceBadge
    /// The place's raw category, for the more specific transit and sights glyphs.
    var raw: String?
    @ScaledMetric private var diameter: CGFloat

    init(badge: PlaceBadge, raw: String? = nil, size: CGFloat = 32) {
        self.badge = badge
        self.raw = raw
        _diameter = ScaledMetric(wrappedValue: size)
    }

    private var fill: Color {
        switch badge {
        case .category(let group): .categoryFill(group)
        case .address: .categoryFill(.services)
        case .currentLocation: Color(uiColor: .userLocation)
        case .droppedPin: Color(uiColor: .systemRed)
        }
    }
    private var glyph: Color {
        switch badge {
        case .category, .address: .categoryGlyph
        case .currentLocation, .droppedPin: .white
        }
    }

    var body: some View {
        Image(systemName: badge.symbol(raw: raw))
            .font(.system(size: diameter * 0.45, weight: .semibold))
            .foregroundStyle(glyph)
            .frame(width: diameter, height: diameter)
            .background(fill, in: Circle())
            .accessibilityHidden(true)
    }
}
