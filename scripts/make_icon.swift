// Renders the LocalLLM app icon (1024×1024 PNG) with CoreGraphics — no external tools.
// Usage: swift scripts/make_icon.swift assets/AppIcon-1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
}

// Flip to a top-left origin so the geometry reads like SVG.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// 1. Body: macOS icon grid (824 pt body, 100 pt inset) with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: rgb(0x000000, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x14204F)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x4F8BFF), rgb(0x3A4FE0), rgb(0x1A1F6E)] as CFArray, locations: [0, 0.45, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 160, y: 100), end: CGPoint(x: 860, y: 924), options: [])
// Glow behind the chip
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x8FE9FF, 0.55), rgb(0x8FE9FF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 380, options: [])
// Top gloss
let gloss = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 470), options: [])
ctx.restoreGState()

// 2. Silicon chip with pins (Apple Silicon / local hardware).
let chip = CGRect(x: 292, y: 292, width: 440, height: 440)
let chipPath = CGPath(roundedRect: chip, cornerWidth: 78, cornerHeight: 78, transform: nil)
ctx.addPath(chipPath); ctx.setFillColor(rgb(0xFFFFFF, 0.12)); ctx.fillPath()
ctx.addPath(chipPath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.92)); ctx.setLineWidth(20); ctx.strokePath()

ctx.setLineCap(.round)
ctx.setLineWidth(20)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.92))
let pins: [CGFloat] = [382, 467, 557, 642]
for p in pins {
    ctx.move(to: CGPoint(x: p, y: 282)); ctx.addLine(to: CGPoint(x: p, y: 222))   // top
    ctx.move(to: CGPoint(x: p, y: 742)); ctx.addLine(to: CGPoint(x: p, y: 802))   // bottom
    ctx.move(to: CGPoint(x: 282, y: p)); ctx.addLine(to: CGPoint(x: 222, y: p))   // left
    ctx.move(to: CGPoint(x: 742, y: p)); ctx.addLine(to: CGPoint(x: 802, y: p))   // right
}
ctx.strokePath()

// 3. AI spark: four-point star with a white→cyan gradient, plus a small companion spark.
func sparkle(center c: CGPoint, radius r: CGFloat, waist w: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
    p.closeSubpath()
    return p
}
let star = sparkle(center: CGPoint(x: 512, y: 520), radius: 150, waist: 26)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: rgb(0x9BF0FF, 0.9))
ctx.addPath(star); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(star); ctx.clip()
let starFill = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xBFF4FF), rgb(0x6FD8FF)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(starFill, start: CGPoint(x: 430, y: 380), end: CGPoint(x: 600, y: 670), options: [])
ctx.restoreGState()

let small = sparkle(center: CGPoint(x: 640, y: 392), radius: 46, waist: 9)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 16, color: rgb(0x9BF0FF, 0.9))
ctx.addPath(small); ctx.setFillColor(rgb(0xFFFFFF, 0.95)); ctx.fillPath()
ctx.restoreGState()

// Export
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("cannot export")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(out)")
