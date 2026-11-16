# AGENTS.md

JuleHygge er et juleoverlay til Windows (WinForms, .NET Framework 4.x) i `src/`, og en native macOS-udgave (Swift/AppKit) i `macos/`. Al brugervendt tekst er på **dansk**.

## Byg
- Byg med `powershell -ExecutionPolicy Bypass -File .\build.ps1`. Den bruger den `csc.exe`, der følger med Windows. Der er **intet .NET SDK** på maskinen, og der må ikke bruges NuGet-pakker.
- Compileren forstår kun **C# 5**: ingen `$"..."`, `?.`, `nameof`, `out var`, expression-bodied members eller initializers på auto-properties.
- **Luk programmet før du bygger** (`Stop-Process -Name JuleHygge`). Ellers er `JuleHygge.exe` låst, og bygget fejler.
- `build.ps1` bruger `/codepage:65001`, så kildefiler skal være UTF-8 (æøå i strenge).

## Test
- `--kalender` åbner julekalenderen ved opstart.
- Miljøvariablen `JULE_DATE=yyyy-MM-dd` får programmet til at tro, at det er en anden dato.
- **Pas på:** En test med en falsk dato skriver åbnede låger og snemandens trin til den rigtige `%APPDATA%\JuleHygge\settings.ini`. Tag en backup af filen før testen, og sæt den tilbage bagefter.
- Der er ingen automatiske tests. Kontrollér visuelt med skærmbilleder. `CopyFromScreen` fanger overlay-vinduerne, og processen skal være DPI-aware, ellers bliver koordinaterne forkerte.

## Ydelse
- Brugeren har **tre skærme**: 3456×2160 og 2× 4480×2520 (175 % skalering). Hver frame bliver lagt oven på skærmen med `UpdateLayeredWindow` i fuld skærmstørrelse, og det koster både CPU og GPU (dwm). Blæseren i den bærbare kan høres.
- Hold derfor fast i de optimeringer, der er lavet:
  - Kun de områder, der blev tegnet i forrige frame, ryddes (`Mark()` og `ClearRects`).
  - Snefnug tegnes direkte i pixelbufferen (`BlendDot`).
  - Julelysene caches som et billede.
  - Antallet af fnug skaleres efter den logiske skærmstørrelse.
- Alt nyt, der tegnes, **skal** registreres med `Mark()`. Ellers bliver det liggende på skærmen som spor.
- Mål CPU-forbruget før og efter ændringer i tegnekoden.

## Konventioner
- Ingen billed- eller lydfiler. Al grafik tegnes i koden med GDI+.
- Figurerne skal være originale: dansk nisse med rød hue og gråt tøj, ingen kendte figurer.
- Indstillinger gemmes i `Settings`. Nye felter skal have en standardværdi, så gamle `settings.ini`-filer stadig virker.
- Fakta i `CalendarContent` er ikke kildetjekket. Tjek dem, før der tilføjes nye.

## Git
- Git og `gh` er installeret, men ligger måske ikke på PATH i ældre shells. Brug i så fald `C:\Program Files\Git\cmd\git.exe` og `C:\Program Files\GitHub CLI\gh.exe`.
- Remote: `rkl1976/christmas` on GitHub. Releases are created with `gh release create` and include the built `JuleHygge.exe`.

