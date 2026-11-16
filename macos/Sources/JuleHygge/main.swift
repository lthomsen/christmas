import AppKit

let args = CommandLine.arguments

// build.sh: write the app icon as an .iconset folder and quit.
if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
    AppIcon.writeIconset(to: args[i + 1])
    exit(0)
}

// Only one copy at a time.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; lives in the menu bar
if let icon = AppIcon.image(size: 512, background: true, scale: 1) { app.applicationIconImage = icon }

let controller = Controller()
if args.contains("--kalender") { controller.showCalendar() }
// --sneplov sends the snow plow after 3 s; --sneplov=N after N seconds (handy for testing).
for a in args {
    if a == "--sneplov" { controller.sendPlowAfter(3) }
    else if a.hasPrefix("--sneplov="), let s = Double(a.dropFirst(10)) { controller.sendPlowAfter(s) }
    // --julemand sends Santa right away, --effekt=N triggers a calendar effect (testing).
    else if a.hasPrefix("--snapshot=") {
        let parts = a.dropFirst(11).split(separator: ",")
        if let dir = parts.first { controller.snapshot = (String(dir), parts.count > 1 ? Double(parts[1]) ?? 5 : 5) }
    }
    else if a == "--julemand" { DispatchQueue.main.async { controller.launchSanta() } }
    else if a.hasPrefix("--effekt="), let n = Int(a.dropFirst(9)) { DispatchQueue.main.async { controller.triggerEffect(n) } }
}
app.run()
