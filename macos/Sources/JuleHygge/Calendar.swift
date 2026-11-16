import AppKit

enum CalendarContent {
    // Effekter: 0 = ingen, 1 = julemanden, 2 = snestorm, 3 = nissefest, 4 = stjerneregn, 5 = det hele
    static let texts = [
        /* 1 */ "Velkommen til december! Nisserne er klar og vinker til dig fra bunden af skærmen. Kan du se dem?",
        /* 2 */ "Hvad kalder man en snemand om sommeren? En vandpyt!",
        /* 3 */ "Hyggetip: Tænd et lys, lav en kop varm kakao og hold fem minutters pause. Arbejdet kan godt vente lidt.",
        /* 4 */ "Vidste du, at julemærket blev fundet på af den danske postmand Einar Holbøll? Det første kom i 1904.",
        /* 5 */ "Hvorfor er julemanden så god til karate? Fordi han har sort bælte!",
        /* 6 */ "Hyggetip: Send en julehilsen til én, du ikke har talt med længe. Det tager to minutter og gør dagen bedre for jer begge.",
        /* 7 */ "Vidste du, at det første kendte juletræ i Danmark blev tændt på Holsteinborg gods i 1808?",
        /* 8 */ "Vejrudsigten for i dag: Kraftigt snefald over skrivebordet. Find vanterne frem!",
        /* 9 */ "Hvad sagde den ene snemand til den anden? \"Kan du også lugte gulerødder?\"",
        /* 10 */ "Hyggetip: Gå en tur, når det bliver mørkt, og kig efter julelys i vinduerne.",
        /* 11 */ "I gamle dage boede nissen på gården. Fik han ikke sin risengrød juleaften, lavede han ballade. Nisserne her på skærmen er heldigvis nemmere at gøre glade.",
        /* 12 */ "Halvvejs til juleaften! Julemanden tager en ekstra prøvetur for at fejre det. Hold øje med himlen.",
        /* 13 */ "I dag er det Santa Lucia. Lyset fejres med optog og hvide kjoler. Her på skærmen fejrer vi det med et stjerneskud.",
        /* 14 */ "Hvad får man, hvis man krydser en snemand med en vampyr? Frostbid!",
        /* 15 */ "Hyggetip: Bag pebernødder. Dejen tager ti minutter, og hele huset kommer til at dufte af jul.",
        /* 16 */ "Vidste du, at Rudolf med den røde tud blev opfundet i 1939 til en lille julebog fra et amerikansk stormagasin?",
        /* 17 */ "Snestorm! Godt at du sidder indenfor i varmen.",
        /* 18 */ "Hvad siger man til en nisse, der er ked af det? Op med humøret, og op med huen!",
        /* 19 */ "Hyggetip: Sæt julemusik på og ryd op på skrivebordet. Både det rigtige og det her på skærmen.",
        /* 20 */ "Vidste du, at risalamande er dansk, selvom navnet lyder fransk? Det kommer af \"riz à l'amande\", som betyder ris med mandler.",
        /* 21 */ "Nisserne holder generalprøve på dansen om juletræet. Se dem lige vinke!",
        /* 22 */ "Hyggetip: Skriv en ønskeseddel, også selvom du er voksen. Julemanden flyver forbi lige om lidt og kan måske nå at tage den med.",
        /* 23 */ "Lillejuleaften! Husk at gemme en hel mandel til risalamanden. Den, der finder den, får mandelgaven.",
        /* 24 */ "Glædelig jul! I Danmark holder vi jul om aftenen den 24., mens mange andre lande først fejrer den den 25. om morgenen. Julemanden er på vej, så god jul og godt nytår!",
    ]
    static let effects = [3, 0, 0, 4, 0, 0, 0, 2, 0, 0, 3, 1, 4, 0, 0, 0, 2, 0, 0, 4, 3, 1, 0, 5]

    static func calendarYear(for d: Date) -> Int {
        let p = JuleClock.parts(d)
        return p.month == 1 ? p.year - 1 : p.year
    }

    /// Højeste låge der må åbnes på datoen d (0 = ingen)
    static func openableUpTo(_ d: Date) -> Int {
        let p = JuleClock.parts(d)
        if p.month == 12 { return min(24, p.day) }
        if p.month == 1 { return 24 }
        return 0
    }

    static func syncYear(_ s: Settings, _ d: Date) {
        let y = calendarYear(for: d)
        if s.calendarYear != y {
            s.calendarYear = y
            s.openedDoors.removeAll()
            s.save()
        }
    }
}

final class CalendarWindow: NSWindow, NSWindowDelegate {
    private let onClose: () -> Void