## macOS (`macos/`)
- Byg med `macos/build.sh` (Swift Package + `.app`-bundle, ad-hoc-signeret). Luk appen først: `pkill -x JuleHygge`.
- Ændringer i figurer/logik bør laves i **begge** udgaver. Tegnekoden i `Overlay.swift` følger `src/Layer.cs` linje for linje (origo øverst til venstre).
- Skærmbilleder kræver skærmoptagelsestilladelse. Brug i stedet `--snapshot=MAPPE[,SEK]`, som gemmer overlayet som PNG.
- Brug `JULE_SETTINGS=<sti i projektet>` ved test med `JULE_DATE`, så de rigtige indstillinger ikke ændres.
- **Strøm:** Mål med `macos/measure.sh` før og efter ændringer i tegnekoden — både app og WindowServer. Brug ikke Core Animation-animationer (de kører med 120 Hz); alt drives af den fælles timer. Se afsnittet "Strømforbrug" i `macos/README.md`.
- Figurernes tegne-closures må aldrig holde overlayet som `unowned` (brug `[weak self]`): ved skærmskift kan AppKit bede et lag tegne, mens overlayet nedlægges. Det crashede appen, da en ekstern skærm blev taget ud (rettet 2026-11-16).
- Genstart efter crash klares af vagtprocessen i `main.swift`, ikke af en launch agent: `SMAppService.agent` er bundet til kodesignaturen og afvises efter hver ad-hoc-build. Når du tester med `build/`-kopien, så luk først den installerede app (`osascript -e 'tell application id "dk.julehygge.JuleHygge" to quit'`), ellers lukker testkopien sig selv (kun én ad gangen).
- **JuleHygge Kamera** (`macos/CameraExtension/`, `VirtualCamera.swift`): byg og installér med `macos/xcbuild.sh` (Xcode-projektet genereres af `tools/make-xcodeproj.py`). Erfaringer:
  - CoreMediaIO angiver strømmens retning set fra enheden: billedet apps læser er "input" (1), og udvidelsens sink er "output" (0). Det modsatte valg fylder sink-køen med udvidelsens egne billeder (rettet 2026-11-16).
  - Udvidelsens egne `Logger`-linjer kommer ikke frem i `log show`/`log stream` (den kører som systembruger). Fejlsøg fra appens side eller via en egen egenskab.
  - En ny version af udvidelsen (hæv `CFBundleVersion`) kræver typisk en genstart af Mac'en, før den nye kører. Ændringer kun i appen kræver ingen genstart.
  - Brug ikke `CALayer.render(in:)` til kamerabaggrunden. Den laver en offscreen-buffer for hvert lag med gennemsigtighed (~900 ms for ~260 snefnug). `ScreenOverlay.renderSceneImage()` tegner lagtræet selv (~10 ms). `CARenderer` gav kun magenta på macOS 27.
  - Vision-masken er 512×384 (4:3), mens kameraet er 1920×1080 (16:9). Stræk masken til kamerabilledet, og flyt begge med samme transformation. Beregn masken for hvert billede, ellers halter kanten.
  - `timeout` findes ikke på macOS. Kør `log stream` i baggrunden og stop den med `kill`.
- Lyd (kun macOS) syntetiseres i `Sound.swift` — stadig ingen lydfiler. Lyd skal altid være slået fra som standard.
- Alt, der er "på vej" (julemanden, sneploven, deres lyd), skal afsluttes i `finishRuns()`, når overlayet stopper (pauseskærm, skærmsøvn, lås). Ellers hænger turen, når timeren står stille, og melodien looper (rettet 2026-11-16).
- Sne på vinduer (`WindowSnow.swift`): bunkerne ligger i globale koordinater i `Controller.ledges` og tegnes af hvert overlay, de krydser. Sneen hører til vinduets sidst stillestående placering (`settled`): under minimering krymper vinduet ind i Dock'en, og sneen skal falde fra det oprindelige sted. Tegn kun strækninger, hvor der faktisk ligger sne (ellers ses en tynd hvid streg på bare kanter).
- Nissehuen (`Hat.swift`): placér den ud fra hovedets omrids i udskæringsmasken, ikke kun ud fra ansigtsrammen. Ansigtet sidder foran hovedets midte, så et gæt ud fra rammen rammer forkert, når hovedet drejes. Mål størrelsen ud fra rammens højde (bredden skrumper, når hovedet drejes). Ved test på et skærmbillede tæller en allerede tegnet hue med i masken.
- `measure.sh` måler den nyeste JuleHygge-proces; den anden er vagtprocessen.
- Test-appen skal køre som `.app` (`build/JuleHygge.app`, ikke `.build/release/JuleHygge`), ellers crasher UserNotifications. Brug `JULE_LOG` og `JULE_SETTINGS` med stier i projektet.
- Se `macos/README.md` for testparametre og `docs/macos-plan.md` for designvalg.
