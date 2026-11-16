import AppKit
import QuartzCore

/// A small layer whose content is redrawn by a closure. The closure draws in the screen's own
/// coordinates (origin top-left, y down), like the GDI+ code in the Windows version.
final class Sprite: NSObject, CALayerDelegate {
    let layer = CALayer()
    private(set) var rect = CGRect.zero
    private let screenHeight: F
    let painter: (CGContext) -> Void

    init(parent: CALayer, screenHeight: F, scale: F, painter: @escaping (CGContext) -> Void) {
        self.screenHeight = screenHeight
        self.painter = painter
        super.init()
        layer.delegate = self
        layer.contentsScale = scale
        layer.contentsGravity = .topLeft
        layer.isHidden = true
        parent.addSublayer(layer)
    }

    /// Moves the sprite to `r` (screen coordinates, y down) and optionally redraws it.
    func place(_ r: CGRect, redraw: Bool = true) {
        // Origin is rounded and size kept stable, so moving the layer without a redraw never rescales its content.
        let r = CGRect(x: floor(r.minX), y: floor(r.minY), width: ceil(r.width) + 1, height: ceil(r.height) + 1)
        if r != rect {
            rect = r
            layer.frame = CGRect(x: r.minX, y: screenHeight - r.maxY, width: r.width, height: r.height)
        }
        layer.isHidden = false
        if redraw { layer.setNeedsDisplay() }
    }

    func hide() { layer.isHidden = true }

    func draw(_ layer: CALayer, in ctx: CGContext) {
        ctx.translateBy(x: 0, y: layer.bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        painter(ctx)
    }

    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

/// A pool of image layers (snowflakes, sparks, snow chunks) reused from frame to frame.
final class DotPool {
    private let parent = CALayer()
    private var layers: [CALayer] = []
    private var used = 0
    private let screenHeight: F

    init(in root: CALayer, screenHeight: F) {
        self.screenHeight = screenHeight
        parent.frame = root.bounds
        root.addSublayer(parent)
    }

    func begin() { used = 0 }

    /// Places one image centered at (x, y) in screen coordinates (y down).
    func add(_ image: CGImage, x: F, y: F, w: F, h: F, opacity: F, rotation: F = 0) {
        let l: CALayer
        if used < layers.count { l = layers[used] } else {
            l = CALayer()
            l.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "transform": NSNull(),
                         "contents": NSNull(), "hidden": NSNull()]
            parent.addSublayer(l)
            layers.append(l)
        }
        used += 1
        if l.contents == nil || (l.contents as! CGImage) !== image { l.contents = image }
        l.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        l.position = CGPoint(x: x, y: screenHeight - y)
        l.opacity = Float(opacity)
        l.setAffineTransform(rotation == 0 ? .identity : CGAffineTransform(rotationAngle: -rotation))
        l.isHidden = false
    }

    func end() {
        var i = used
        while i < layers.count {
            if !layers[i].isHidden { layers[i].isHidden = true }
            i += 1
        }
    }
}

/// Pre-rendered images for the pooled layers (drawn once per screen scale).
final class DotImages {
    let flake, crystal, goldDot, whiteDot, goldGlint, whiteGlint, goldStar, whiteStar, smoke, chunk: CGImage

    init(scale: F) {
        let s: F = 64, m: F = 32
        func img(_ d: (CGContext) -> Void) -> CGImage { renderImage(width: s, height: s, scale: scale / 4, d)! }
        flake = img { $0.fillEllipse(C(255, 255, 255), 0, 0, s, s) }
        crystal = img { g in
            for k in 0..<3 {
                let a = F(k) * 1.0472, dx = cos(a) * m, dy = sin(a) * m
                g.line(C(255, 255, 255), 5, m - dx, m - dy, m + dx, m + dy, round: true)
            }
        }
        goldDot = img { $0.fillEllipse(C(255, 220, 120), 0, 0, s, s) }
        whiteDot = flake
        func glint(_ c: CGColor) -> CGImage {
            img { g in
                g.fillEllipse(c, m - 10, m - 10, 20, 20)
                g.line(c, 2.2, m - 30, m, m + 30, m); g.line(c, 2.2, m, m - 30, m, m + 30)
            }
        }
        goldGlint = glint(C(255, 220, 120)); whiteGlint = glint(C(255, 255, 255))
        goldStar = img { $0.fillPoly(C(255, 220, 120), starPoints(m, m, m, m * 0.45)) }
        whiteStar = img { $0.fillPoly(C(255, 255, 255), starPoints(m, m, m, m * 0.45)) }
        smoke = img { $0.fillEllipse(C(120, 120, 125), 0, 0, s, s) }
        chunk = img { $0.fillEllipse(C(250, 252, 255), 0, 0, s, s) }
    }
}

/// Ét gennemsigtigt, klik-igennem overlay-vindue for én skærm.
final class ScreenOverlay {
    unowned let c: Controller
    var cfg: Settings { c.cfg }
    let window: NSWindow
    let root: CALayer
    let isPrimary: Bool
    /// The screen in global coordinates with origin top-left of the primary screen, y down.
    let screenBounds: CGRect
    let S: F
    private(set) var snowmanPos: CGPoint?
    let W: F, H: F
    private let groundY: F
    private let lightsTop: F
    private let images: DotImages

    private var flakes: [Flake] = []
    private var heap: [F]
    private let heapStep: F = 4
    private var nisser: [Nisse] = []
    /// How many nisser more or fewer than the chosen number are around right now (−2…+2).
    private var nisseOffset = 0
    private var nisseChangeTimer: F = F(Double(ProcessInfo.processInfo.environment["JULE_NISSE_SECONDS"] ?? "") ?? Double(90 + R() * 90))
    private var nisseLayers: [CALayer] = []
    /// Pre-rendered poses, shared by every nisse with the same clothes: key = variant + state + frame.
    private var nisseFrames: [String: CGImage] = [:]
    private var paused = false, lastPowerSave = false
    private var frameNo = 0
    private var groundTimer: F = 0

    // layers, in drawing order (back to front)
    private var lightsSprite: Sprite!, santaSprite: Sprite!, snowmanSprite: Sprite!, plowSprite: Sprite!
    private var sparkPool: DotPool!
    private let groundFill = CAShapeLayer(), groundLine = CAShapeLayer()
    private let nisseLayer = CALayer()
    private var plowBitPool: DotPool!
    private var flakePool: DotPool!
    private var bulbLayers: [(layer: CALayer, omega: Double, phase: Double)] = []
    private let lightsLayer = CALayer()
    private var bulbsBuilt = false
    private var snowmanKey = ""

