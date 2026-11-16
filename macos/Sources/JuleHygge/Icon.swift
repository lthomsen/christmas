import AppKit

/// The snowflake icon, same design as the Windows tray icon.
enum AppIcon {
    /// Draws the icon in a 32×32 design space scaled to `size` (y-down context).
    static func draw(_ g: CGContext, size: F, background: Bool, color: CGColor = C(255, 255, 255)) {
        let k = size / 32
        if background {
            let rect = CGRect(x: 1 * k, y: 1 * k, width: 30 * k, height: 30 * k)
            g.fillGradient(CGPath(ellipseIn: rect, transform: nil), C(225, 45, 55), C(160, 15, 25),
                           from: CGPoint(x: 0, y: rect.minY), to: CGPoint(x: 0, y: rect.maxY))
        }
        let c = 16 * k, w = max(1.2, 2.2 * k)
        for i in 0..<3 {
            let a = F(i) * .pi / 3 + .pi / 2
            let dx = cos(a) * 11 * k, dy = sin(a) * 11 * k
            g.line(color, w, c - dx, c - dy, c + dx, c + dy, round: true)
            if size < 15 { continue }   // branches are just noise at tiny sizes
            for sgn in [-1.0, 1.0] as [F] {
                let ex = c + sgn * dx * 0.65, ey = c + sgn * dy * 0.65
                let a1 = a + (sgn > 0 ? 0 : .pi)
                for side in [-1.0, 1.0] as [F] {
                    let ba = a1 + side * 2.4
                    g.line(color, w, ex, ey, ex + cos(ba) * 4 * k, ey + sin(ba) * 4 * k, round: true)
                }
            }
        }
    }

    static func image(size: F, background: Bool, scale: F = 2) -> NSImage? {
        guard let cg = renderImage(width: size, height: size, scale: scale, { draw($0, size: size, background: background) }) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }

    /// Template image for the menu bar (black on transparent; macOS tints it).
    static var menuBarImage: NSImage? {
        let s: F = 18
        guard let cg = renderImage(width: s, height: s, scale: 2, { g in
            g.translateBy(x: -1.5, y: -1.5); g.scaleBy(x: 21 / 18, y: 21 / 18)
            draw(g, size: s, background: false, color: C(0, 0, 0))
        }) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: s, height: s))
        img.isTemplate = true
        return img
    }

    /// Writes an .iconset folder (used by build.sh, which turns it into the app's .icns).
    static func writeIconset(to dir: String) {
        for base in [16, 32, 128, 256, 512] {
            for mul in [1, 2] {
                let px = base * mul
                guard let cg = renderImage(width: F(px), height: F(px), scale: 1, { draw($0, size: F(px), background: true) }) else { continue }
                let name = mul == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }
}
