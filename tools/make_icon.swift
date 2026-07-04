import AppKit
import CoreGraphics

// Renders the GRC Whisper app icon (white mic + green cradle on an indigo
// squircle) at every size macOS needs, writes an .iconset, and leaves iconutil
// to pack the .icns. Vector-drawn, so it stays crisp from 16px to 1024px.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

func render(_ S: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // --- squircle background ---
    let margin = S * 0.095
    let side = S - 2 * margin
    let corner = side * 0.2237
    let rect = CGRect(x: margin, y: margin, width: side, height: side)
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
                  color: color(0, 0, 0, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(color(46, 42, 107))
    ctx.fillPath()
    ctx.restoreGState()

    // indigo gradient fill, clipped to the squircle
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs,
                          colors: [color(97, 116, 240), color(52, 46, 122)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    // soft top highlight
    let hi = CGGradient(colorsSpace: cs,
                        colors: [color(255, 255, 255, 0.16), color(255, 255, 255, 0)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: S * 0.55), options: [])
    ctx.restoreGState()

    // --- microphone ---
    let cx = S * 0.5
    let w = S * 0.215
    let hCap = S * 0.30
    let capRect = CGRect(x: cx - w/2, y: S * 0.445, width: w, height: hCap)  // device coords (y up)
    let devCy = S * 0.595
    let r = w/2 + S * 0.05
    let cradleBottomY = devCy - r
    let stemBottomY = cradleBottomY - S * 0.085
    let baseHW = S * 0.105

    // green cradle + stem + base (drawn first, capsule sits on top)
    ctx.setStrokeColor(color(52, 199, 89))
    ctx.setLineWidth(S * 0.040)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let cradle = CGMutablePath()
    cradle.addArc(center: CGPoint(x: cx, y: devCy), radius: r,
                  startAngle: .pi * 200/180, endAngle: .pi * 340/180, clockwise: false)
    ctx.addPath(cradle)
    ctx.strokePath()

    ctx.move(to: CGPoint(x: cx, y: cradleBottomY))
    ctx.addLine(to: CGPoint(x: cx, y: stemBottomY))
    ctx.strokePath()

    ctx.move(to: CGPoint(x: cx - baseHW, y: stemBottomY))
    ctx.addLine(to: CGPoint(x: cx + baseHW, y: stemBottomY))
    ctx.strokePath()

    // white capsule
    ctx.addPath(CGPath(roundedRect: capRect, cornerWidth: w/2, cornerHeight: w/2, transform: nil))
    ctx.setFillColor(color(255, 255, 255, 0.98))
    ctx.fillPath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

// unique pixel size -> iconset filenames
let map: [(Int, [String])] = [
    (16,  ["icon_16x16.png"]),
    (32,  ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64,  ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024,["icon_512x512@2x.png"]),
]

for (size, names) in map {
    let img = render(CGFloat(size))
    for name in names { writePNG(img, to: "\(outDir)/\(name)") }
}
print("wrote iconset to \(outDir)")
