// Draws the app icon: one calm green route along a quiet street grid, with a single soft corner.
// Run with `swift Scripts/make_icon.swift` from the repository root; writes the three 1024 px PNGs.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

struct Palette {
    let background: [CGColor]?   // top and bottom of the ground; nil leaves it transparent
    let street: CGColor
    let direct: CGColor
    let route: CGColor
    let startFill: CGColor
    let endDot: CGColor
}

let start = CGPoint(x: 300, y: 780), end = CGPoint(x: 724, y: 300)   // y grows downward

func draw(_ p: Palette, to name: String) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: p.background == nil ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)
    if let ground = p.background {
        let gradient = CGGradient(colorsSpace: space, colors: ground as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])
    }
    ctx.setLineCap(.round); ctx.setLineJoin(.round)

    // A quiet street grid; the route runs along two of its streets.
    ctx.setStrokeColor(p.street); ctx.setLineWidth(18)
    for v in [88, 300, 724, 936] as [CGFloat] {
        ctx.move(to: CGPoint(x: v, y: -20)); ctx.addLine(to: CGPoint(x: v, y: 1044))
        ctx.move(to: CGPoint(x: -20, y: v)); ctx.addLine(to: CGPoint(x: 1044, y: v))
    }
    ctx.strokePath()

    // The busy diagonal the fastest route would take, a little heavier.
    ctx.setStrokeColor(p.direct); ctx.setLineWidth(34)
    ctx.move(to: CGPoint(x: -20, y: 1044)); ctx.addLine(to: CGPoint(x: 1044, y: -20)); ctx.strokePath()

    // The calmer route: up one street, a soft turn, along the next.
    ctx.setStrokeColor(p.route); ctx.setLineWidth(80)
    ctx.move(to: start)
    ctx.addArc(tangent1End: CGPoint(x: start.x, y: end.y), tangent2End: end, radius: 170)
    ctx.addLine(to: end)
    ctx.strokePath()

    // Start: a ring. End: a filled dot with a pin-like centre.
    ctx.setFillColor(p.startFill); ctx.setStrokeColor(p.route); ctx.setLineWidth(24)
    ctx.addEllipse(in: CGRect(x: start.x - 54, y: start.y - 54, width: 108, height: 108)); ctx.drawPath(using: .fillStroke)
    ctx.setFillColor(p.route)
    ctx.fillEllipse(in: CGRect(x: end.x - 72, y: end.y - 72, width: 144, height: 144))
    ctx.setFillColor(p.endDot)
    ctx.fillEllipse(in: CGRect(x: end.x - 26, y: end.y - 26, width: 52, height: 52))

    let url = out.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    print(url.path)
}

// Light: opaque white ground (the App Store icon must have no alpha).
try draw(Palette(background: [rgb(0xFFFFFF), rgb(0xF2F2F2)], street: rgb(0xE8E8ED), direct: rgb(0xC7C7CC),
                 route: rgb(0x248A3D), startFill: rgb(0xFFFFFF), endDot: rgb(0xFFFFFF)), to: "AppIcon.png")
// Dark: transparent ground so the system's dark backdrop shows; the dark-mode green.
try draw(Palette(background: nil, street: rgb(0x2C2C2E), direct: rgb(0x48484A),
                 route: rgb(0x30D158), startFill: rgb(0x000000), endDot: rgb(0x000000)), to: "AppIcon-Dark.png")
// Tinted: greyscale; the system applies the person's tint by luminance.
try draw(Palette(background: [rgb(0x000000), rgb(0x000000)], street: rgb(0x262626), direct: rgb(0x5A5A5A),
                 route: rgb(0xFFFFFF), startFill: rgb(0x000000), endDot: rgb(0x000000)), to: "AppIcon-Tinted.png")
