import AppKit

/// hold + K → the screen color picker (eyedropper). Presents macOS's own
/// magnifier loupe and, on pick, copies the sampled color's hex (#RRGGBB) to the
/// clipboard. Built on `NSColorSampler`, so the loupe, multi-display handling,
/// and pixel sampling all come from the system — no screen-recording grant of
/// our own is required, and it Just Works across Retina/HDR displays.
@MainActor
enum ColorPicker {
    struct Picked {
        let hex: String   // "#RRGGBB"
        let rgb: String   // "rgb(r, g, b)"
    }

    /// Show the loupe. `completion` fires with the picked color, or nil if the
    /// user cancelled (Esc / click away). Called on the main thread.
    static func pick(_ completion: @escaping (Picked?) -> Void) {
        NSColorSampler().show { color in
            // sRGB conversion is what makes the hex match what design tools show;
            // a raw device/display-P3 color would read a few points off.
            guard let color, let srgb = color.usingColorSpace(.sRGB) else {
                completion(nil); return
            }
            let r = Int((srgb.redComponent * 255).rounded())
            let g = Int((srgb.greenComponent * 255).rounded())
            let b = Int((srgb.blueComponent * 255).rounded())
            let hex = String(format: "#%02X%02X%02X", r, g, b)
            completion(Picked(hex: hex, rgb: "rgb(\(r), \(g), \(b))"))
        }
    }
}
