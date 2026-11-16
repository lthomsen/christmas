import AppKit
import SystemExtensions

/// Installs and removes the "JuleHygge Kamera" system extension (only works in the Xcode-built app in /Applications).
final class CameraInstaller: NSObject, OSSystemExtensionRequestDelegate {
    static let extensionID = "dk.julehygge.JuleHygge.Camera"
    private var removing = false

    func install() { submit(OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main), removing: false) }
    func remove() { submit(OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main), removing: true) }

    private func submit(_ r: OSSystemExtensionRequest, removing: Bool) {
        if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            alert("JuleHygge skal ligge i mappen Programmer",
                  "macOS installerer kun kameraudvidelser fra apps i /Programmer. Installér med macos/xcbuild.sh og prøv igen.")
            return
        }
        self.removing = removing
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        alert("Godkend JuleHygge Kamera",
              "Åbn Systemindstillinger > Generelt > Login-emner og udvidelser > Kameraudvidelser, og slå JuleHygge Kamera til. Vælg derefter \"JuleHygge Kamera\" som kamera i Teams.")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if removing {
            alert("JuleHygge Kamera er fjernet", result == .willCompleteAfterReboot ? "Det forsvinder helt efter en genstart." : "")
        } else {
            alert("JuleHygge Kamera er klar",
                  "Vælg \"JuleHygge Kamera\" som kamera i Teams (Indstillinger > Enheder). Slå Teams' egen baggrund fra, så du står foran julescenen."
                  + (result == .willCompleteAfterReboot ? "\n\nDet bliver aktivt efter en genstart." : ""))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        ErrorLog.write("camera extension: \(error)")
        alert(removing ? "Kunne ikke fjerne JuleHygge Kamera" : "Kunne ikke installere JuleHygge Kamera", error.localizedDescription)
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