    private var PS: Bool { c.powerSave }
    /// Top of the snow band used in power-save mode (snow falls only between here and the bottom).
    private var bandTop: F { max(0, groundY - H * 0.32) }
    private var lightsHeight: F { 70 * S }

    static let santaRed = C(205, 25, 35), gold = C(235, 195, 70), skin = C(255, 214, 186),
        deer = C(145, 95, 55), deerDark = C(100, 62, 32), hatRed = C(210, 30, 40)

    init(controller: Controller, screen: NSScreen) {
        c = controller
        let frame = screen.frame
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        screenBounds = CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
        W = frame.width; H = frame.height
        isPrimary = frame.origin == .zero
        groundY = H
        // The lights hang just below the menu bar.
        lightsTop = max(0, frame.maxY - screen.visibleFrame.maxY)
        S = max(0.6, H / 1080)
        let scale = screen.backingScaleFactor
        images = DotImages(scale: scale)
        // JULE_DEEPSNOW=1 starts with a full snow pile (to test the plow throwing snow).
        heap = Array(repeating: ProcessInfo.processInfo.environment["JULE_DEEPSNOW"] != nil ? 18 * max(0.6, frame.height / 1080) : 0, count: Int(W / heapStep) + 2)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar   // over the Dock
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.title = "JuleHygge"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        view.wantsLayer = true
        window.contentView = view
        window.setFrame(frame, display: false)
        root = view.layer!

        let h = H
        lightsSprite = Sprite(parent: root, screenHeight: h, scale: scale) { [unowned self] g in self.renderLights(g) }
        lightsLayer.frame = root.bounds
        lightsLayer.isHidden = true
        root.addSublayer(lightsLayer)
        sparkPool = DotPool(in: root, screenHeight: h)
        santaSprite = Sprite(parent: root, screenHeight: h, scale: scale) { [unowned self] g in self.drawSanta(g) }
        snowmanSprite = Sprite(parent: root, screenHeight: h, scale: scale) { [unowned self] g in self.drawSnowman(g) }
        for l in [groundFill, groundLine] {
            l.frame = root.bounds
            l.actions = ["path": NSNull(), "hidden": NSNull()]
            root.addSublayer(l)
        }
        groundFill.fillColor = C(248, 252, 255, 245)
        groundLine.fillColor = nil
        groundLine.strokeColor = C(170, 200, 230, 110)
        groundLine.lineWidth = 1.5 * S
        nisseLayer.frame = root.bounds
        root.addSublayer(nisseLayer)
        plowBitPool = DotPool(in: root, screenHeight: h)
        plowSprite = Sprite(parent: root, screenHeight: h, scale: scale) { [unowned self] g in self.drawPlow(g) }
        flakePool = DotPool(in: root, screenHeight: h)

        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil); window.close() }

    func keepOnTop() { if !paused { window.orderFrontRegardless() } }

    // ------------------------------------------------------------------ én frame
    func frame(_ dt: F) {
        let fullscreen = c.fullscreenRects.contains { abs($0.minX - screenBounds.minX) < 2 && abs($0.minY - screenBounds.minY) < 2 &&
            abs($0.width - screenBounds.width) < 2 && abs($0.height - screenBounds.height) < 2 }
        if fullscreen && cfg.pauseFullscreen {
            if !paused { paused = true; root.isHidden = true }
            return
        }
        if paused { paused = false; root.isHidden = false }
        if PS != lastPowerSave { lastPowerSave = PS; flakes.removeAll() }
        frameNo += 1

        updateSnow(dt)
        updatePlow(dt)
        updateNisser(dt)

        renderLightsLayer()
        renderSparks()
        renderSanta()
        renderSnowman()
        groundTimer -= dt
        if groundTimer <= 0 { groundTimer = 0.2; renderGround() }   // the pile changes slowly
        renderNisser()
        renderPlow()
        renderSnow()
    }

    // ------------------------------------------------------------------ sne
    private func updateSnow(_ dt: F) {
        let baseCount = [110, 260, 650]
        let logicalArea = W * H
        // In power-save mode snow only covers the band at the bottom, at a slightly higher density.
        let areaShare: F = PS ? (groundY - bandTop) / H * 1.3 : 1
        let target = c.snowOn ? Int(F(baseCount[c.effectiveSnowLevel]) * min(2, logicalArea / (1920 * 1080)) * areaShare * c.snowIntensity) : 0
        // new flakes come in from the top; surplus flakes disappear only when they land
        let add = flakes.isEmpty ? target : max(1, target / 60)
        var i = 0
        while i < add && flakes.count < target { flakes.append(newFlake(anywhere: flakes.isEmpty || c.time < 1)); i += 1 }

        let wind = c.wind * S
        let t = c.time
        var k = flakes.count - 1
        while k >= 0 {
            let f = flakes[k]
            f.y += f.vy * dt
            f.x += (wind * (0.4 + f.r / (4 * S)) + F(cos(t * Double(f.swaySpd) + Double(f.phase))) * f.sway) * dt
            f.rot += f.rotSpd * dt
            if f.x < -60 { f.x += W + 120 } else if f.x > W + 60 { f.x -= W + 120 }
            if f.y >= groundY - heapAt(f.x) {
                if cfg.snowGround { deposit(f.x, f.r) }
                if flakes.count > target { flakes.remove(at: k) } else { flakes[k] = newFlake(anywhere: false) }
            }
            k -= 1
        }

        let maxH = 18 * S, slope = 1.2 * S
        for i in 0..<(heap.count - 1) {
            let d = heap[i] - heap[i + 1]
            if d > slope { let m = (d - slope) * 0.3; heap[i] -= m; heap[i + 1] += m }
            else if d < -slope { let m = (-d - slope) * 0.3; heap[i] += m; heap[i + 1] -= m }
        }
        let melt = !c.snowOn || !cfg.snowGround
        for i in 0..<heap.count {
            if melt { heap[i] = max(0, heap[i] - 3 * S * dt) }
            if heap[i] > maxH { heap[i] = maxH }
        }
    }

