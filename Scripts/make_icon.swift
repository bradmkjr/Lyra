// Renders Lyra's app icon (a lyre on a violet squircle) at every macOS size.
// Usage: swift Scripts/make_icon.swift Lyra/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

/// Fills `path` (or its stroke outline, if `lineWidth` is set) with a vertical gradient.
func fill(_ ctx: CGContext, _ path: CGPath, _ grad: CGGradient, from: CGFloat, to: CGFloat, lineWidth: CGFloat? = nil) {
    ctx.saveGState()
    ctx.addPath(path)
    if let lineWidth {
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
    }
    ctx.clip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: from), end: CGPoint(x: 512, y: to), options: [])
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext) {
    // Body: Apple's macOS grid puts an 824pt rounded square on the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x2A1760))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x8F45E0), color(0x4B23A8), color(0x1E1050)]),
                           start: CGPoint(x: 260, y: 924), end: CGPoint(x: 780, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Soft glow behind the lyre.
    ctx.drawRadialGradient(gradient([color(0xFFB86B, 0.30), color(0xFFB86B, 0)]),
                           startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 520), endRadius: 360, options: [])
    // Glossy top sheen.
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()

    let gold = gradient([color(0xFFE29A), color(0xF7B548), color(0xE07F27)])

    // Strings sit behind the frame.
    let strings = CGMutablePath()
    for x in stride(from: 452.0, through: 572.0, by: 30.0) {
        strings.move(to: CGPoint(x: x, y: 345))
        strings.addLine(to: CGPoint(x: x, y: 682))
    }
    ctx.saveGState()
    ctx.addPath(strings)
    ctx.setLineWidth(9)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0xFFF4DC, 0.92))
    ctx.strokePath()
    ctx.restoreGState()

    // Arms: rise from the sound box, bow outward, and curl out at the tips.
    let arms = CGMutablePath()
    for side: CGFloat in [-1, 1] {
        func p(_ dx: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 512 + side * dx, y: y) }
        arms.move(to: p(78, 345))
        arms.addCurve(to: p(170, 610), control1: p(210, 400), control2: p(215, 520))
        arms.addCurve(to: p(140, 735), control1: p(140, 670), control2: p(110, 705))
        arms.addCurve(to: p(215, 770), control1: p(165, 760), control2: p(195, 778))
    }

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: color(0x12062E, 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    fill(ctx, arms, gold, from: 790, to: 330, lineWidth: 46)

    // Yoke (crossbar).
    let yoke = CGMutablePath()
    yoke.move(to: CGPoint(x: 352, y: 682))
    yoke.addLine(to: CGPoint(x: 672, y: 682))
    fill(ctx, yoke, gold, from: 710, to: 650, lineWidth: 34)

    // Sound box.
    let box = CGPath(roundedRect: CGRect(x: 392, y: 285, width: 240, height: 92),
                     cornerWidth: 46, cornerHeight: 46, transform: nil)
    fill(ctx, box, gold, from: 377, to: 285)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Sound hole on the box.
    ctx.setFillColor(color(0x7A3A12, 0.55))
    ctx.fillEllipse(in: CGRect(x: 487, y: 312, width: 50, height: 38))
}

// Render once at 1024 and downsample for the smaller sizes.
let master = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
drawIcon(master)
let masterImage = master.makeImage()!

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(masterImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    let url = outDir.appendingPathComponent("icon_\(size).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Failed to write \(url.path)") }
}
print("wrote icons to \(outDir.path)")
