# Lyd fra julemand og sneplov i Teams — undersøgelse (2026-11-17)

> **Status:** Undersøgt, ikke bygget.

**Ønske:** De andre i et Teams-møde skal høre bjælderne, melodierne og sneploven, når julemanden eller sneploven kører i kamerabilledet.

## Hvorfor det ikke kan gå gennem kameraet
JuleHygge Kamera er en CoreMediaIO-udvidelse, og den leverer kun billede. Teams tager lyden fra den mikrofon, man har valgt i Teams' enhedsindstillinger. Lyden skal derfor ind via en mikrofon, som Teams kan vælge.

Lyden spiller allerede lokalt i højttalerne, når lyd er slået til. Den rigtige mikrofon fanger den dog dårligt: Teams' støjfjernelse og ekkodæmpning fjerner netop den slags lyd. Det kan ikke bruges.

## Muligheder

### A. "JuleHygge Mikrofon": en virtuel lydenhed som Core Audio-plug-in (anbefales)
Et **AudioServerPlugIn** (HAL-plug-in) i `/Library/Audio/Plug-Ins/HAL`. Det er samme teknik som BlackHole og Loopback bruger. Plug-in'et er en simpel **loopback**: en lydenhed med både en udgang og en indgang, hvor det, der sendes til udgangen, kommer ud af indgangen.

1. **Appen** optager den rigtige mikrofon (AVAudioEngine), blander bjælder, melodi og sneplov ind og sender resultatet til JuleHygge Mikrofons udgang.
2. **Teams:** I *Indstillinger → Enheder* vælger man **JuleHygge Mikrofon** som mikrofon. Teams hører så stemmen med julelydene blandet ind.
3. **Plug-in'et** indeholder ingen logik ud over loopbacken. Al blanding sker i appen, så der er ingen kommunikation mellem appen og plug-in'et ud over selve lyden.

**Detaljer:**
- **Kun lyden til mødet:** Mens JuleHygge Mikrofon er i brug, spilles julelydene ikke i højttalerne. Ellers fanger den rigtige mikrofon dem også, og de andre hører dem dobbelt.
- **Ingen stemme uden mikrofonadgang:** Appen beder om mikrofonadgang (`NSMicrophoneUsageDescription`). Uden adgang kommer stemmen ikke med.
- **Bjælder kun med kameraet:** Lydene blandes kun ind, når julemanden eller sneploven er i kamerabilledet, og kun hvis lyd er slået til.
- **Forsinkelse:** Ekstra lydforsinkelse er ca. 10–20 ms (en buffer i appen og en i plug-in'et), ikke til at høre i et møde.

**Forhindringer:**
- **Installation kræver administrator:**
  - Plug-in'et kopieres til `/Library/Audio/Plug-Ins/HAL`.
  - Core Audio skal genstartes (`sudo killall coreaudiod`), eller Mac'en genstartes.
  - Appen kan klare det med et menupunkt "Installér JuleHygge Mikrofon…", der beder om adgangskoden.
- **Signering:**
  - Ifølge et open source-projekt kræver macOS 26 og nyere et betalt Apple Developer-medlemskab for at indlæse egne HAL-drivere, mens ældre udgaver kan bruge ad hoc-signering. Det er ikke bekræftet af Apple.
  - Teamets certifikat (87YVYCK9JT) haves allerede.
- **Kendt faldgrube:** Et forumindlæg fra macOS 26.5 beskriver, at `StartIO` ikke kaldes for en AUHAL-indgangsklient. Det skal testes med Teams specifikt.
- **Teams' støjfjernelse:**
  - Den kan dæmpe musik og bjælder, også fra en virtuel mikrofon.
  - Brugeren bør sætte støjfjernelse til *Lav* eller *Fra*, eller slå *High-fidelity music mode* til.
  - Det skal stå i vejledningen.
- **Teams og virtuelle mikrofoner:** BlackHole anbefales i Microsofts eget forum til at få lyd ind i Teams. Jeg fandt dog ingen nyere bekræftelse for den nye Teams-klient. Det skal testes.
- **Lydmotoren:** Appens lydmotor sender i dag kun lyd til højttalerne. Når JuleHygge Mikrofon er i brug, skal der en ekstra lydmotor til, der optager mikrofonen og sender blandingen til den virtuelle enhed.

**Omfang:** Cirka 2–3 dages arbejde:
- **Plug-in'et:** skrives i C ud fra Apples eksempel "Creating an Audio Server Driver Plug-in" (NullAudio) og et loopback-design, ca. 800–1.200 linjer.
- **Xcode-target:** et nyt target til `.driver`-bundlet.
- **Appens del:** en lydmotor til mikrofonen, blandingen og valg af lydenhed.
- **Installation:** menupunktet til installation og afinstallation.
- **Test:** i Teams og Photo Booth/QuickTime-optagelse.

### B. AudioDriverKit (DriverKit-udvidelse)
Apples nyere måde at lave lyddrivere på. Den kræver entitlementen `com.apple.developer.driverkit.family.audio`. Den kan bruges frit under udvikling, men Apple skal godkende den til distribution. En udvikler rapporterer, at Apple afviste den til en **virtuel** lydenhed. Den vej er usikker og giver ingen fordele her.

### C. Gennem højttaleren
Ingen kode, men det virker ikke: Teams' ekkodæmpning og støjfjernelse fjerner lyden, og den kommer med ekko og rumklang.

### D. BlackHole eller Loopback, som brugeren selv installerer
Appen kan sende sin blanding til en enhed, som brugeren allerede har installeret. Det kræver ikke noget plug-in fra os, men brugeren skal selv installere et tredjepartsprogram og sætte det op. Det kan bygges som et lille ekstra menupunkt, "Send julelyde til…", og være vejen til at teste idéen, før A bygges.

## Anbefaling
1. **Test idéen først med D:** Byg blandingen i appen (mikrofon og julelyde) med valg af udgangsenhed, og test med BlackHole 2ch i Teams. Det afklarer om Teams' støjfjernelse og den nye Teams-klient spiller med (½–1 dag).
2. **Hvis det virker,** byg A, så JuleHygge leverer sin egen mikrofon og ikke afhænger af tredjepartssoftware.

## Kilder
- [Apple: Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- [xcbuild/loopback (HAL-plug-in, krav om udviklermedlemskab på macOS 26+)](https://github.com/xcbuild/loopback)
- [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole)
- [Apple Developer Forums: HAL-plug-in, StartIO kaldes ikke på 26.5](https://developer.apple.com/forums/thread/835816)
- [Apple Developer Forums: virtuel mikrofon på macOS](https://developer.apple.com/forums/thread/657619)
- [Apple Developer Forums: HAL-virtuel enhed som proxy for mikrofon](https://developer.apple.com/forums/thread/127413)
- [Apple Developer Forums: AudioDriverKit til virtuelle enheder](https://developer.apple.com/forums/thread/682035)
- [WWDC22: DriverKit-entitlements til udvikling/distribution](https://developer.apple.com/videos/play/wwdc2022/110373/)
- [Microsoft Tech Community: BlackHole til lyd i Teams fra en Mac](https://techcommunity.microsoft.com/discussions/microsoftteams/sharing-system-audio-in-teams-from-a-mac/1611410/replies/1980697)
- [Microsoft Teams Blog: støjfjernelse og High-fidelity music mode](https://techcommunity.microsoft.com/t5/microsoft-teams-blog/expanding-background-noise-suppression-across-platforms-and/ba-p/3300366)
