# JuleHygge til macOS 🎄

Native macOS-udgave (Swift + AppKit + Core Animation) af juleoverlayet. Samme indhold som Windows-versionen: snevejr, sne der lægger sig i bunden af skærmen, julemanden med rensdyr på tværs af skærme, nisser, julelys under menulinjen, snemand der bygges over 12 dage, sneplov og julekalender med 24 låger.

- Bor i **menulinjen** (snefnug-ikonet), ingen Dock-ikon. Klik på ikonet for indstillinger og julekalender.
- Overlayet ligger over alle vinduer og Docken, men man klikker igennem det. Det følger med til alle Spaces.
- Sne og nisser ligger i **bunden af skærmen** på alle skærme.
- Pauser automatisk, når en app kører i fuldskærm (kan slås fra).
- **Strømspare** slår til på batteri eller i macOS' strømsparetilstand: sne kun nederst og 20 i stedet for 30 billeder/s.
- Notifikationer når dagens låge er klar (klik åbner kalenderen).
- "Start ved login" i menuen bruger `SMAppService`.
- Indstillinger: `~/Library/Application Support/JuleHygge/settings.ini` (samme format som Windows). Fejllog: `~/Library/Logs/JuleHygge.log`.

## Byg og kør

Kræver Xcode eller Command Line Tools (Swift 5.10+), macOS 14+.

```bash
./build.sh
```

```bash
open build/JuleHygge.app
```

Læg evt. `build/JuleHygge.app` i `/Programmer`, så "Start ved login" virker stabilt. Appen er ad-hoc-signeret; til distribution kræves Developer ID-signering og notarisering.

## Test

| Parameter / miljøvariabel | Effekt |
|---|---|
| `--kalender` | åbner julekalenderen ved start |
| `--julemand` | sender julemanden afsted med det samme |
| `--sneplov` / `--sneplov=N` | sender sneploven ud efter 3 / N sekunder |
| `--effekt=N` | kalendereffekt: 1 julemand, 2 snestorm, 3 nissefest, 4 stjerneregn, 5 det hele |
| `--snapshot=MAPPE[,SEK]` | gemmer overlay pr. skærm (og kalenderen) som PNG efter SEK sekunder — kræver ikke skærmoptagelsestilladelse |
| `JULE_DATE=yyyy-MM-dd` | lader som om det er en anden dato |
| `JULE_SETTINGS=sti` | brug en anden settings-fil (så tests ikke ændrer de rigtige indstillinger) |
| `JULE_DEBUG=1` | debuglinjer i fejlloggen |

Eksempel (kør binæren direkte for at kunne sætte miljøvariabler):

```bash
JULE_SETTINGS=$PWD/build/test.ini JULE_DATE=2026-12-13 build/JuleHygge.app/Contents/MacOS/JuleHygge --kalender --julemand --snapshot=$PWD/build/shots,4
```

## Kode

| Fil | Indhold |
|-----|---------|
| `Sources/JuleHygge/main.swift` | Opstart, én instans, kommandolinje |
| `Sources/JuleHygge/Controller.swift` | Menulinje-menu, hovedløkke, julemanden, effekter, daglige notifikationer, strøm, fuldskærm, autostart |
| `Sources/JuleHygge/Overlay.swift` | Ét klik-igennem vindue pr. skærm: sne, sneplov, nisser, julelys, snemand |
| `Sources/JuleHygge/Calendar.swift` | Julekalender-vinduet og indholdet bag lågerne |
| `Sources/JuleHygge/Settings.swift` | Indlæsning og gemning af indstillinger |
| `Sources/JuleHygge/Icon.swift` | Snefnug-ikonet (menulinje og app-ikon, tegnes i koden) |
| `Sources/JuleHygge/Util.swift` | Dato, log, dataklasser og GDI+-agtige tegnehjælpere |

### Tegning
Hver figur (julemanden, nisser, snemand, sneplov, julelys) er et lille `CALayer`, der kun gentegnes i sin egen størrelse. Snefnug, gnister og sneklumper er genbrugte billedlag, som kun flyttes. Snedriven er et `CAShapeLayer`. Al sammensætning sker på GPU'en, så der er ingen dirty-rect-håndtering som i Windows-versionen. Tegnekoden bruger skærmkoordinater med origo øverst til venstre, så den kan sammenlignes linje for linje med `src/Layer.cs`.
