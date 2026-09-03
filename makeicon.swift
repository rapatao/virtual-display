// Renders VirtualDisplay.iconset. Run: swift makeicon.swift
// Each size is drawn from vectors rather than downsampled from 1024, so the strokes
// stay crisp at 16pt instead of turning into grey mush.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything below is authored against a 1024pt canvas and scaled per output size.
func draw(into ctx: CGContext, side: CGFloat) {
    let k = side / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * k, y: y * k, width: w * k, height: h * k)
    }
    func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius * k, cornerHeight: radius * k, transform: nil)
    }

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Rounded-square plate, inset like a standard macOS app icon.
    let plate = rounded(r(100, 100, 824, 824), 185)
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [CGColor(srgbRed: 0.42, green: 0.60, blue: 0.99, alpha: 1),
                                       CGColor(srgbRed: 0.23, green: 0.20, blue: 0.75, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: side),
                           end: CGPoint(x: side, y: 0),
                           options: [])
    ctx.restoreGState()

    // The screen: an outline only.
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(44 * k)
    ctx.addPath(rounded(r(210, 300, 604, 424), 52))
    ctx.strokePath()

    // The mirrored region: a solid block floating inside it, clear of the outline.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(rounded(r(492, 366, 268, 192), 32))
    ctx.fillPath()
}

func render(side: Int, to url: URL) {
    let ctx = CGContext(data: nil,
                        width: side, height: side,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(into: ctx, side: CGFloat(side))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("could not encode \(url.lastPathComponent)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("VirtualDisplay.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconutil expects exactly this set of names.
for base in [16, 32, 128, 256, 512] {
    render(side: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    render(side: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(iconset.path)")
