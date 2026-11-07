// Renders the app icon (dark gauge) and packs Resources/AppIcon.icns.
//   swift scripts/make-icon.swift            -> Resources/AppIcon.icns
//   swift scripts/make-icon.swift out.png    -> also write a 1024px preview PNG
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k)

    // Apple icon grid: 824pt body centered on a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow + body gradient.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.14, blue: 0.20, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [CGColor(srgbRed: 0.18, green: 0.21, blue: 0.29, alpha: 1),
                                   CGColor(srgbRed: 0.09, green: 0.11, blue: 0.16, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Thin inner highlight along the top edge.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // Gauge, y up. Center slightly below the middle.
    let c = CGPoint(x: 512, y: 490)
    let r: CGFloat = 270
    let deg = CGFloat.pi / 180
    func arc(from a0: CGFloat, to a1: CGFloat) -> CGPath {
        let p = CGMutablePath()
        // In y-up space, 225° is lower-left, -45° lower-right; clockwise = over the top.
        p.addArc(center: c, radius: r, startAngle: a0 * deg, endAngle: a1 * deg, clockwise: true)
        return p
    }
    ctx.setLineCap(.round)
    ctx.setLineWidth(78)
    ctx.addPath(arc(from: 225, to: -45))
    ctx.setStrokeColor(CGColor(srgbRed: 0.24, green: 0.27, blue: 0.36, alpha: 1))
    ctx.strokePath()

    // Value arc: teal, about 60% of the sweep.
    ctx.addPath(arc(from: 225, to: 63))
    ctx.setStrokeColor(CGColor(srgbRed: 0.365, green: 0.792, blue: 0.647, alpha: 1))
    ctx.strokePath()

    // Needle pointing at the value end, plus hub.
    let a = 63 * deg
    let tip = CGPoint(x: c.x + cos(a) * (r - 110), y: c.y + sin(a) * (r - 110))
    ctx.move(to: c)
    ctx.addLine(to: tip)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(40)
    ctx.strokePath()
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - 48, y: c.y - 48, width: 96, height: 96))

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "failed to write \(url.path)")
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(render(base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
precondition(p.terminationStatus == 0, "iconutil failed")
print("Wrote \(out.path)")

if CommandLine.arguments.count > 1 {
    let preview = URL(fileURLWithPath: CommandLine.arguments[1])
    writePNG(render(1024), preview)
    print("Wrote \(preview.path)")
}
