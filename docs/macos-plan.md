# JuleHygge på macOS — analyse og plan

> **Status (2026-11-16):** Alle fem faser er implementeret i `macos/` (native Swift + AppKit + Core Animation). Distribution med Developer ID/notarisering mangler stadig. Se `macos/README.md`.

## Udgangspunkt
Windows-versionen (~2.450 linjer C# 5, WinForms + GDI+, .NET Framework 4.x) er tæt bundet til Win32:

| Windows-del | Hvor | macOS-modstykke |
|---|---|---|
| `WS_EX_LAYERED/TRANSPARENT/TOPMOST/TOOLWINDOW` overlay pr. skærm | `Layer.cs` | Borderless `NSPanel`/`NSWindow`, `isOpaque=false`, `backgroundColor=.clear`, `ignoresMouseEvents=true`, `level=.statusBar`/`.screenSaver`, `collectionBehavior=[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]` |
| `UpdateLayeredWindow(Indirect)` + DIB-pixelbuffer + dirty rects | `Layer.cs` | Core Animation / SpriteKit / Metal — GPU-komposition gør det manuelle dirty-rect-arbejde overflødigt |
| GDI+ (`Graphics`, `GraphicsPath`) til figurer | `Layer.cs`, `Calendar.cs` | Core Graphics (`CGContext`, `CGPath`) — næsten 1:1 API |
| Bakkeikon (`NotifyIcon`) + kontekstmenu + balloon | `Controller.cs` | `NSStatusItem` i menulinjen + `NSMenu`; `UNUserNotificationCenter` til "dagens låge er klar" |
| Proceslinjen (sne, nisser, sneplov, snemand) | `Layer.cs` | **Bunden af skærmen** (besluttet). Jorden er `NSScreen.frame.minY` på alle skærme, uanset Dockens placering. Overlayet ligger over Docken, så sne og nisser kan dække Dock-ikoner — derfor holdes bunken lav. Svarer til Windows-versionens fuldskærmsadfærd (sne i skærmbunden). |
| Fuldskærmsdetektion (`GetForegroundWindow`, `GetClassName`) | `Controller.cs` | `NSWorkspace.activeSpaceDidChangeNotification` + `CGWindowListCopyWindowInfo` (fuldskærmsapps ligger i egen Space) |
| Batteri / power-save (`SystemInformation.PowerStatus`) | `Controller.cs` | IOKit `IOPSCopyPowerSourcesInfo` + `ProcessInfo.isLowPowerModeEnabled` |
| `Screen.AllScreens`, DPI | flere steder | `NSScreen.screens`, `backingScaleFactor`; `didChangeScreenParametersNotification` |
| `%APPDATA%\JuleHygge\settings.ini` | `Settings.cs` | `UserDefaults` (eller samme ini i `~/Library/Application Support/JuleHygge`) |
| Kalendervindue (WinForms `Form`) | `Calendar.cs` | SwiftUI-vindue eller `NSWindow` + custom `NSView` |
| Autostart (hvis relevant) | — | `SMAppService.mainApp.register()` |

Ren logik, der kan porteres direkte: `CalendarContent` (tekster), `JuleClock`/`JULE_DATE`, snemandens trin, effekt-tilstandsmaskinen, julemandens rute over tilstødende skærme.

## Muligheder
1. **Native Swift + AppKit (anbefalet).** Lille app, ingen runtime, bedst ydelse/batteri, adgang til alle macOS-API'er ovenfor. Tegnekoden oversættes GDI+ → Core Graphics næsten linje for linje; animation via `CADisplayLink` (macOS 14+) eller `CVDisplayLink`.
2. **.NET 9 + Avalonia.** Genbruger C#-logik, men overlay/klik-igennem/menulinje/Dock kræver alligevel native interop pr. platform, og `System.Drawing` virker ikke på macOS. Delt kodebase bliver mindre delt end man tror.
3. **Electron/Tauri.** Transparente klik-igennem-vinduer er mulige, men tungt for en baggrundsanimation, der skal køre hele december.

**Anbefaling:** Separat native macOS-app i samme repo (`macos/`), Swift Package / Xcode-projekt, og port logikken modul for modul. Windows-versionen forbliver urørt.

## Foreslået struktur
```
macos/JuleHygge/
  App.swift            // NSApplication, LSUIElement (ingen Dock-ikon), NSStatusItem + menu
  OverlayWindow.swift  // ét klik-igennem vindue pr. NSScreen
  SceneView.swift      // CALayer/SpriteKit-scene: sne, bunke, nisser, lys, snemand, sneplov
  Santa.swift          // julemanden + rensdyr på tværs af skærme
  Calendar/            // CalendarContent (porteret), CalendarView (SwiftUI)
  Settings.swift       // UserDefaults
  Power.swift          // batteri / low power mode
  Fullscreen.swift     // pause i fuldskærm
```

## Faser
1. **Skelet:** menulinjeikon, ét transparent klik-igennem overlay pr. skærm med snevejr. Mål CPU (mål < 2–3 % på Apple Silicon).
2. **Sne i skærmbunden:** bunke langs skærmens nederste kant på alle skærme, pause i fuldskærm, power-save på batteri.
3. **Figurer:** julelys, nisser, snemand (12 trin), sneplov, julemand med rensdyr på tværs af skærme.
4. **Julekalender:** port `CalendarContent`, SwiftUI-vindue, notifikationer, effekter (snestorm, nissefest, stjerneregn).
5. **Distribution:** signering + notarisering (Developer ID), `.dmg`/zip i GitHub Releases, evt. autostart via `SMAppService`.

## Åbne spørgsmål
- ~~Hvor skal sne/nisser bo?~~ Besluttet: **nederst på skærmen**.
- Minimum macOS-version (14 Sonoma giver `CADisplayLink` på macOS og nemmere SwiftUI)?
- Native Swift-port, eller er delt C#-kode (Avalonia) et krav?
