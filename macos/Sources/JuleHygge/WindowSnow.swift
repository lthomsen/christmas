import AppKit

/// Snow on the top edge of other apps' windows (not fullscreen ones). Some of the falling flakes land there;
/// when the window disappears (minimized, closed, hidden, another Space) the snow falls down as clumps
/// and lands in the pile at the bottom. All in global coordinates (origin top-left of the primary screen, y down),
/// like `ScreenOverlay.screenBounds`, so a window that spans two screens carries one pile.
final class Ledge {
    static let step: F = 4
    let id: Int
    var rect: CGRect
    /// Where the window last stood still. The snow sits there: while a window moves (or shrinks into the Dock
    /// when minimized) the pile stays put, and if the window goes away, the snow falls from this spot.
    var settled: CGRect
    /// Snow height per `step` points from the window's left edge.
    var cols: [F]
    /// Parts of the top edge (global x) not covered by a window in front.
    var visible: [(F, F)] = []
    /// True while the window is being moved or resized: the pile is hidden and catches nothing until it settles.
    var moving = false
    /// Bumped whenever the drawn shape changes, so each overlay only rebuilds its path when needed.
    var version = 0
    var hasSnow = false

    init(id: Int, rect: CGRect) {
        self.id = id; self.rect = rect; self.settled = rect
        cols = Array(repeating: 0, count: Int(rect.width / Ledge.step) + 1)
    }

    func isVisible(_ x: F) -> Bool { visible.contains { x >= $0.0 && x <= $0.1 } }

    func height(at x: F) -> F {
        let i = Int((x - settled.minX) / Ledge.step)
        return i >= 0 && i < cols.count ? cols[i] : 0
    }

    func deposit(at x: F, r: F) {
        let i = Int((x - settled.minX) / Ledge.step)
        let amount = 0.3 * r
        for k in -1...1 where i + k >= 0 && i + k < cols.count { cols[i + k] += k == 0 ? amount : amount * 0.5 }
        hasSnow = true
        version += 1
    }

    /// Keeps the width in step with the window, keeping the snow that is still on it.
    func resize(to width: F) {
        let n = Int(width / Ledge.step) + 1
        if n < cols.count { cols.removeLast(cols.count - n) } else if n > cols.count { cols += Array(repeating: 0, count: n - cols.count) }
    }
}

/// A lump of snow falling off a window that went away; the overlay below catches it in its ground pile.
final class SnowClump {
    var x: F = 0, y: F = 0, vx: F = 0, vy: F = 0, r: F = 0
    var dead = false
}