    private func newFlake(anywhere: Bool) -> Flake {
        let f = Flake()
        let depth = R()
        f.r = (1 + depth * depth * 3.5) * S
        f.vy = (25 + depth * 55 + R() * 15) * S * (c.effectiveSnowLevel == 2 ? 1.5 : 1)
        f.x = -50 + R() * (W + 100)
        let top = PS ? bandTop : 0
        f.y = anywhere ? top + R() * (groundY - top) : top - 10 - R() * 60
        f.phase = R() * 6.28
        f.sway = (8 + R() * 20) * S
        f.swaySpd = 0.5 + R() * 1.2
        f.a = Int(110 + depth * 145)
        f.crystal = depth > 0.8 && R() < 0.5
        if f.crystal { f.r *= 1.6 }
        f.rot = R() * 6.28
        f.rotSpd = (R() - 0.5) * 2
        return f
    }


    private func renderSnow() {
        flakePool.begin()
        // In power-save mode flakes fade in over the top of the snow band instead of popping into view.
        let top: F = PS ? bandTop : -1000, fadeLen = 90 * S
        for f in flakes {
            if f.y < -f.r * 2 || f.y < top { continue }
            let a = PS ? F(f.a) * min(1, (f.y - top) / fadeLen) : F(f.a)
            if a <= 0 { continue }
            if f.crystal {
                if a < 60 { continue }
                flakePool.add(images.crystal, x: f.x, y: f.y, w: f.r * 2, h: f.r * 2, opacity: a / 255, rotation: f.rot)
            } else {
                // GDI version draws a dot of radius r plus half a pixel of anti-aliasing
                flakePool.add(images.flake, x: f.x, y: f.y, w: f.r * 2 + 0.5, h: f.r * 2 + 0.5, opacity: a / 255)
            }
        }
        flakePool.end()
    }


    private func deposit(_ x: F, _ r: F) {
        let idx = Int(x / heapStep)
        let amount = 0.35 * r
        for k in -1...1 {
            let j = idx + k
            if j >= 0 && j < heap.count { heap[j] += k == 0 ? amount : amount * 0.5 }
        }
    }

    private func heapAt(_ x: F) -> F {
        let fx = x / heapStep
        let i = Int(floor(fx))
        if i < 0 { return heap[0] }
        if i >= heap.count - 1 { return heap[heap.count - 1] }
        let t = fx - F(i)
        return heap[i] * (1 - t) + heap[i + 1] * t
    }

