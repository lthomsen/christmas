import Foundation
import CryptoKit

/// Self-update from GitHub releases, as in the Windows version (src/Updater.cs).
///
/// The macOS workflow builds JuleHygge.app with the release tag as its version and attaches it to the release as
/// JuleHygge-macOS.zip. The app asks the GitHub API for the latest release, downloads a newer zip, unpacks it next
/// to itself, checks it, and swaps the whole app bundle (a running app can be moved aside, not overwritten).
///
/// Only a release build updates itself:
/// - a local build has version 0.0.0 (build.sh without VERSION);
/// - a build with the JuleHygge Kamera extension (xcbuild.sh) never does: the release zip is ad-hoc signed and has
///   no camera extension, so installing it would remove the camera and the developer signature.
enum Updater {
    static let repo = "rkl1976/christmas"
    static let assetName = "JuleHygge-macOS.zip"
    static let bundleID = "dk.julehygge.JuleHygge"
    /// Tells the supervisor (main.swift) to start the new app and step down.
    static let restartExitCode: Int32 = 3

    /// "1.4", "1.4.0" and "v1.4.0" are the same version.
    struct Version: Comparable, CustomStringConvertible {
        var parts: [Int]
        init?(_ text: String) {
            var t = text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            let p = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !p.isEmpty, p.count <= 4, !p.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
            parts = p.map { $0! } + [Int](repeating: 0, count: 3 - min(3, p.count))
        }
        static let zero = Version("0.0.0")!
        static func < (a: Version, b: Version) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
        static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
        var description: String { parts.prefix(3).map(String.init).joined(separator: ".") }
    }

    /// The version stamped by build.sh (VERSION=x.y.z). JULE_UPDATE_VERSION=x.y.z pretends to be another version (testing).
    static var current: Version {
        if let over = ProcessInfo.processInfo.environment["JULE_UPDATE_VERSION"], let v = Version(over) { return v }
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(Version.init) ?? .zero
    }

    static var appURL: URL { Bundle.main.bundleURL }

    /// True when this app carries the JuleHygge Kamera extension.
    static var hasCamera: Bool {
        let dir = appURL.appendingPathComponent("Contents/Library/SystemExtensions")
        return !((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
    }

    static var isReleaseBuild: Bool { current > .zero && !hasCamera && appURL.pathExtension == "app" }

    /// Why this app does not update itself, for the menu.
    static var notUpdatingReason: String {
        hasCamera ? "Version med JuleHygge Kamera (opdaterer ikke)" : "Udviklerversion (opdaterer ikke)"
    }

    struct Result {
        var version: Version?     // the newer release; nil when this is the latest
        var newApp: URL?          // downloaded and verified app, ready to install
        var error: String?
    }

    private static var folder: URL { appURL.deletingLastPathComponent() }
    private static var staging: URL { folder.appendingPathComponent(".JuleHygge-opdatering") }

    /// Runs on a background queue: finds the latest release and, if it is newer and has the zip, downloads,
    /// unpacks and checks it.
    static func checkAndDownload() -> Result {
        var res = Result()
        cleanUp()
        // Test aid: JULE_UPDATE_ZIP=file with JULE_UPDATE_ZIP_VERSION=x.y.z stands in for GitHub's latest release,
        // so the whole update, restart included, can be tried on a copy of the app without publishing anything.
        let env = ProcessInfo.processInfo.environment
        if let path = env["JULE_UPDATE_ZIP"], let v = env["JULE_UPDATE_ZIP_VERSION"].flatMap(Version.init) {
            if v <= current { return res }
            guard let zip = FileManager.default.contents(atPath: path) else { res.error = "kan ikke læse \(path)"; return res }
            res.version = v
            let prepared = prepare(zip: zip, expected: v, digest: nil)
            res.newApp = prepared.app; res.error = prepared.error
            return res
        }
        guard let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return res }
        var req = URLRequest(url: api, timeoutInterval: 30)
        req.setValue("JuleHygge-Updater", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, problem) = fetch(req)
        guard let data else { res.error = problem ?? "intet svar fra GitHub"; return res }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { res.error = "ulæseligt svar fra GitHub"; return res }
        guard let tag = root["tag_name"] as? String, let remote = Version(tag) else {
            res.error = "ulæseligt versionsnummer: \(root["tag_name"] ?? "intet")"; return res
        }
        if remote <= current { return res }   // up to date

        var link: URL?, digest: String?
        for a in (root["assets"] as? [[String: Any]]) ?? [] where (a["name"] as? String)?.lowercased() == assetName.lowercased() {
            link = (a["browser_download_url"] as? String).flatMap(URL.init)
            digest = a["digest"] as? String
        }
        // The zip is attached by the workflow a few minutes after the release is published; try again later.
        guard let link else { ErrorLog.debug("update: \(tag) has no \(assetName) yet"); return res }
        res.version = remote

        // the app's own folder must be writable (and the new app is unpacked there, so the swap is a rename)
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            res.error = "kan ikke skrive i \(folder.path)"; return res
        }
        var get = URLRequest(url: link, timeoutInterval: 120)
        get.setValue("JuleHygge-Updater", forHTTPHeaderField: "User-Agent")
        get.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (zip, downloadProblem) = fetch(get)
        guard let zip else { res.error = downloadProblem ?? "kunne ikke hente \(assetName)"; return res }
        let prepared = prepare(zip: zip, expected: remote, digest: digest)
        res.newApp = prepared.app
        res.error = prepared.error
        if res.error == nil { ErrorLog.debug("update: downloaded \(tag)") }
        return res
    }

