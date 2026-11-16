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

Installér i `~/Applications` med start ved login (login-elementet peger på den installerede kopi, så senere builds ikke ødelægger det):

```bash
./install.sh
```
Appen er ad-hoc-signeret; til distribution kræves Developer ID-signering og notarisering.

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
| `JULE_FPS=N` | fast billedfrekvens (til målinger) |
| `JULE_DEEPSNOW=1` | starter med fuld snedrive (til test af sneploven) |
| `JULE_TICKS=1` | skriver faktiske billeder/s til stderr |
| `--login=on` / `--login=off` | slår start ved login til/fra |

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
| `install.sh` / `measure.sh` | installation med start ved login / CPU-måling af app og WindowServer |
| `Sources/JuleHygge/Util.swift` | Dato, log, dataklasser og GDI+-agtige tegnehjælpere |

### Strømforbrug
Det dyre er ikke appens egen CPU, men at **WindowServer** skal sammensætte overlayet på ny ved hver ændring. Målt med `./measure.sh` (MacBook + 2560×1440-skærm, WindowServer ~12 % uden appen):

| | App | WindowServer ekstra | I alt |
|---|---|---|---|
| Første version (30 fps med Timer, alt gentegnet) | 27 % | ~21 % | ~48 % |
| Billedfrekvens 12 (også strømspare) | ~5 % | ~4 % | **~9 %** |
| Billedfrekvens 20 (standard) | ~8 % | ~10 % | **~18 %** |
| Billedfrekvens 30 | ~11 % | ~22 % | **~33 %** |
| Billedfrekvens 60 | ~19 % | ~36 % | **~55 %** |
| Mens julemanden flyver (60 fps, ~10-20 s ad gangen) | ~20 % | ~40 % | ~60 % |
| Mens sneploven kører, inkl. sne der sprøjter op (30 fps, ~25 s over to skærme) | ~15 % | ~14 % | ~29 % |

Billedfrekvensen for den rolige scene vælges i menuen **Billedfrekvens** (gemmes som `FrameRate`). Strømspare bruger højst 12. Separate frekvenser pr. element ville ikke spare noget: enhver ændring får WindowServer til at sammensætte overlayet, så det er det samlede antal opdateringer pr. sekund, der koster.

Valg der holder det nede:
- **Én fælles display link** (`NSScreen.displayLink`) og én `CATransaction` pr. frame. Den følger skærmens opdatering, så billederne kommer med helt jævne mellemrum (ved 20 fps på 120 Hz præcis hver 6. opdatering). En almindelig `Timer` driver i forhold til skærmen og får sneen til at hakke. Lav frekvens når scenen er rolig (20 fps / 12 fps i strømspare), 60 fps (30 i strømspare) kun mens julemanden flyver, og 30 fps (20) mens den langsomme sneplov kører.
- **Ingen Core Animation-animationer** (`CABasicAnimation` m.fl.): de kører altid med skærmens fulde frekvens (op til 120 Hz) og fik WindowServer op over 50 %. `preferredFrameRateRange` hjalp ikke.
- **Nisser** tegnes ikke pr. frame: hver positur (16 gangbilleder, 8 stå, 8 vinke) tegnes én gang pr. tøjvariant og genbruges; størrelse og retning er GPU-skalering.
- **Julelys**: ledning og slukkede pærer tegnes én gang; hver pæres lyse udgave er et færdigt billede, hvis gennemsigtighed ændres ~7 gange/s.
- Julemand og sneplov flyttes hver frame, men gentegnes kun hver anden. Snedriven opdateres 5 gange/s.
- Timeren stopper helt, når skærmen sover eller er låst.

### Tegning
Hver figur (julemanden, nisser, snemand, sneplov, julelys) er et lille `CALayer`, der kun gentegnes i sin egen størrelse. Snefnug, gnister og sneklumper er genbrugte billedlag, som kun flyttes. Sneploven køres af `Controller` i globale koordinater, så den kører én sammenhængende tur hen over skærme, der står ved siden af hinanden (ligesom julemanden). Snedriven er et `CAShapeLayer`. Al sammensætning sker på GPU'en, så der er ingen dirty-rect-håndtering som i Windows-versionen. Tegnekoden bruger skærmkoordinater med origo øverst til venstre, så den kan sammenlignes linje for linje med `src/Layer.cs`.