extension Controller {
    /// Windows that can carry snow, front to back, plus the windows that cover a whole screen.
    static func scanWindows() -> (ledges: [(id: Int, rect: CGRect)], fullscreen: [CGRect]) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return ([], []) }
        let me = ProcessInfo.processInfo.processIdentifier
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        var ledges: [(Int, CGRect)] = [], full: [CGRect] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { continue }
            if screens.contains(where: { abs($0.minX - r.minX) < 2 && abs($0.minY - r.minY) < 2 && abs($0.width - r.width) < 2 && abs($0.height - r.height) < 2 }) {
                full.append(r)
                continue
            }
            // ordinary, visible windows of a reasonable size whose top edge is on a screen
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0.5, r.width >= 150, r.height >= 80, let id = w[kCGWindowNumber as String] as? Int,
                  screens.contains(where: { $0.contains(CGPoint(x: r.midX, y: r.minY + 1)) }) else { continue }
            ledges.append((id, r))
        }
        return (ledges, full)
    }

    /// Matches the scanned windows with the existing ledges: windows that moved hide their snow until they settle,
    /// and windows that are gone let their snow fall.
    func updateLedges(_ wins: [(id: Int, rect: CGRect)]) {
        var seen = Set<Int>()
        let pileRoom: F = 16   // a window in front just above the edge still hides the snow
        for (i, w) in wins.enumerated() {
            seen.insert(w.id)
            let y = w.rect.minY
            var vis: [(F, F)] = [(w.rect.minX + 6, w.rect.maxX - 6)]   // rounded corners
            for f in wins[..<i] where f.rect.minY < y + 1 && f.rect.maxY > y - pileRoom {
                vis = vis.flatMap { seg -> [(F, F)] in
                    if f.rect.maxX <= seg.0 || f.rect.minX >= seg.1 { return [seg] }
                    var out: [(F, F)] = []
                    if f.rect.minX > seg.0 { out.append((seg.0, f.rect.minX)) }
                    if f.rect.maxX < seg.1 { out.append((f.rect.maxX, seg.1)) }
                    return out
                }
            }
            vis = vis.filter { $0.1 - $0.0 >= 8 }
            if let l = ledges[w.id] {
                if l.rect != w.rect {
                    l.rect = w.rect
                    if !l.moving { l.moving = true; l.version += 1 }
                } else if l.moving {
                    // came to rest: the snow moves along (and keeps what still fits on a resized window)
                    if l.settled.width != l.rect.width { l.resize(to: l.rect.width) }
                    l.settled = l.rect
                    l.moving = false; l.version += 1
                }
                if l.visible.count != vis.count || zip(l.visible, vis).contains(where: { $0.0 != $1.0 || $0.1 != $1.1 }) {
                    l.visible = vis; l.version += 1
                }
            } else {
                let l = Ledge(id: w.id, rect: w.rect)
                l.visible = vis
                ledges[w.id] = l
            }
        }
        for (id, l) in ledges where !seen.contains(id) {
            if l.hasSnow { dropSnow(from: l) }
            ledges[id] = nil
        }
        ledgeList = Array(ledges.values)
    }

    /// The window went away: its snow falls as clumps.
    private func dropSnow(from l: Ledge) {
        for (i, h) in l.cols.enumerated() where h > 0.5 {
            let n = min(4, Int(h / 2.5) + 1)
            for _ in 0..<n where clumps.count < 700 {
                let c = SnowClump()
                // straight down from where the window stood, only a little spread
                c.x = l.settled.minX + F(i) * Ledge.step + R() * Ledge.step
                c.y = l.settled.minY - R() * h
                c.vx = (R() - 0.5) * 6
                c.vy = R() * 20
                c.r = 1.6 + R() * 1.8
                clumps.append(c)
            }
        }
        ErrorLog.debug("window \(l.id) gone: \(clumps.count) clumps falling")
    }

    /// Settles each pile (slopes, rounded ends, no higher than ~10 pt), melts it when snow is off,
    /// and moves the falling clumps.
    func updateWindowSnow(_ dt: F) {
        let melt = !snowOn || !cfg.windowSnow
        if ProcessInfo.processInfo.environment["JULE_DEBUG"] == "1", Int(time / 5) != Int((time - Double(dt)) / 5) {
            ErrorLog.debug("ledges: " + ledgeList.map { "\($0.id) \(Int($0.settled.minX)),\(Int($0.settled.minY)) w\(Int($0.settled.width)) vis\($0.visible.count) mov\($0.moving) max\(String(format: "%.1f", $0.cols.max() ?? 0))" }.joined(separator: " | "))
        }
        let maxH: F = 10, slope: F = 1.4
        for l in ledgeList where l.hasSnow {
            var any = false
            let n = l.cols.count
            for i in 0..<(n - 1) {
                let d = l.cols[i] - l.cols[i + 1]
                if d > slope { let m = (d - slope) * 0.3; l.cols[i] -= m; l.cols[i + 1] += m }
                else if d < -slope { let m = (-d - slope) * 0.3; l.cols[i] += m; l.cols[i + 1] -= m }
            }
            for i in 0..<n {
                let edge = F(min(i, n - 1 - i)) * Ledge.step
                let cap = min(maxH, max(0, edge - 6) * 0.5)   // snow rounds off toward the window's corners
                if melt { l.cols[i] = max(0, l.cols[i] - 3 * dt) }
                if l.cols[i] > cap { l.cols[i] = cap }
                if l.cols[i] > 0.3 { any = true }
            }
            if melt || !any { l.version += 1 }
            l.hasSnow = any
        }
        if !clumps.isEmpty {
            for c in clumps {
                c.vy += 700 * dt
                c.x += c.vx * dt
                c.y += c.vy * dt
                if c.y > 100_000 { c.dead = true }
            }
            let bottom = overlays.filter { !$0.isVirtual }.map { $0.screenBounds.maxY }.max() ?? 0
            clumps.removeAll { $0.dead || $0.y > bottom + 50 }
        }
    }
}