    init(controller: Controller, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720), styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "Julekalender \(CalendarContent.calendarYear(for: JuleClock.today))"
        isReleasedWhenClosed = false
        contentView = CalendarView(controller: controller, title: title)
        delegate = self
        center()
    }

    func windowWillClose(_ notification: Notification) {
        (contentView as? CalendarView)?.stop()
        onClose()
    }
}

final class CalendarView: NSView {
    static let order = [7, 15, 2, 22, 11, 18, 4, 20, 13, 1, 9, 24, 16, 6, 23, 10, 3, 19, 12, 21, 5, 17, 14, 8]
    static let doorFills = [C(165, 28, 38), C(238, 228, 204), C(30, 105, 60)]
    static let goldC = C(240, 205, 110)

    private unowned let c: Controller
    private let titleText: String
    private var doors = [CGRect](repeating: .zero, count: 25)
    private var openAnim = [F](repeating: 0, count: 25)
    private var timer: Timer?
    private var pulse: F = 0
    private var tickCount = 0
    private var selected = 0
    private var message = ""
    private var background: CGImage?

    override var isFlipped: Bool { true }

    init(controller: Controller, title: String) {
        c = controller
        titleText = title
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 720))
        let size: F = 110, gap: F = 15
        let left = (820 - (6 * size + 5 * gap)) / 2, top: F = 95
        for i in 0..<24 {
            doors[Self.order[i]] = CGRect(x: left + F(i % 6) * (size + gap), y: top + F(i / 6) * (size + gap), width: size, height: size)
        }
        for d in 1...24 where c.cfg.openedDoors.contains(d) { openAnim[d] = 1 }
        message = initialMessage()
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.animTick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    required init?(coder: NSCoder) { fatalError() }

    func stop() { timer?.invalidate(); timer = nil }

    /// Repaints only doors that are moving: an opening door, or an openable door whose gold border pulses.
    private func animTick() {
        if window?.isMiniaturized == true { return }
        pulse += 0.04
        tickCount += 1
        let pulseFrame = tickCount & 1 == 0
        let upTo = CalendarContent.openableUpTo(JuleClock.today)
        for d in 1...24 {
            if openAnim[d] > 0 && openAnim[d] < 1 {
                openAnim[d] = min(1, openAnim[d] + 0.07)
                setNeedsDisplay(doors[d].insetBy(dx: -8, dy: -8))
            } else if pulseFrame && d <= upTo && !c.cfg.openedDoors.contains(d) {
                setNeedsDisplay(doors[d].insetBy(dx: -8, dy: -8))
            }
        }
    }

    private func initialMessage() -> String {
        let today = JuleClock.today
        let p = JuleClock.parts(today)
        if CalendarContent.openableUpTo(today) == 0 {
            let n = JuleClock.days(from: today, to: JuleClock.make(p.year, 12, 1))
            return "Julekalenderen åbner den 1. december, om \(n)\(n == 1 ? " dag" : " dage"). Indtil da må du nøjes med nisserne!"
        }
        if p.month == 12 && p.day <= 24 && !c.cfg.openedDoors.contains(p.day) {
            return "Dagens låge er nummer \(p.day). Kan du finde den?"
        }
        return "Klik på en åben låge for at læse den igen."
    }

    private func doorAt(_ p: CGPoint) -> Int {
        for d in 1...24 where doors[d].contains(p) { return d }
        return 0
    }

    override func resetCursorRects() {
        for d in 1...24 { addCursorRect(doors[d], cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let d = doorAt(convert(event.locationInWindow, from: nil))
        if d > 0 { clickDoor(d) }
    }

    private func clickDoor(_ d: Int) {
        let today = JuleClock.today
        CalendarContent.syncYear(c.cfg, today)
        let upTo = CalendarContent.openableUpTo(today)
        if d <= upTo {
            if !c.cfg.openedDoors.contains(d) {
                c.cfg.openedDoors.insert(d)
                c.cfg.save()
                openAnim[d] = 0.01
            }
            selected = d
            message = "Låge \(d):  " + CalendarContent.texts[d - 1]
            c.triggerEffect(CalendarContent.effects[d - 1])
        } else {
            selected = 0
            let p = JuleClock.parts(today)
            if p.month == 12 {
                let n = d - p.day
                message = "Tålmodighed! Låge \(d) kan åbnes om \(n)\(n == 1 ? " dag." : " dage.")"
            } else {
                message = "Låge \(d) åbner den \(d). december."
            }
        }
        needsDisplay = true
    }

    // ------------------------------------------------------------------ tegning
    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        // The static background (gradient, snow dots, title) is rendered once and then just copied.
        if background == nil { background = renderImage(width: bounds.width, height: bounds.height, scale: scale) { renderBackground($0) } }
        if let bg = background {
            g.saveGState()
            g.translateBy(x: 0, y: bounds.height); g.scaleBy(x: 1, y: -1)
            g.draw(bg, in: bounds)
            g.restoreGState()
        }

        let upTo = CalendarContent.openableUpTo(JuleClock.today)
        for d in 1...24 where doors[d].insetBy(dx: -8, dy: -8).intersects(dirtyRect) { drawDoor(g, d, upTo) }

        let mr = CGRect(x: 40, y: 605, width: bounds.width - 80, height: 95)
        if !mr.intersects(dirtyRect) { return }
        g.fill(C(255, 255, 255, 45), CGPath(roundedRect: mr, cornerWidth: 12, cornerHeight: 12, transform: nil))
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white, .paragraphStyle: para]
        let text = NSAttributedString(string: message, attributes: attrs)
        let inner = mr.insetBy(dx: 18, dy: 8)
        let h = text.boundingRect(with: inner.size, options: [.usesLineFragmentOrigin]).height
        text.draw(with: CGRect(x: inner.minX, y: inner.midY - h / 2, width: inner.width, height: h), options: [.usesLineFragmentOrigin])
    }

    private func renderBackground(_ g: CGContext) {
        let cr = bounds
        g.fillGradient(CGPath(rect: cr, transform: nil), C(24, 72, 46), C(8, 28, 18), from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: cr.height))
        var rng = SeededRandom(seed: 7)
        for _ in 0..<90 {
            let rad = 1 + rng.next() * 2.5
            g.fillEllipse(C(255, 255, 255, 55), rng.next() * cr.width, rng.next() * cr.height, rad * 2, rad * 2)
        }
        // Text drawing needs an NSGraphicsContext; the image context is y-down already, so mark it flipped.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: g, flipped: true)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let font = NSFont(name: "Georgia-Bold", size: 32) ?? NSFont.boldSystemFont(ofSize: 32)
        let t = NSAttributedString(string: titleText, attributes: [.font: font, .foregroundColor: NSColor(cgColor: Self.goldC)!, .paragraphStyle: para])
        let h = t.size().height
        t.draw(in: CGRect(x: 0, y: 15 + (70 - h) / 2, width: cr.width, height: h))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func rounded(_ r: CGRect, _ rad: F) -> CGPath {
        let rr = max(0.1, min(rad, r.width / 2, r.height / 2))
        return CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil)
    }

    private func drawText(_ s: String, font: NSFont, color: CGColor, in r: CGRect, centered: Bool) {
        let para = NSMutableParagraphStyle(); para.alignment = centered ? .center : .left
        let t = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .paragraphStyle: para])
        let h = t.size().height
        t.draw(in: centered ? CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h) : r)
    }

    private func drawDoor(_ g: CGContext, _ d: Int, _ upTo: Int) {
        let rc = doors[d]
        let opened = c.cfg.openedDoors.contains(d)
        let fill = Self.doorFills[d % 3]
        let numCol = d % 3 == 1 ? C(165, 28, 38) : C(255, 255, 255)
        let rad: F = 10

        if opened {
            g.fillGradient(rounded(rc, rad), C(70, 40, 28), C(35, 20, 14), from: CGPoint(x: 0, y: rc.minY), to: CGPoint(x: 0, y: rc.maxY))
            drawIcon(g, d, rc.insetBy(dx: rc.width * 0.2, dy: rc.height * 0.2))
            drawText("\(d)", font: NSFont(name: "Georgia-Bold", size: 12) ?? .boldSystemFont(ofSize: 12), color: C(200, 180, 140),
                     in: CGRect(x: rc.minX + 6, y: rc.minY + 4, width: 40, height: 18), centered: false)
            let a = openAnim[d]
            if a < 1 {
                // lågen svinger op omkring venstre hængsel
                let dr = CGRect(x: rc.minX, y: rc.minY, width: rc.width * (1 - a), height: rc.height)
                if dr.width > 2 { g.fill(shade(fill, 1 - a * 0.5), rounded(dr, min(rad, dr.width / 2))) }
            } else {
                g.fillRect(shade(fill, 0.6), rc.minX - 4, rc.minY + 6, 5, rc.height - 12)
            }
        } else {
            let p = rounded(rc, rad)
            g.fillGradient(p, shade(fill, 1.1), shade(fill, 0.85), from: CGPoint(x: rc.minX, y: rc.minY), to: CGPoint(x: rc.midX, y: rc.maxY))
            g.stroke(C(255, 255, 255, 80), 1.2, p)
            g.saveGState()
            g.setLineDash(phase: 0, lengths: [3, 3])
            g.stroke(C(0, 0, 0, 70), 1, rounded(rc.insetBy(dx: 7, dy: 7), rad * 0.6))
            g.restoreGState()
            drawText("\(d)", font: NSFont(name: "Georgia-Bold", size: 34) ?? .boldSystemFont(ofSize: 34), color: numCol, in: rc, centered: true)
            if d <= upTo {
                let al = Int(150 + 100 * sin(pulse * 3))
                g.stroke(withAlpha(Self.goldC, al), 3.5, rounded(rc.insetBy(dx: -2, dy: -2), rad + 2))
            }
        }
        if selected == d { g.stroke(C(255, 255, 255), 2.5, rounded(rc.insetBy(dx: -3, dy: -3), rad + 3)) }
    }

    /// Lille tegning bag hver åbnet låge
    private func drawIcon(_ g: CGContext, _ d: Int, _ r: CGRect) {
        let cx = r.midX, cy = r.midY, w = r.width, h = r.height
        let ri = r.insetBy(dx: -w * 0.15, dy: -h * 0.15)
        g.fillEllipse(C(255, 220, 140, 40), ri.minX, ri.minY, ri.width, ri.height)
        let gold = Self.goldC, red = C(205, 35, 45), green = C(40, 140, 70), white = C(245, 240, 230)
        switch d % 6 {
        case 0: // stjerne
            g.fillPoly(gold, starPoints(cx, cy, w * 0.48, w * 0.2))
        case 1: // juletræ
            for i in 0..<3 {
                let ty = cy - h * 0.38 + F(i) * h * 0.2, tw = w * (0.38 + F(i) * 0.14)
                g.fillPoly(green, [(cx, ty), (cx + tw / 2, ty + h * 0.3), (cx - tw / 2, ty + h * 0.3)])
            }
            g.fillRect(C(110, 70, 35), cx - w * 0.06, cy + h * 0.32, w * 0.12, h * 0.14)
            g.fillPoly(gold, starPoints(cx, cy - h * 0.42, w * 0.12, w * 0.05))
            g.fillEllipse(red, cx - w * 0.15, cy - h * 0.02, w * 0.08, w * 0.08)
            g.fillEllipse(gold, cx + w * 0.08, cy + h * 0.15, w * 0.08, w * 0.08)
        case 2: // gave
            g.fillRect(red, cx - w * 0.38, cy - h * 0.15, w * 0.76, h * 0.55)
            g.fillRect(C(178, 34, 34), cx - w * 0.42, cy - h * 0.27, w * 0.84, h * 0.14)
            g.fillRect(gold, cx - w * 0.06, cy - h * 0.27, w * 0.12, h * 0.67)
            g.fillEllipse(gold, cx - w * 0.28, cy - h * 0.45, w * 0.26, h * 0.2)
            g.fillEllipse(gold, cx + w * 0.02, cy - h * 0.45, w * 0.26, h * 0.2)
        case 3: // hjerte
            let p = CGMutablePath()
            p.start(cx, cy + h * 0.38)
            p.curve(cx - w * 0.65, cy - h * 0.05, cx - w * 0.35, cy - h * 0.5, cx, cy - h * 0.18)
            p.curve(cx + w * 0.35, cy - h * 0.5, cx + w * 0.65, cy - h * 0.05, cx, cy + h * 0.38)
            g.fill(red, p)
        case 4: // lys
            g.fillEllipse(C(255, 200, 80, 70), cx - w * 0.22, cy - h * 0.55, w * 0.44, h * 0.44)
            g.fillRect(white, cx - w * 0.13, cy - h * 0.15, w * 0.26, h * 0.6)
            g.fillRect(red, cx - w * 0.13, cy + h * 0.1, w * 0.26, h * 0.06)
            g.fillEllipse(gold, cx - w * 0.07, cy - h * 0.42, w * 0.14, h * 0.24)
        default: // klokke
            let p = CGMutablePath()
            p.start(cx - w * 0.38, cy + h * 0.25)
            p.curve(cx - w * 0.3, cy - h * 0.05, cx - w * 0.28, cy - h * 0.4, cx, cy - h * 0.4)
            p.curve(cx + w * 0.28, cy - h * 0.4, cx + w * 0.3, cy - h * 0.05, cx + w * 0.38, cy + h * 0.25)
            p.closeSubpath()
            g.fill(gold, p)
            g.fillEllipse(gold, cx - w * 0.08, cy + h * 0.2, w * 0.16, w * 0.16)
            g.fillEllipse(red, cx - w * 0.2, cy - h * 0.52, w * 0.18, h * 0.14)
            g.fillEllipse(red, cx + w * 0.02, cy - h * 0.52, w * 0.18, h * 0.14)
        }
    }
}

/// Deterministic random numbers, so the background snow dots are the same every time.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> F {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return F(state % 1_000_000) / 1_000_000
    }
}