    private var groundShown = false
    private func renderGround() {
        let mx = heap.max() ?? 0
        if mx < 0.5 {
            if groundShown { groundFill.isHidden = true; groundLine.isHidden = true; groundShown = false }
            return
        }
        // Shape layers use the layer's y-up coordinates: y' = H - y.
        let fill = CGMutablePath(), line = CGMutablePath()
        fill.move(to: CGPoint(x: 0, y: H - groundY - 1))
        for i in 0..<heap.count {
            let p = CGPoint(x: F(i) * heapStep, y: H - (groundY - heap[i]))
            fill.addLine(to: p)
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        fill.addLine(to: CGPoint(x: W, y: H - groundY - 1))
        fill.closeSubpath()
        groundFill.path = fill
        groundLine.path = line
        if !groundShown { groundFill.isHidden = false; groundLine.isHidden = false; groundShown = true }
    }

    // ------------------------------------------------------------------ julemanden og gnister
    private func renderSparks() {
        let ox = screenBounds.minX, oy = screenBounds.minY
        sparkPool.begin()
        for sp in c.sparks {
            let x = sp.x - ox, y = sp.y - oy
            if x < -20 || y < -20 || x > W + 20 || y > H + 20 { continue }
            let life = sp.star ? min(1, sp.life) : sp.life / sp.max
            if sp.star {
                sparkPool.add(sp.gold ? images.goldStar : images.whiteStar, x: x, y: y, w: sp.size * 2, h: sp.size * 2,
                              opacity: life, rotation: sp.life)
            } else if sp.size > 3.5 * S {
                sparkPool.add(sp.gold ? images.goldGlint : images.whiteGlint, x: x, y: y, w: sp.size * 3.2, h: sp.size * 3.2, opacity: life)
            } else {
                sparkPool.add(sp.gold ? images.goldDot : images.whiteDot, x: x, y: y, w: sp.size, h: sp.size, opacity: life)
            }
        }
        sparkPool.end()
    }

    private func renderSanta() {
        guard c.santaActive else { santaSprite.hide(); return }
        let sc = c.santaScale * 1.1
        let sx = c.santaX - screenBounds.minX, sy = c.santaY - screenBounds.minY
        if sx < -330 * sc || sx > W + 330 * sc || sy < -150 * sc || sy > H + 150 * sc { santaSprite.hide(); return }
        santaSprite.place(CGRect(x: sx - 330 * sc, y: sy - 135 * sc, width: 660 * sc, height: 195 * sc), redraw: frameNo % 2 == 0 || santaSprite.layer.isHidden)   // moves every frame, limbs at half rate
    }

    private func drawSanta(_ g: CGContext) {
        let sc = c.santaScale * 1.1
        let sx = c.santaX - screenBounds.minX, sy = c.santaY - screenBounds.minY
        g.translateBy(x: sx, y: sy)
        g.scaleBy(x: c.santaDir * sc, y: sc)
        g.rotate(by: cos(c.santaPhase * 0.9) * -4 * c.santaDir * .pi / 180)
        let t = c.santaPhase

        let rx: [F] = [80, 140, 200, 260]
        let ry = (0..<4).map { i in -40 + sin(t * 6 + F(i) * 0.8) * 3 }
        for i in 0..<4 { g.line(C(120, 60, 30), 1.4, -14, -44, rx[i] + 4, ry[i] - 6) }
        for i in 0..<4 { drawReindeer(g, rx[i], ry[i], F(i) * 0.8, i == 3, t) }

        let red = Self.santaRed, white = C(255, 255, 255), black = C(30, 30, 30)
        g.fillEllipse(C(150, 110, 60), -92, -66, 36, 40)
        g.fillRect(C(40, 140, 70), -84, -74, 12, 12)
        g.fillRect(C(60, 100, 200), -72, -70, 10, 9)
        g.fillRect(Self.gold, -79, -74, 2, 12)

        g.fillEllipse(red, -52, -58, 32, 42)
        g.line(red, 7, -32, -48, -16, -44, round: true)
        g.fillEllipse(black, -19, -48, 8, 8)
        g.fillEllipse(Self.skin, -45, -76, 19, 19)
        g.fillEllipse(white, -42, -68, 18, 20)
        g.fillEllipse(white, -31, -70, 9, 5)
        g.fillEllipse(C(240, 150, 140), -28, -71, 5, 5)
        g.fillEllipse(black, -32, -74, 2.6, 2.6)
        g.fillPoly(red, [(-47, -72), (-25, -74), (-40, -90), (-56, -86)])
        g.fillRect(white, -48, -76, 25, 5)
        g.fillEllipse(white, -61, -91, 9, 9)

        let path = CGMutablePath()
        path.start(-82, -46)
        path.curve(-70, -36, -78, -4, -60, 2)
        path.to(12, 2)
        path.curve(26, 2, 30, -18, 40, -22)
        path.to(34, -27)
        path.curve(22, -16, 0, -21, -48, -23)
        path.to(-72, -48)
        path.closeSubpath()
        g.fillGradient(path, C(200, 30, 40), C(120, 10, 20), from: CGPoint(x: 0, y: -46), to: CGPoint(x: 0, y: 4))
        g.stroke(Self.gold, 2, path)

        let gold = Self.gold
        g.line(gold, 3, -55, 2, -55, 12, round: true)
        g.line(gold, 3, 5, 2, 5, 12, round: true)
        g.line(gold, 3, -72, 12, 22, 12, round: true)
        g.bezier(gold, 3, 22, 12, 36, 12, 38, -2, 28, -4)
        g.bezier(gold, 3, -72, 12, -80, 12, -80, 4, -74, 4)
    }

    private func drawReindeer(_ g: CGContext, _ x: F, _ y: F, _ phase: F, _ rudolph: Bool, _ t: F) {
        let gal = t * 9 + phase
        func leg(_ col: CGColor, _ w: F, _ hx: F, _ hy: F, _ a: F) {
            g.line(col, w, hx, hy, hx + sin(a) * 15, hy + cos(a) * 15, round: true)
        }
        let far = C(85, 52, 28)
        leg(far, 3.2, x + 9, y + 4, sin(gal + 0.6) * 0.8 + 0.5)
        leg(far, 3.2, x - 9, y + 4, sin(gal + .pi + 0.6) * 0.8 - 0.4)
        leg(Self.deerDark, 3.6, x + 14, y + 4, sin(gal) * 0.8 + 0.5)
        leg(Self.deerDark, 3.6, x - 14, y + 4, sin(gal + .pi) * 0.8 - 0.4)

        g.fillEllipse(C(255, 255, 255), x - 27, y - 9, 8, 7)
        g.fillEllipse(Self.deer, x - 22, y - 10, 44, 20)
        g.fillEllipse(C(200, 160, 110), x - 14, y - 1, 28, 8)
        g.fillPoly(Self.deer, [(x + 10, y - 6), (x + 18, y - 25), (x + 26, y - 22), (x + 21, y + 2)])
        g.fillEllipse(Self.deer, x + 16, y - 32, 16, 11)
        g.fillEllipse(Self.deer, x + 26, y - 29, 11, 8)
        g.fillEllipse(Self.deerDark, x + 14, y - 33, 7, 4)
        g.fillEllipse(C(0, 0, 0), x + 23, y - 30, 2.5, 2.5)

        let ant = C(205, 175, 125)
        g.line(ant, 2, x + 20, y - 31, x + 16, y - 45, round: true)
        g.line(ant, 2, x + 17, y - 41, x + 11, y - 45, round: true)
        g.line(ant, 2, x + 16, y - 45, x + 20, y - 51, round: true)
        g.line(ant, 2, x + 23, y - 31, x + 27, y - 45, round: true)
        g.line(ant, 2, x + 26, y - 41, x + 32, y - 44, round: true)
        g.line(C(190, 20, 30), 3, x + 8, y - 9, x + 5, y + 9)
        g.fillEllipse(Self.gold, x + 3, y + 5, 4.5, 4.5)

        if rudolph {
            let a = Int(90 + 70 * sin(t * 6))
            g.fillEllipse(C(255, 60, 50, a), x + 30, y - 33, 15, 15)
            g.fillEllipse(C(240, 30, 30), x + 34, y - 29, 7, 7)
        } else {
            g.fillEllipse(C(40, 25, 15), x + 35, y - 27, 4, 4)
        }
    }

    // ------------------------------------------------------------------ snemand (bygges lidt mere hver dag)
    private func renderSnowman() {
        guard isPrimary && cfg.snowman else { snowmanPos = nil; snowmanSprite.hide(); return }
        let x = W * 0.78, y = groundY - heapAt(W * 0.78) + 3 * S
        snowmanPos = CGPoint(x: screenBounds.minX + x, y: screenBounds.minY + y)
        let key = "\(c.snowmanStage) \(Int(y))"
        let r = CGRect(x: x - 62 * S, y: y - 135 * S, width: 124 * S, height: 142 * S)
        snowmanSprite.place(r, redraw: key != snowmanKey)
        snowmanKey = key
    }

    private func drawSnowman(_ g: CGContext) {
        let stage = c.snowmanStage
        let x = W * 0.78, y = groundY - heapAt(x) + 3 * S
        g.translateBy(x: x, y: y)
        g.scaleBy(x: S, y: S)

        g.fillEllipse(C(60, 80, 110, 50), -30, -3, 60, 6)
        let wood = C(110, 70, 35)
        if stage >= 12 {
            g.line(wood, 2.6, 32, -6, 46, -104, round: true)
            g.fillPoly(C(215, 175, 90), [(24, 6), (42, 6), (37, -14), (31, -14)])
            g.line(C(170, 30, 30), 2, 30, -11, 38, -11)
        }
        if stage >= 8 {
            g.line(wood, 2.6, -15, -66, -40, -84, round: true)
            g.line(wood, 2.6, -33, -79, -37, -91, round: true)
            g.line(wood, 2.6, -33, -79, -44, -78, round: true)
            g.line(wood, 2.6, 15, -66, 40, -80, round: true)
            g.line(wood, 2.6, 33, -76, 39, -88, round: true)
        }

        func ball(_ cx: F, _ cy: F, _ r: F) {
            let rc = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
            let p = CGPath(ellipseIn: rc, transform: nil)
            g.fillGradient(p, C(255, 255, 255), C(200, 216, 238), from: CGPoint(x: rc.minX + r * 0.4, y: rc.minY), to: CGPoint(x: rc.maxX - r * 0.4, y: rc.maxY))
            g.stroke(C(140, 165, 200, 70), 1, p)
        }
        if stage == 1 { ball(0, -11, 11) } else { ball(0, -24, 25) }
        if stage >= 3 { ball(0, -62, 18) }
        if stage >= 4 { ball(0, -92, 13) }

        let coal = C(35, 35, 40)
        if stage >= 7 { for i in 0..<3 { g.fillEllipse(coal, -2.4, -72.4 + F(i) * 9, 4.8, 4.8) } }
        if stage >= 10 {
            let scarf = C(200, 30, 40)
            g.fillRect(scarf, -13, -82, 26, 6)
            g.fillPoly(scarf, [(5, -78), (12, -78), (15, -57), (8, -57)])
            g.line(C(255, 255, 255), 1.5, 9, -66, 14, -66)
            g.line(C(255, 255, 255), 1.5, 10, -61, 15, -61)
        }
        if stage >= 5 {
            g.fillEllipse(coal, -6.5, -98, 4, 4)
            g.fillEllipse(coal, 2.5, -98, 4, 4)
        }
        if stage >= 6 { g.fillPoly(C(240, 130, 30), [(0, -93), (19, -89.5), (0, -87)]) }
        if stage >= 9 {
            for i in -2...2 {
                let sx = F(i) * 3, sy = -86 + 2 * (1 - (sx / 6) * (sx / 6)) + 1
                g.fillEllipse(coal, sx - 1.1, sy - 1.1, 2.2, 2.2)
            }
        }
        if stage >= 11 {
            g.fillRect(coal, -15, -106, 30, 4)
            g.fillRect(coal, -10, -127, 20, 22)
            g.fillRect(C(200, 30, 40), -10, -110, 20, 4)
        }
        if stage >= 12 {
            g.fillRect(C(40, 140, 70), -50, -13, 15, 13)
            g.line(Self.gold, 1.8, -42.5, -13, -42.5, 0)
            g.line(Self.gold, 1.8, -50, -6.5, -35, -6.5)
            g.strokeEllipse(Self.gold, 1.8, -46, -17, 3.5, 3.5)
            g.strokeEllipse(Self.gold, 1.8, -42.5, -17, 3.5, 3.5)
        }
    }

    // ------------------------------------------------------------------ sneplov
    // An orange plow truck clears the snow when it gets high, alternating direction each run.
    // Snow it scrapes up builds a growing pile in front of the blade and is thrown up as chunks.
    private var plowBits: [PlowBit] = []
    private var plowSmokeTimer: F = 0, plowChunkAcc: F = 0
    private let plowScale: F = 1.15

    // The truck itself is driven by the Controller in global coordinates, so one plow drives continuously
    // across neighbouring screens. These read its state in this screen's coordinates.
    private var plowActive: Bool { c.plow.active && c.plow.members.contains(ObjectIdentifier(self)) }
    private var plowX: F { c.plow.gx - screenBounds.minX }
    private var plowDir: F { c.plow.dir }
    private var plowWheel: F { c.plow.wheel }
    private var plowOnScreen: Bool { plowActive && plowX > -140 * S * plowScale && plowX < W + 140 * S * plowScale }
    private var plowPileHeight: F { min(34, 4 + sqrt(c.plow.pushed / S) * 0.3) }

    /// True while snow chunks or smoke from the plow are still flying on this screen.
    var isBusy: Bool { !plowBits.isEmpty }

    /// Average height of the snow pile (the Controller sends the plow when it gets high).
    var heapAverage: F { heap.reduce(0, +) / F(heap.count) }

    private func updatePlow(_ dt: F) {
        let sc = S * plowScale
        if plowActive {
            // Everything between the edge where the plow entered this screen and the blade stays scraped down.
            let blade = plowX + plowDir * 72 * sc
            let residue = 1.5 * S
            let from: F = plowDir > 0 ? 0 : W
            if (plowDir > 0 && blade > 0) || (plowDir < 0 && blade < W) {
                let i0 = max(0, Int(max(0, min(from, blade)) / heapStep))
                let i1 = min(heap.count - 1, Int(min(W, max(from, blade)) / heapStep))
                if i0 <= i1 {
                    for i in i0...i1 where heap[i] > residue { c.plow.pushed += heap[i] - residue; heap[i] = residue }
                }
            }
        }
        if plowOnScreen {
            let gy = groundY - heapAt(plowX) + S
            let ph = plowPileHeight
            if ph > 10 {
                plowChunkAcc += dt * 30
                while plowChunkAcc >= 1 {
                    plowChunkAcc -= 1
                    let b = PlowBit()
                    b.x = plowX + plowDir * (70 + R() * ph) * sc
                    b.y = gy - ph * sc
                    b.vx = plowDir * (80 + R() * 140) * S
                    b.vy = -(60 + R() * 140) * S
                    b.max = 2; b.life = 2
                    b.size = (1.5 + R() * 2.5) * S
                    plowBits.append(b)
                }
            }
            plowSmokeTimer -= dt
            if plowSmokeTimer <= 0 {
                plowSmokeTimer = 0.2
                let b = PlowBit()
                b.smoke = true
                b.x = plowX - plowDir * 2 * sc
                b.y = gy - 76 * sc
                b.vx = -plowDir * 25 * S
                b.vy = -30 * S
                b.max = 1.6; b.life = 1.6
                b.size = 5 * S
                plowBits.append(b)
            }
            // Nisser wave at the truck as it passes.
            for n in nisser where n.state != 2 && abs(n.x - plowX) < 140 * S { n.state = 2; n.stateTimer = 1.5 }
        }

        var i = plowBits.count - 1
        while i >= 0 {
            let b = plowBits[i]
            b.life -= dt
            b.x += b.vx * dt
            b.y += b.vy * dt
            if b.smoke { b.size += 6 * S * dt } else { b.vy += 420 * S * dt }
            if b.life <= 0 || (!b.smoke && b.vy > 0 && b.y >= groundY - heapAt(b.x)) { plowBits.remove(at: i) }
            i -= 1
        }
    }

    private func renderPlow() {
        plowBitPool.begin()
        for b in plowBits {
            plowBitPool.add(b.smoke ? images.smoke : images.chunk, x: b.x, y: b.y, w: b.size * 2, h: b.size * 2,
                            opacity: b.smoke ? 90 / 255 * b.life / b.max : 235 / 255)
        }
        plowBitPool.end()
        guard plowOnScreen else { plowSprite.hide(); return }
        let sc = S * plowScale
        let gy = groundY - heapAt(plowX) + S
        plowSprite.place(CGRect(x: plowX - 130 * sc, y: gy - 100 * sc, width: 260 * sc, height: 106 * sc), redraw: frameNo % 2 == 0 || plowSprite.layer.isHidden)
    }

    private func drawPlow(_ g: CGContext) {
        let sc = S * plowScale
        let gy = groundY - heapAt(plowX) + S
        let ph = plowPileHeight
        g.translateBy(x: plowX, y: gy)
        g.scaleBy(x: plowDir * sc, y: sc)

        let o = C(235, 130, 20), od = C(185, 95, 10), dark = C(50, 50, 55), grey = C(110, 110, 115), glass = C(175, 210, 235)
        // exhaust stack
        g.fillRect(grey, -4, -76, 4, 30)
        // salt spreader at the back, with a spinning disc
        g.fillRect(grey, -92, -32, 12, 16)
        let sa = plowWheel * 2
        g.line(C(70, 70, 75), 2, -86 - cos(sa) * 6, -14, -86 + cos(sa) * 6, -14)
        // dump body with ribs and a reflective stripe
        g.fillRect(o, -80, -50, 74, 36)
        g.fillRect(od, -82, -53, 78, 5)
        for rx: F in [-62, -44, -26] { g.line(od, 2, rx, -48, rx, -16) }
        // cab
        g.fillPoly(o, [(-2, -14), (-2, -64), (26, -64), (40, -44), (43, -14)])
        g.fillPoly(glass, [(14, -59), (25, -59), (36, -43), (14, -43)])
        g.fillRect(glass, 1, -59, 10, 16)
        g.line(od, 1.2, 12, -60, 12, -16)
        g.fillRect(dark, 4, -38, 5, 2)
        g.fillRect(C(255, 255, 255, 230), -80, -26, 123, 3)
        g.fillEllipse(C(255, 245, 190), 38, -26, 5, 5)
        // amber beacon on the roof, flashing
        g.fillRect(dark, 12, -68, 10, 4)
        let flash = 0.5 + 0.5 * F(sin(c.time * 12))
        g.fillEllipse(C(255, 170, 0, Int(150 * flash)), 3, -82, 28, 24)
        g.fillEllipse(C(255, 200 + Int(55 * flash), 120 + Int(60 * flash)), 13, -74, 8, 7)
        // chassis and wheels with rotating spokes
        g.fillRect(dark, -86, -16, 132, 7)
        for wx: F in [-58, -32, 26] {
            g.fillEllipse(C(30, 30, 32), wx - 10, -20, 20, 20)
            g.fillEllipse(C(160, 160, 165), wx - 5, -15, 10, 10)
            for k in 0..<3 {
                let a = plowWheel + F(k) * .pi / 3
                let dx = cos(a) * 5, dy = sin(a) * 5
                g.line(C(60, 60, 65), 1.6, wx - dx, -10 - dy, wx + dx, -10 + dy)
            }
        }
        // snow pile in front of the blade
        let pile = CGMutablePath()
        pile.start(56, 1)
        pile.curve(60, -ph, 74 + ph * 0.6, -ph * 0.95, 72 + ph * 1.6, 1)
        pile.closeSubpath()
        g.fill(C(250, 252, 255, 250), pile)
        g.stroke(C(170, 200, 230, 120), 1, pile)
        // plow arm and curved yellow blade with black warning stripes
        g.line(C(80, 80, 85), 3, 42, -12, 55, -16)
        let blade = CGMutablePath()
        blade.start(54, -38)
        blade.curve(66, -30, 70, -14, 68, 2)
        blade.to(56, 2)
        blade.curve(58, -12, 54, -28, 50, -38)
        blade.closeSubpath()
        g.fill(C(250, 195, 30), blade)
        g.saveGState()
        g.addPath(blade); g.clip()
        var sy: F = -44
        while sy < 8 { g.line(C(40, 40, 40), 3, 46, sy, 74, sy + 14); sy += 9 }
        g.restoreGState()
        g.stroke(C(130, 95, 10), 1.2, blade)
    }

    // ------------------------------------------------------------------ nisser
    static let tunics = [C(115, 120, 130), C(40, 105, 65), C(150, 35, 45), C(70, 85, 145)]
    static let gifts = [C(40, 140, 70), C(60, 100, 200), C(200, 40, 60), C(150, 80, 180)]

    func nisseWave(_ seconds: F) {
        for n in nisser { n.state = 2; n.stateTimer = seconds }
    }

    private func updateNisser(_ dt: F) {
        // Every 1½–3 minutes a nisse arrives or leaves. The offset is pulled back toward 0, so the
        // number swings a little up and down but stays around the chosen count over time.
        nisseChangeTimer -= dt
        if nisseChangeTimer <= 0 {
            // JULE_NISSE_SECONDS=N changes the interval (for testing)
            nisseChangeTimer = F(Double(ProcessInfo.processInfo.environment["JULE_NISSE_SECONDS"] ?? "") ?? Double(90 + R() * 90))
            if nisseOffset == 0 { nisseOffset = R() < 0.5 ? -1 : 1 }
            else if R() < 0.7 { nisseOffset += nisseOffset > 0 ? -1 : 1 }
            else { nisseOffset = max(-2, min(2, nisseOffset + (nisseOffset > 0 ? 1 : -1))) }
        }
        let target = cfg.nisser ? max(1, cfg.nisseCount + nisseOffset) : 0
        if ProcessInfo.processInfo.environment["JULE_NISSE_SECONDS"] != nil, frameNo % 40 == 0, isPrimary {
            FileHandle.standardError.write("t=\(Int(c.time)) target=\(target) nisser=\(nisser.count) leaving=\(nisser.filter { $0.leaving }.count) entering=\(nisser.filter { $0.entering }.count) snow=\(String(format: "%.2f", c.snowIntensity))\n".data(using: .utf8)!)
        }
        let staying = nisser.filter { !$0.leaving }.count
        if staying < target {
            // At start-up everyone is already there; later arrivals walk in from a screen edge.
            let arriving = !nisser.isEmpty || c.time > 2
            for _ in 0..<(arriving ? 1 : target - staying) { addNisse(walkingIn: arriving) }
        } else if staying > target {
            if !cfg.nisser {
                while !nisser.isEmpty { removeNisse(at: nisser.count - 1) }
            } else if let n = nisser.last(where: { !$0.leaving }) {
                // walks off at the nearest edge
                n.leaving = true
                n.state = 0
                n.dir = n.x < W / 2 ? -1 : 1
            }
        }

        for n in nisser {
            // Wrap at 200π (a whole number of periods for both the wave and the hat sway).
            n.t += dt
            if n.t > 200 * .pi { n.t -= 200 * .pi }
            n.stateTimer -= dt
            if n.state == 0 {
                n.x += n.dir * n.speed * dt
                n.walkPhase += dt * n.speed / (4.5 * S)
                if n.entering && n.x > 30 * S && n.x < W - 30 * S { n.entering = false }
                if !n.entering && !n.leaving {
                    if n.x < 30 * S { n.x = 30 * S; n.dir = 1 }
                    if n.x > W - 30 * S { n.x = W - 30 * S; n.dir = -1 }
                }
                if n.entering || n.leaving { continue }   // no stopping or turning while arriving or leaving
                if n.stateTimer <= 0 {
                    let r = R()
                    if r < 0.3 { n.state = 1; n.stateTimer = 2 + R() * 3 }
                    else if r < 0.5 { n.state = 2; n.stateTimer = 2.5 }
                    else { if r < 0.7 { n.dir = -n.dir }; n.stateTimer = 4 + R() * 8 }
                }
            } else if n.leaving {
                n.state = 0   // stop waving and keep walking out
            } else if n.stateTimer <= 0 {
                n.state = 0
                n.stateTimer = 4 + R() * 8
                if R() < 0.4 { n.dir = -n.dir }
            }
        }
    }

    private func addNisse(walkingIn: Bool) {
        let n = Nisse()
        n.dir = R() < 0.5 ? -1 : 1
        if walkingIn {
            n.entering = true
            n.x = n.dir > 0 ? -40 * S : W + 40 * S
        } else {
            n.x = 60 * S + R() * (W - 120 * S)
        }
        n.speed = (22 + R() * 18) * S
        n.size = 0.85 + R() * 0.3
        let ti = Int.random(in: 0..<Self.tunics.count)
        n.tunic = Self.tunics[ti]
        n.mitten = ti == 2 ? C(40, 105, 65) : Self.hatRed   // red tunic gets green mittens
        n.carriesGift = R() < 0.4
        let gi = Int.random(in: 0..<Self.gifts.count)
        n.gift = Self.gifts[gi]
        n.variant = "\(ti)-\(n.carriesGift ? gi : -1)"
        n.stateTimer = 4 + R() * 6
        n.t = R() * 10
        nisser.append(n)
        let l = CALayer()
        l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "transform": NSNull(), "hidden": NSNull()]
        nisseLayer.addSublayer(l)
        nisseLayers.append(l)
    }

