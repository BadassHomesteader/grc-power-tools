import AppKit
import CoreGraphics

// Renders the Power Tools app icon: a FLAT black-and-white mark — a white mic on
// a solid black squircle (no gradient, shadow, or highlight). Vector-drawn, so it
// stays crisp from 16px to 1024px. Writes an .iconset; iconutil packs the .icns.

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

    // flat solid-black squircle (no shadow, gradient, or highlight)
    ctx.addPath(squircle)
    ctx.setFillColor(color(18, 18, 20))
    ctx.fillPath()

    // --- microphone (all white) ---
    let cx = S * 0.5
    let w = S * 0.215
    let hCap = S * 0.30
    let capRect = CGRect(x: cx - w/2, y: S * 0.445, width: w, height: hCap)  // device coords (y up)
    let devCy = S * 0.595
    let r = w/2 + S * 0.05
    let cradleBottomY = devCy - r
    let stemBottomY = cradleBottomY - S * 0.085
    let baseHW = S * 0.105

    // white cradle + stem + base (drawn first, capsule sits on top)
    ctx.setStrokeColor(color(255, 255, 255))
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
    ctx.setFillColor(color(255, 255, 255))
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
