import SwiftUI
import PeoplemapsCore

/// Shared spacing for the glass redesign (Docs/DESIGN.md section 3).
enum Layout {
    /// Corner radius of an opaque content group inside the sheet.
    static let groupRadius: CGFloat = 22
    /// Sheet content inset.
    static let inset: CGFloat = 16
    /// Landscape card content inset.
    static let cardInset: CGFloat = 12
    /// Space above and below the content of a portrait sheet.
    static let sheetTop: CGFloat = 20
    static let sheetBottom: CGFloat = 12
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
}

private struct FloatingSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let opaque = reduceTransparency || GlassFlags.reduceTransparency
        let glass: Glass = opaque ? .identity : interactive ? .regular.interactive() : .regular
        content
            .background { if opaque { shape.fill(Color.panel) } }
            .glassEffect(glass, in: shape)
            .overlay { if opaque || contrast == .increased { shape.stroke(Color(uiColor: .separator), lineWidth: 1) } }
    }
}

extension View {
    /// Draws the view on Liquid Glass in `shape`, responding to touch when `interactive`. With Reduce Transparency it switches glass
    /// off and fills `.panel`, which in dark mode is nearly the colour of the map's land, so the outline Increase Contrast adds comes
    /// on there too. Use for controls floating over the map, never for reading.
    func floatingSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(FloatingSurface(shape: shape, interactive: interactive))
    }
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
        case .currentLocation: Color(uiColor: .systemBlue)
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