    private func removeNisse(at i: Int) {
        nisser.remove(at: i)
        nisseLayers.remove(at: i).removeFromSuperlayer()
    }

    // Frames per cycle: walking (legs + hat sway, period 4π of the walk phase), standing (hat sway), waving (arm).
    private static let walkFrames = 16, standFrames = 8, waveFrames = 8

    private func renderNisser() {
        // nisser that have walked off the screen are gone
        for i in stride(from: nisser.count - 1, through: 0, by: -1) where nisser[i].leaving && (nisser[i].x < -45 * S || nisser[i].x > W + 45 * S) {
            removeNisse(at: i)
        }
        for (i, n) in nisser.enumerated() {
            let sc = S * n.size
            let gy = groundY - heapAt(n.x) + 2 * S
            let frame: Int
            switch n.state {
            case 0: frame = Int((n.walkPhase / (4 * .pi)).truncatingRemainder(dividingBy: 1) * F(Self.walkFrames)) % Self.walkFrames
            case 1: frame = Int((n.t * 1.5 / (2 * .pi)).truncatingRemainder(dividingBy: 1) * F(Self.standFrames)) % Self.standFrames
            default: frame = Int((n.t * 11 / (2 * .pi)).truncatingRemainder(dividingBy: 1) * F(Self.waveFrames)) % Self.waveFrames
            }
            let key = "\(n.variant)-\(n.state)-\(frame)"
            let img = nisseFrames[key] ?? renderNisseFrame(n, frame, key)
            let l = nisseLayers[i]
            if l.contents == nil || (l.contents as! CGImage) !== img { l.contents = img }
            l.bounds = CGRect(x: 0, y: 0, width: 64 * sc, height: 80 * sc)
            l.position = CGPoint(x: n.x, y: H - (gy - 32 * sc))
            l.setAffineTransform(CGAffineTransform(scaleX: n.dir, y: 1))
        }
    }

