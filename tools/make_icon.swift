import AppKit
import CoreGraphics
import CoreText

// Renders the Power Tools app icon: a FLAT black-and-white mark — a white command
// (⌘) symbol on a solid black squircle (no gradient, shadow, or highlight).
// Crisp from 16px to 1024px. Writes an .iconset; iconutil packs the .icns.

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

    // --- command symbol (⌘), centered on its glyph path bounds ---
    let font = NSFont.systemFont(ofSize: S * 0.6, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        NSAttributedString.Key(rawValue: kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "⌘", attributes: attrs))
    let gb = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)  // tight glyph box
    ctx.setFillColor(color(255, 255, 255))
    ctx.textPosition = CGPoint(x: S/2 - gb.midX, y: S/2 - gb.midY)
    CTLineDraw(line, ctx)

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