    /// Unpacks a downloaded zip beside the app and checks it. Returns the new app, or why it cannot be used.
    static func prepare(zip: Data, expected: Version, digest: String?) -> (app: URL?, error: String?) {
        // the file must match GitHub's SHA-256 digest (when given)
        if let digest, digest.lowercased().hasPrefix("sha256:") {
            let hash = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
            if hash != digest.dropFirst(7).lowercased() { return (nil, "den hentede fil passer ikke med sin SHA-256-sum") }
        }
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let file = staging.appendingPathComponent(assetName)
            try zip.write(to: file)
            guard run("/usr/bin/ditto", ["-x", "-k", file.path, staging.path]) == 0 else {
                try? fm.removeItem(at: staging); return (nil, "kunne ikke pakke den hentede fil ud")
            }
            try? fm.removeItem(at: file)
        } catch { try? fm.removeItem(at: staging); return (nil, "\(error.localizedDescription)") }
        let app = staging.appendingPathComponent("JuleHygge.app")
        if let why = verify(app, expected: expected) { try? fm.removeItem(at: staging); return (nil, why) }
        return (app, nil)
    }

    /// The unpacked app must be JuleHygge with exactly the release's version, without a camera extension, and
    /// with a valid (ad-hoc) signature, so a damaged download is never installed.
    private static func verify(_ app: URL, expected: Version) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            return "den hentede fil er ikke en app"
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else { return "den hentede app er ikke JuleHygge" }
        let found = (info["CFBundleShortVersionString"] as? String).flatMap(Version.init)
        guard found == expected else {
            return "den hentede app har version \(found?.description ?? "ukendt"), forventede \(expected)"
        }
        let exe = app.appendingPathComponent("Contents/MacOS/\(info["CFBundleExecutable"] as? String ?? "JuleHygge")")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { return "den hentede app mangler sit program" }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else { return "den hentede apps signatur er ikke gyldig" }
        return nil
    }

    /// Swaps the downloaded app in. Runs on the main thread right before the restart.
    static func install(_ newApp: URL) throws {
        let fm = FileManager.default
        // a unique name, because the old supervisor is still running from the old bundle
        let old = folder.appendingPathComponent("JuleHygge.old-\(Int(Date().timeIntervalSince1970)).app")
        try fm.moveItem(at: appURL, to: old)
        do { try fm.moveItem(at: newApp, to: appURL) }
        catch { try? fm.moveItem(at: old, to: appURL); throw error }
        try? fm.removeItem(at: staging)
    }

    /// Starts the app again from its place (now the new version) once this process has quit.
    static func relaunchAfterExit() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // (the path is passed as an argument, not pasted into the script)
        // The app's own test settings (JULE_…) follow it into the new version: `open` starts apps with a clean
        // environment otherwise, and a test would carry on with the real settings file.
        var open = ["/usr/bin/open"]
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("JULE_") && key != "JULE_SUPERVISOR" {
            open += ["--env", "\(key)=\(value)"]
        }
        p.arguments = ["-c", "sleep 1.5; exec \"$@\"", "sh"] + open + [appURL.path]
        try? p.run()
    }

    /// Removes leftovers from earlier updates.
    static func cleanUp() {
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("JuleHygge.old-") && name.hasSuffix(".app") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func fetch(_ request: URLRequest) -> (Data?, String?) {
        var out: (Data?, String?) = (nil, nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { out = (nil, error.localizedDescription) }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 { out = (nil, "GitHub svarede \(http.statusCode)") }
            else { out = (data, nil) }
            done.signal()
        }.resume()
        done.wait()
        return out
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Test aid (--opdatering-test=ZIP,VERSION): treats ZIP as a downloaded release of VERSION, unpacks and checks
    /// it and swaps it in for the app this is run from. Run it from a copy of the app, never the installed one.
    /// --opdatering-test=github,- only asks GitHub and downloads and checks a newer release, without installing.
    static func test(zip: String, version: String) {
        if zip == "github" {
            // the real check against GitHub, without installing anything
            print("denne app: version \(current), opdaterer selv: \(isReleaseBuild)")
            let r = checkAndDownload()
            print("nyere udgivelse: \(r.version?.description ?? "ingen"), hentet og godkendt: \(r.newApp != nil), fejl: \(r.error ?? "ingen")")
            cleanUp()
            return
        }
        guard let v = Version(version), let data = FileManager.default.contents(atPath: zip) else { print("kan ikke læse zip eller version"); return }
        print("denne app: \(appURL.path), version \(current), kamera \(hasCamera), opdaterer selv: \(isReleaseBuild)")
        cleanUp()
        let prepared = prepare(zip: data, expected: v, digest: nil)
        guard let app = prepared.app else { print("afvist:", prepared.error ?? "?"); return }
        do { try install(app); print("installeret version \(v) i \(appURL.path)") } catch { print("kunne ikke installere:", error.localizedDescription) }
    }
}