    /// Draws one pose at the largest nisse size; smaller nisser and the walking direction are GPU scaling.
    private func renderNisseFrame(_ n: Nisse, _ frame: Int, _ key: String) -> CGImage {
        let maxSc = S * 1.15
        let img = renderImage(width: 64 * maxSc, height: 80 * maxSc, scale: window.backingScaleFactor) { g in
            g.scaleBy(x: maxSc, y: maxSc)
            g.translateBy(x: 32, y: 72)
            drawNisse(g, n, frame)
        }!
        nisseFrames[key] = img
        return img
    }

    private func drawNisse(_ g: CGContext, _ n: Nisse, _ frame: Int) {
        let p: F = n.state == 0 ? F(frame) / F(Self.walkFrames) * 4 * .pi : 0
        let standPhase: F = n.state == 1 ? F(frame) / F(Self.standFrames) * 2 * .pi : 0
        let wavePhase: F = n.state == 2 ? F(frame) / F(Self.waveFrames) * 2 * .pi : 0
        let walking = n.state == 0
        let legA: F = walking ? sin(p) * 0.55 : 0
        let bob: F = walking ? -abs(sin(p)) * 1.5 : 0

        g.fillEllipse(C(60, 80, 110, 50), -11, -2, 22, 4)

        func leg(_ hx: F, _ hy: F, _ a: F) {
            let fx = hx + sin(a) * 12, fy = hy + cos(a) * 12
            g.line(C(80, 80, 92), 5, hx, hy, fx, fy, round: true)
            g.fillEllipse(C(62, 40, 28), fx - 3, fy - 2, 9, 5)
        }
        leg(-2, -15 + bob, legA)
        leg(2, -15 + bob, -legA)

        g.translateBy(x: 0, y: bob)
        let backArm: F, frontArm: F
        if n.state == 2 { backArm = -legA * 0.8; frontArm = 2.5 + sin(wavePhase) * 0.45 }
        else if n.carriesGift { backArm = 1.3; frontArm = 1.3 }
        else { backArm = -legA * 0.9; frontArm = legA * 0.9 }

        func arm(_ sx: F, _ sy: F, _ a: F) {
            let hx = sx + sin(a) * 10, hy = sy + cos(a) * 10
            g.line(n.tunic, 4.2, sx, sy, hx, hy, round: true)
            g.fillEllipse(n.mitten, hx - 2.5, hy - 2.5, 5, 5)
        }
        arm(-1, -29, backArm)
        g.fillEllipse(n.tunic, -10, -34, 20, 22)
        g.fillRect(C(35, 30, 30), -9.5, -20, 19, 3)
        g.fillRect(Self.gold, 2, -20.5, 3.5, 4)

        if n.carriesGift && n.state != 2 {
            g.fillRect(n.gift, 6, -31, 11, 10)
            g.line(Self.gold, 1.6, 11.5, -31, 11.5, -21)
            g.line(Self.gold, 1.6, 6, -26, 17, -26)
            g.strokeEllipse(Self.gold, 1.6, 9, -34, 3, 3)
            g.strokeEllipse(Self.gold, 1.6, 12, -34, 3, 3)
        }

        g.fillEllipse(Self.skin, -6, -44, 13, 12)
        let beard = CGMutablePath()
        beard.start(-6, -39)
        beard.curve(-7, -30, -2, -22, 3, -20)
        beard.curve(7, -24, 9, -32, 7.5, -39)
        beard.closeSubpath()
        g.fill(C(250, 250, 250), beard)
        arm(1, -29, frontArm)
        g.fillEllipse(C(240, 160, 150), 4, -40, 5, 5)

        let sway = sin(walking ? p * 0.5 : standPhase) * 2.5
        let tipX = -14 + sway, tipY: F = -57
        let hat = CGMutablePath()
        hat.start(-7.5, -39)
        hat.to(8, -39)
        hat.curve(9, -54, 0, -62, tipX, tipY)
        hat.curve(-6, -57, -7, -49, -7.5, -39)
        hat.closeSubpath()
        g.fill(Self.hatRed, hat)
        g.line(C(150, 15, 25), 2, -7.5, -39.5, 8, -39.5)
        g.fillEllipse(C(255, 255, 255), tipX - 3, tipY - 3, 6, 6)
    }

