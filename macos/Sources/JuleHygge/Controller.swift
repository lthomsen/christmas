import AppKit
import IOKit.ps
import QuartzCore
import ServiceManagement
import UserNotifications

/// Styrer det hele: menulinje-ikon, hovedløkke, julemanden (på tværs af skærme), effekter og daglige begivenheder.
/// Selve tegningen sker i ét ScreenOverlay-vindue pr. skærm.
final class Controller: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let cfg = Settings.load()
    /// Seconds since start (a Double, so long uptimes do not lose precision).
    var time: Double = 0
    var stormUntil: Double = -1
    var wind: F = 0
    var fullscreenRects: [CGRect] = []

    // julemanden, i globale koordinater (origo øverst til venstre på hovedskærmen)
    var santaActive = false
    var santaX: F = 0, santaY0: F = 0, santaDir: F = 1, santaSpeed: F = 0, santaPhase: F = 0, santaScale: F = 1
    private var santaMinX: F = 0, santaMaxX: F = 0
    var sparks: [Spark] = []

    static let snowmanMaxStage = 12
    var snowmanStage = 1
    static let snowmanSteps = [
        "en lille snebold", "en stor snebold", "maven", "hovedet", "øjne af kul", "en gulerodsnæse",
        "knapper", "arme af grene", "et smil", "et rødt halstørklæde", "en høj hat", "en kost - snemanden er færdig!"]

    private var overlays: [ScreenOverlay] = []
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var tickCount = 0, tickWindow: CFTimeInterval = 0
    private var lastT = CACurrentMediaTime()
    private var windTarget: F = 0, windTimer: F = 0, santaNext: F = 5, sparkAcc: F = 0, fsTimer: F = 0, topTimer: F = 0, dayTimer: F = 0
    private var powerTimer: F = 0
    private var celebrateAt: Double = -1, plowAt: Double = -1
    private var lastDay: Date?
    private var statusItem: NSStatusItem!
    private var calendarWindow: CalendarWindow?
    private var menuActions: [MenuAction] = []
    private var countdownItem: NSMenuItem!, snowmanItem: NSMenuItem!, autostartItem: NSMenuItem!
    private(set) var powerSave = false

    var santaY: F { santaY0 + sin(santaPhase * 0.9) * 40 * santaScale }
    var effectiveSnowLevel: Int { time < stormUntil ? 2 : cfg.snowLevel }
    var snowOn: Bool { cfg.snow || time < stormUntil }

    override init() {
        super.init()
        if cfg.firstRun == nil { cfg.firstRun = JuleClock.today; cfg.save() }
        buildStatusItem()
        buildOverlays()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { self.updateDaily(startup: true) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buildOverlays()
        }
        // Stop completely while the displays sleep, the screen is locked or another user is active.
        let ws = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                                 (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setAsleep(sleeping) }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.setAsleep(true) }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.setAsleep(false) }
        updatePowerSave()
        startTimer()
    }

    private var asleep = false
    private var currentFps: Double = 0

    /// Every screen update makes WindowServer recomposite the overlay, which is what really costs power.
    /// So the calm scene runs at a low frame rate, and only fast things (Santa, the plow, sparks) get a smooth 60 fps.
    private var desiredFps: Double {
        if let f = Double(ProcessInfo.processInfo.environment["JULE_FPS"] ?? "") { return f }
        let calm = Double(powerSave ? min(cfg.frameRate, 12) : cfg.frameRate)
        // Santa (and his sparks/star showers) moves fast and needs 60 fps to look fluent.
        if santaActive || !sparks.isEmpty { return max(calm, powerSave ? 30 : 60) }
        // The plow is slow (~175 pt/s), so 30 fps is smooth enough and costs about half as much.
        if plow.active || overlays.contains(where: { $0.isBusy }) { return max(calm, powerSave ? 20 : 30) }
        return calm
    }
    private func setAsleep(_ s: Bool) {
        if s == asleep { return }
        asleep = s
        if s { stopTicker() } else { lastT = CACurrentMediaTime(); startTimer() }
    }

    /// Frames follow the display's refresh (a display link), so at e.g. 20 fps on a 120 Hz screen every frame
    /// lands exactly 6 refreshes apart. A plain Timer drifts against the refresh and makes motion judder.
    private func startTimer() {
        stopTicker()
        let fps = desiredFps
        currentFps = fps
        guard let screen = NSScreen.screens.first else { return }
        let l = screen.displayLink(target: self, selector: #selector(linkFired(_:)))
        let f = Float(fps)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: f, maximum: f, preferred: f)
        l.add(to: .main, forMode: .common)   // keeps running while the menu is open
        link = l
    }

    private func stopTicker() { link?.invalidate(); link = nil }

    @objc private func linkFired(_ l: CADisplayLink) {
        // Safety net in case the system delivers more callbacks than asked for: skip early ones.
        let now = CACurrentMediaTime()
        if now - lastTick < 1 / currentFps - 0.004 { return }
        lastTick = now
        if ProcessInfo.processInfo.environment["JULE_TICKS"] != nil {
            tickCount += 1
            if now - tickWindow >= 5 {
                FileHandle.standardError.write("ticks/s: \(Double(tickCount) / (now - tickWindow))\n".data(using: .utf8)!)
                tickCount = 0; tickWindow = now
            }
        }
        tick()
    }

    private func updatePowerSave() {
        var onBattery = false
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
            onBattery = type == "Battery Power"
        }
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        let ps = cfg.powerSave == 1 || (cfg.powerSave == 2 && (onBattery || low))
        if ps != powerSave { powerSave = ps; if link != nil && !asleep { startTimer() } }
    }

    // ------------------------------------------------------------------ skærme
    private func buildOverlays() {
        for o in overlays { o.close() }
        overlays.removeAll()
        for s in NSScreen.screens {
            if !cfg.allScreens && s.frame.origin != .zero { continue }
            overlays.append(ScreenOverlay(controller: self, screen: s))
        }
        santaActive = false
        plow.active = false
    }

    // ------------------------------------------------------------------ hovedløkke
    private func tick() {
        let now = CACurrentMediaTime()
        let dt = F(min(0.1, now - lastT))
        lastT = now
        time += Double(dt)

        dayTimer -= dt
        if dayTimer <= 0 {
            dayTimer = 30
            if JuleClock.today != lastDay { updateDaily(startup: false) }
        }
        powerTimer -= dt
        if powerTimer <= 0 { powerTimer = 5; updatePowerSave() }
        fsTimer -= dt
        if fsTimer <= 0 { fsTimer = 1; fullscreenRects = Self.findFullscreenWindows() }
        topTimer -= dt
        if topTimer <= 0 { topTimer = 5; for o in overlays { o.keepOnTop() } }

        updateWind(dt)
        updateSanta(dt)
        updateSparks(dt)
        updatePlow(dt)
        if celebrateAt > 0 && time >= celebrateAt { celebrateAt = -1; snowmanCelebrate() }
        if plowAt >= 0 && time >= plowAt { plowAt = -1; sendPlow() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for o in overlays { o.frame(dt) }
        CATransaction.commit()
        if desiredFps != currentFps && !asleep { startTimer() }
        if let s = snapshot, time >= s.at { snapshot = nil; writeSnapshots(to: s.dir) }
    }

    /// Test aid (--snapshot=DIR[,SECONDS]): renders each screen's overlay onto a dark background as a PNG,
    /// since screenshots need the Screen Recording permission.
    var snapshot: (dir: String, at: Double)?

    private func writeSnapshots(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (i, o) in overlays.enumerated() {
            let w = Int(o.W), h = Int(o.H)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(C(40, 55, 80)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            (o.root.presentation() ?? o.root).render(in: ctx)
            if let img = ctx.makeImage() {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("screen\(i).png"))
            }
        }
        if let v = calendarWindow?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("calendar.png"))
        }
        ErrorLog.debug("snapshot written to \(dir)")
    }

    private func updateWind(_ dt: F) {
        windTimer -= dt
        if windTimer <= 0 {
            windTimer = 3 + R() * 6
            let storm = effectiveSnowLevel == 2
            windTarget = (R() * 2 - 1) * (storm ? 140 : 30) + (storm ? 60 : 0)
        }
        wind += (windTarget - wind) * min(1, dt * 0.5)
    }

    /// Windows of other apps that exactly cover a screen (fullscreen apps, games, video), in global top-left coordinates.
    private static func findFullscreenWindows() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let screens = NSScreen.screens.map { s -> CGRect in
            let top = NSScreen.screens[0].frame.maxY
            return CGRect(x: s.frame.minX, y: top - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
        var out: [CGRect] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { continue }
            if screens.contains(where: { abs($0.minX - r.minX) < 2 && abs($0.minY - r.minY) < 2 && abs($0.width - r.width) < 2 && abs($0.height - r.height) < 2 }) {
                out.append(r)
            }
        }
        return out
    }

    // ------------------------------------------------------------------ julemanden
    func launchSanta() {
        if santaActive || overlays.isEmpty { return }
        let target = overlays.randomElement()!
        let b = target.screenBounds
        santaScale = target.S
        santaY0 = b.minY + b.height * (0.12 + R() * 0.25)
        // fly over every screen at the same height
        santaMinX = b.minX; santaMaxX = b.maxX
        for o in overlays {
            let lb = o.screenBounds
            if santaY0 >= lb.minY && santaY0 < lb.maxY { santaMinX = min(santaMinX, lb.minX); santaMaxX = max(santaMaxX, lb.maxX) }
        }
        santaDir = R() < 0.5 ? 1 : -1
        santaX = santaDir > 0 ? santaMinX - 420 * santaScale : santaMaxX + 420 * santaScale
        santaSpeed = (190 + R() * 80) * santaScale * (santaMaxX - santaMinX > b.width * 1.5 ? 1.6 : 1)
        santaPhase = 0
        santaActive = true
    }

    private func updateSanta(_ dt: F) {
        if !santaActive {
            if cfg.santa { santaNext -= dt; if santaNext <= 0 { launchSanta(); santaNext = 60 + R() * 120 } }
            return
        }
        santaX += santaDir * santaSpeed * dt
        santaPhase += dt
        sparkAcc += dt * 45
        while sparkAcc >= 1 {
            sparkAcc -= 1
            let sp = Spark()
            sp.x = santaX - santaDir * 90 * santaScale + (R() - 0.5) * 10 * santaScale
            sp.y = santaY + (R() - 0.3) * 20 * santaScale
            sp.vx = -santaDir * (10 + R() * 30) * santaScale
            sp.vy = (R() - 0.5) * 20 * santaScale
            sp.max = 0.8 + R() * 1.4; sp.life = sp.max
            sp.size = (1.5 + R() * 3) * santaScale
            sp.gold = R() < 0.6
            sparks.append(sp)
        }
        if (santaDir > 0 && santaX > santaMaxX + 450 * santaScale) || (santaDir < 0 && santaX < santaMinX - 450 * santaScale) {
            santaActive = false
            santaNext = 60 + R() * 120
        }
    }

    private func updateSparks(_ dt: F) {
        sparks.removeAll { sp in
            sp.life -= dt
            if sp.life <= 0 { return true }
            sp.x += sp.vx * dt
            sp.y += sp.vy * dt
            sp.vy += 12 * santaScale * dt
            return false
        }
    }

    // ------------------------------------------------------------------ effekter (bruges af julekalenderen)
    func triggerEffect(_ effect: Int) {
        switch effect {
        case 1: launchSanta()
        case 2: stormUntil = time + 25
        case 3: nisseParty()
        case 4: starShower()
        case 5: launchSanta(); starShower(); nisseParty()
        default: break
        }
    }

    // ------------------------------------------------------------------ sneplov
    /// One plow run in global coordinates, driving continuously across side-by-side screens (like Santa).
    final class PlowRun {
        var active = false
        var gx: F = 0, dir: F = 1, nextDir: F = 1, wheel: F = 0, pushed: F = 0, cooldown: F = 20
        var minX: F = 0, maxX: F = 0
        var members = Set<ObjectIdentifier>()
    }
    let plow = PlowRun()
    private let plowSpeed: F = 170, plowScale: F = 1.15

    /// Sends the plow out now (menu, --sneplov), starting from the main screen's row of screens.
    func sendPlow() {
        if let o = overlays.first(where: { $0.isPrimary }) ?? overlays.first { startPlow(from: o) }
    }

    private func startPlow(from start: ScreenOverlay) {
        if plow.active { return }
        // all screens joined edge to edge with the starting screen, left and right
        var row = [start]
        var grew = true
        while grew {
            grew = false
            let lo = row.map { $0.screenBounds.minX }.min()!, hi = row.map { $0.screenBounds.maxX }.max()!
            for o in overlays where !row.contains(where: { $0 === o }) {
                let b = o.screenBounds
                if abs(b.maxX - lo) < 2 || abs(b.minX - hi) < 2 { row.append(o); grew = true }
            }
        }
        plow.minX = row.map { $0.screenBounds.minX }.min()!
        plow.maxX = row.map { $0.screenBounds.maxX }.max()!
        plow.members = Set(row.map { ObjectIdentifier($0) })
        plow.dir = plow.nextDir
        plow.nextDir = -plow.nextDir
        let sc = start.S * plowScale
        plow.gx = plow.dir > 0 ? plow.minX - 110 * sc : plow.maxX + 110 * sc
        plow.pushed = 0
        plow.active = true
        ErrorLog.debug("plow start dir=\(plow.dir) from \(plow.minX) to \(plow.maxX)")
    }

    private func updatePlow(_ dt: F) {
        if !plow.active {
            plow.cooldown -= dt
            if cfg.plow && plow.cooldown <= 0, let o = overlays.first(where: { $0.heapAverage > 18 * $0.S * 0.75 }) { startPlow(from: o) }
            return
        }
        // speed and size follow the screen the truck is on
        let here = overlays.first { plow.members.contains(ObjectIdentifier($0)) && plow.gx >= $0.screenBounds.minX && plow.gx < $0.screenBounds.maxX }
            ?? overlays.first { plow.members.contains(ObjectIdentifier($0)) }
        let s = here?.S ?? 1
        plow.gx += plow.dir * plowSpeed * s * dt
        plow.wheel += plowSpeed * s * dt / (10 * s * plowScale)
        if (plow.dir > 0 && plow.gx > plow.maxX + 260 * s * plowScale) || (plow.dir < 0 && plow.gx < plow.minX - 260 * s * plowScale) {
            plow.active = false
            plow.cooldown = 30
            ErrorLog.debug("plow done")
        }
    }

    func sendPlowAfter(_ seconds: Double) { plowAt = time + (seconds > 0 ? seconds : 0) }

    private func nisseParty() { for o in overlays { o.nisseWave(6) } }

    private func starShower() {
        for o in overlays {
            let b = o.screenBounds
            for _ in 0..<90 {
                let sp = Spark()
                sp.x = b.minX + R() * b.width
                sp.y = b.minY - R() * b.height * 0.8
                sp.vx = (R() - 0.5) * 20 * o.S
                sp.vy = (140 + R() * 140) * o.S
                sp.max = 5 + R() * 3; sp.life = sp.max
                sp.size = (3 + R() * 4) * o.S
                sp.gold = R() < 0.8
                sp.star = true
                sparks.append(sp)
            }
        }
    }

    private func snowmanCelebrate() {
        guard cfg.snowman else { return }
        for o in overlays {
            guard o.isPrimary, let p = o.snowmanPos else { continue }
            let s = o.S
            for _ in 0..<70 {
                let sp = Spark()
                sp.x = p.x + (R() - 0.5) * 90 * s
                sp.y = p.y - R() * 120 * s
                sp.vx = (R() - 0.5) * 60 * s
                sp.vy = -(20 + R() * 60) * s
                sp.max = 1.5 + R() * 1.5; sp.life = sp.max
                sp.size = (2 + R() * 3) * s
                sp.gold = R() < 0.6
                sparks.append(sp)
            }
        }
    }

    // ------------------------------------------------------------------ daglige begivenheder
    private func updateDaily(startup: Bool) {
        let today = JuleClock.today
        lastDay = today
        CalendarContent.syncYear(cfg, today)
        snowmanStage = max(1, min(Self.snowmanMaxStage, JuleClock.days(from: cfg.firstRun ?? today, to: today) + 1))

        var title: String?, msg: String?, opensCalendar = false
        if snowmanStage > cfg.snowmanSeenStage {
            if cfg.snowmanSeenStage > 0 && cfg.snowman {
                title = "Snemanden vokser!"
                msg = "Nisserne har bygget videre på snemanden. I dag fik den " + Self.snowmanSteps[snowmanStage - 1]
                celebrateAt = time + 2
            }
            cfg.snowmanSeenStage = snowmanStage
            cfg.save()
        }
        let d = JuleClock.parts(today)
        if d.month == 12 && d.day <= 24 && !cfg.openedDoors.contains(d.day) && cfg.lastDoorNotice != today {
            title = "Dagens låge er klar!"
            msg = "Låge \(d.day) i julekalenderen venter på dig. Klik her for at åbne kalenderen."
            opensCalendar = true
            cfg.lastDoorNotice = today
            cfg.save()
        }
        if msg == nil && startup {
            title = "Jule-hygge er tændt"
            msg = "Klik på snefnug-ikonet i menulinjen for indstillinger og julekalender."
        }
        if let title, let msg { notify(title, msg, opensCalendar: opensCalendar) }
    }

    private func notify(_ title: String, _ body: String, opensCalendar: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["kalender": opensCalendar]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { err in
            if let err { ErrorLog.write("notification: \(err)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let opens = response.notification.request.content.userInfo["kalender"] as? Bool ?? false
        DispatchQueue.main.async { if opens { self.showCalendar() } }
        completionHandler()
    }

    func showCalendar() {
        if calendarWindow == nil { calendarWindow = CalendarWindow(controller: self) { [weak self] in self?.calendarWindow = nil } }
        NSApp.activate(ignoringOtherApps: true)
        calendarWindow?.makeKeyAndOrderFront(nil)
    }

    // ------------------------------------------------------------------ menulinje-ikon og menu
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = AppIcon.menuBarImage
        statusItem.button?.toolTip = "Jule-hygge"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let cal = item("Julekalender…") { [unowned self] _ in showCalendar() }
        cal.attributedTitle = NSAttributedString(string: "Julekalender…", attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(cal)
        countdownItem = NSMenuItem(title: Self.countdown(), action: nil, keyEquivalent: "")
        countdownItem.isEnabled = false
        menu.addItem(countdownItem)
        menu.addItem(.separator())

        menu.addItem(toggle("Snevejr", { $0.snow }, { $0.snow = $1 }))
        menu.addItem(choice("Snemængde", ["Let sne", "Normal", "Snestorm"], [0, 1, 2], { $0.snowLevel }, { $0.snowLevel = $1 }))
        menu.addItem(toggle("Sne i bunden af skærmen", { $0.snowGround }, { $0.snowGround = $1 }))
        snowmanItem = toggle("Snemand", { $0.snowman }, { $0.snowman = $1 })
        menu.addItem(snowmanItem)
        menu.addItem(.separator())

        menu.addItem(toggle("Julemanden", { $0.santa }, { $0.santa = $1 }))
        menu.addItem(item("Send julemanden afsted nu!") { [unowned self] _ in launchSanta() })
        menu.addItem(.separator())

        menu.addItem(toggle("Sneplov rydder sneen", { $0.plow }, { $0.plow = $1 }))
        menu.addItem(item("Send sneploven ud nu!") { [unowned self] _ in sendPlow() })
        menu.addItem(.separator())

        menu.addItem(toggle("Nisser", { $0.nisser }, { $0.nisser = $1 }))
        menu.addItem(choice("Antal nisser pr. skærm", ["1", "2", "3", "5", "8", "12"], [1, 2, 3, 5, 8, 12], { $0.nisseCount }, { $0.nisseCount = $1 }))
        menu.addItem(.separator())

        menu.addItem(choice("Strømspare",
                            ["Fra - fuld sne på hele skærmen", "Til - sne kun nederst, stille blæser", "Kun på batteri eller i strømsparetilstand"],
                            [0, 1, 2], { $0.powerSave }, { [unowned self] in $0.powerSave = $1; updatePowerSave() }))
        menu.addItem(choice("Billedfrekvens",
                            ["12 billeder/s - mindst strøm", "20 billeder/s - normal", "30 billeder/s - glattere sne", "60 billeder/s - helt glat, mest strøm"],
                            [12, 20, 30, 60], { $0.frameRate }, { [unowned self] in $0.frameRate = $1; startTimer() }))
        menu.addItem(toggle("Julelys", { $0.lights }, { $0.lights = $1 }))
        menu.addItem(toggle("Vis på alle skærme", { $0.allScreens }, { [unowned self] in $0.allScreens = $1; buildOverlays() }))
        menu.addItem(toggle("Pause ved fuldskærm (spil/film)", { $0.pauseFullscreen }, { $0.pauseFullscreen = $1 }))
        autostartItem = item("Start ved login") { it in
            Self.setAutostart(!Self.autostart)
            it.state = Self.autostart ? .on : .off
        }
        menu.addItem(autostartItem)
        menu.addItem(.separator())
        menu.addItem(item("Afslut") { [unowned self] _ in exit() })
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        countdownItem.title = Self.countdown()
        snowmanItem.title = "Snemand (trin \(snowmanStage) af \(Self.snowmanMaxStage))"
        autostartItem.state = Self.autostart ? .on : .off
    }

    private func item(_ title: String, _ action: @escaping (NSMenuItem) -> Void) -> NSMenuItem {
        let a = MenuAction(action)
        menuActions.append(a)
        let it = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
        it.target = a
        return it
    }

    private func toggle(_ title: String, _ get: @escaping (Settings) -> Bool, _ set: @escaping (Settings, Bool) -> Void) -> NSMenuItem {
        let it = item(title) { [unowned self] it in
            set(cfg, !get(cfg))
            it.state = get(cfg) ? .on : .off
            cfg.save()
        }
        it.state = get(cfg) ? .on : .off
        return it
    }

    private func choice(_ title: String, _ names: [String], _ values: [Int], _ get: @escaping (Settings) -> Int,
                        _ set: @escaping (Settings, Int) -> Void) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for (name, v) in zip(names, values) {
            let it = item(name) { [unowned self] _ in
                set(cfg, v)
                for o in sub.items { o.state = o.tag == v ? .on : .off }
                cfg.save()
            }
            it.tag = v
            it.state = get(cfg) == v ? .on : .off
            sub.addItem(it)
        }
        parent.submenu = sub
        return parent
    }

    private func exit() {
        stopTicker()
        calendarWindow?.close()
        for o in overlays { o.close() }
        overlays.removeAll()
        cfg.save()
        NSApp.terminate(nil)
    }

    static func countdown() -> String {
        let today = JuleClock.today
        let y = JuleClock.parts(today).year
        var eve = JuleClock.make(y, 12, 24)
        if today > eve { eve = JuleClock.make(y + 1, 12, 24) }
        let d = JuleClock.days(from: today, to: eve)
        if d == 0 { return "★ Glædelig jul! ★" }
        if d == 1 { return "★ 1 dag til juleaften ★" }
        return "★ \(d) dage til juleaften ★"
    }

    static var autostart: Bool { SMAppService.mainApp.status == .enabled }

    static func setAutostart(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { ErrorLog.write("autostart: \(error)") }
    }
}

/// Lets a closure be the target of a menu item.
final class MenuAction: NSObject {
    let action: (NSMenuItem) -> Void
    init(_ action: @escaping (NSMenuItem) -> Void) { self.action = action }
    @objc func run(_ sender: NSMenuItem) { action(sender) }
}
