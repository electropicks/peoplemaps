import SwiftUI
import UIKit

/// What the portrait sheet's fit stop holds on the place card and the route preview, designed per screen and scaled for Dynamic Type
/// rather than measured from the content. A measured `.height` is a new detent every time the content is laid out again, so the sheet
/// opened at one height and moved to another a frame later (Docs/DESIGN.md 4.4). Taken from both screens on an iPhone 17 Pro on
/// 10 November 2026 at the sizes listed, each the tallest of the places tried; between them a size is interpolated by the body
/// font's point size. Content taller than its stop scrolls.
enum SheetHeights {
    /// The place card with Directions, its estimate and the estimate's caveat.
    private static let place: [(DynamicTypeSize, CGFloat)] = [(.large, 232), (.xLarge, 249), (.xxxLarge, 319), (.accessibility1, 460), (.accessibility5, 600)]
    /// The route preview: its header and routes, then Why this route, the modes and Start pinned under them.
    private static let preview: [(DynamicTypeSize, CGFloat)] = [(.large, 343), (.xLarge, 350), (.xxxLarge, 409), (.accessibility1, 656)]

    /// The card's content; `fromLine` adds the "From …" line an estimate shows when it doesn't start here.
    static func place(_ size: DynamicTypeSize, fromLine: Bool) -> CGFloat {
        value(place, size) + (fromLine ? lineHeight(.subheadline, size) : 0)
    }
    /// With room for the reason under the calmer route to run to a second line, as it does for some routes (Ballard to Gas Works).
    static func preview(_ size: DynamicTypeSize) -> CGFloat { value(preview, size) + lineHeight(.subheadline, size) }

    private static func lineHeight(_ style: UIFont.TextStyle, _ size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).lineHeight.rounded(.up)
    }

    /// Linear in the body font's size between the measured sizes, and along the nearest two past either end.
    private static func value(_ table: [(DynamicTypeSize, CGFloat)], _ size: DynamicTypeSize) -> CGFloat {
        let x = bodySize(size)
        let i = min(max(table.firstIndex { bodySize($0.0) >= x } ?? table.count - 1, 1), table.count - 1)
        let (x0, y0) = (bodySize(table[i - 1].0), table[i - 1].1), (x1, y1) = (bodySize(table[i].0), table[i].1)
        return (y0 + (x - x0) * (y1 - y0) / (x1 - x0)).rounded()
    }

    private static func bodySize(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 14
        case .small: 15
        case .medium: 16
        case .large: 17
        case .xLarge: 19
        case .xxLarge: 21
        case .xxxLarge: 23
        case .accessibility1: 28
        case .accessibility2: 33
        case .accessibility3: 40
        case .accessibility4: 47
        case .accessibility5: 53
        @unknown default: 17
        }
    }
}