    // ------------------------------------------------------------------ julelys
    static let bulbColors = [C(255, 60, 60), C(60, 220, 90), C(255, 200, 60), C(80, 150, 255), C(255, 110, 200)]

    // The wire, sockets and dimmed bulbs are drawn once. Each bulb's bright version (glow, colour, shine)
    // is a separate layer whose opacity twinkles via a Core Animation loop, so the twinkle costs no CPU.
    private func renderLightsLayer() {
        guard cfg.lights else { lightsSprite.hide(); lightsLayer.isHidden = true; return }
        if lightsSprite.layer.isHidden { lightsSprite.place(CGRect(x: 0, y: lightsTop, width: W, height: lightsHeight)) }
        if !bulbsBuilt { buildBulbs(); bulbsBuilt = true }
        lightsLayer.isHidden = false
        // The twinkle is slow, so 10 updates/s (5 in power-save mode) is plenty.
        lightsTimer -= 1
        if lightsTimer <= 0 {
            lightsTimer = PS ? 3 : 3
            for b in bulbLayers {
                // brightness 0.55 + 0.45·sin(ω·t + φ), as in the Windows version (0.1…1 over the dimmed bulb)
                b.layer.opacity = Float(0.55 + 0.45 * sin(c.time * b.omega + b.phase))
            }
        }
    }
    private var lightsTimer = 0

    private func forEachBulb(_ body: (_ idx: Int, _ bx: F, _ by: F) -> Void) {
        let span = 230 * S, sag = 22 * S, top = lightsTop + 1
        var idx = 0
        var x0 = -span * 0.3
        while x0 < W {
            for b in 0..<4 {
                let u = (F(b) + 0.5) / 4
                body(idx, x0 + u * span, top + sag * (1 - (2 * u - 1) * (2 * u - 1)))
                idx += 1
            }
            x0 += span
        }
    }

    private func buildBulbs() {
        let scale = window.backingScaleFactor
        let w = 7 * S, h = 11 * S, bw = 26 * S, bh = 28 * S
        let bright = Self.bulbColors.map { col in
            renderImage(width: bw, height: bh, scale: scale) { g in
                g.fillEllipse(withAlpha(col, 70), 0, 1 * S, 26 * S, 26 * S)
                g.fillEllipse(col, bw / 2 - w / 2, 3 * S, w, h)
                g.fillEllipse(C(255, 255, 255, 160), bw / 2 - w / 4, 5 * S, w / 3, h / 3)
            }
        }
        forEachBulb { idx, bx, by in
            let l = CALayer()
            l.contents = bright[idx % bright.count]
            l.contentsScale = scale
            l.frame = CGRect(x: bx - 13 * S, y: H - (by + bh), width: bw, height: bh)
            l.actions = ["opacity": NSNull()]
            bulbLayers.append((l, 1.3 + Double(idx * 37 % 10) * 0.12, Double(idx) * 1.7))
            lightsLayer.addSublayer(l)
        }
    }

    private func renderLights(_ g: CGContext) {
        let span = 230 * S, sag = 22 * S, top = lightsTop + 1
        let wire = C(25, 60, 35, 220), socket = C(30, 70, 40)
        var x0 = -span * 0.3
        while x0 < W {
            g.setStrokeColor(wire); g.setLineWidth(2 * S); g.setLineCap(.round)
            g.beginPath()
            for k in 0...24 {
                let u = F(k) / 24
                let p = CGPoint(x: x0 + u * span, y: top + sag * (1 - (2 * u - 1) * (2 * u - 1)))
                if k == 0 { g.move(to: p) } else { g.addLine(to: p) }
            }
            g.strokePath()
            x0 += span
        }
        let w = 7 * S, h = 11 * S
        forEachBulb { idx, bx, by in
            let comps = Self.bulbColors[idx % Self.bulbColors.count].components!
            g.fillRect(socket, bx - 2.5 * S, by, 5 * S, 4 * S)
            g.fillEllipse(CGColor(srgbRed: comps[0] * 0.5, green: comps[1] * 0.5, blue: comps[2] * 0.5, alpha: 1), bx - w / 2, by + 3 * S, w, h)
        }
    }
}
