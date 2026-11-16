# JuleHygge som baggrund i Teams — undersøgelse (2026-11-16)

> **Status:** Mulighed A (virtuelt kamera) er bygget, se "JuleHygge Kamera" i `macos/README.md`. Kode, udvidelse og Xcode-projekt er klar. Det er signeret med teamets Apple Development-certifikat og testet i Photo Booth og Microsoft Teams (2026-11-16). Lyden kommer ikke med i Teams, for den spilles kun lokalt (en virtuel mikrofon er fravalgt).

**Ønske:** Når et Teams-møde kører, skal juleoverlayet (sne, nisser, julemand osv.) vises som baggrund bag brugeren i Teams, som om det var en tredje skærm.

## Hvad Teams selv kan
- Almindelige møder: brugeren kan uploade egne **stillbilleder** (JPEG/PNG) som baggrund under *Videoeffekter*. Der er ingen understøttelse af egne video- eller animerede baggrunde. Microsofts upload-funktion for town halls (2026) er også kun billeder, og standardmøder er uændrede.
- Teams har ingen API til, at en anden app kan levere en levende baggrund.

## Muligheder

### A. Virtuelt kamera (den eneste vej til en levende, animeret baggrund)
En **CoreMediaIO Camera Extension** ("JuleHygge Kamera"), som brugeren vælger som kamera i Teams:
1. Læs det rigtige kamera (AVCaptureSession).
2. Udskær personen med Vision (`VNGeneratePersonSegmentationRequest`, eller `AVCaptureDevice` med indbygget segmentering).
3. Tegn julescenen offscreen i 1280×720/1920×1080 som en "virtuel tredje skærm", altså de samme figurer som overlayet: snevejr, julelys, nisser, snemand og julemand.
4. Læg personen ovenpå og send billedet ud som kamera.

Detektion af et møde er ikke nødvendig. Scenen kører kun, når Teams bruger kameraet (extensionen får start/stop-kald).

**Forhindringer:**
- **Kræver Apple Developer Program (99 USD/år):** System extensions kræver den begrænsede entitlement `com.apple.developer.system-extension.install` med Developer ID-provisioneringsprofil for både app og extension, plus notarisering. Den nuværende ad-hoc-signering kan ikke installere en camera extension.
- Appen skal ligge i `/Applications`, og brugeren skal godkende udvidelsen i Systemindstillinger. Teams skal have adgang til kameraet.
- Teams på Mac har tidligere haft perioder, hvor virtuelle kameraer ikke virkede. Det skal testes med den aktuelle Teams-version.
- Der er rapporter om fejl ved installation af nye CMIO-udvidelser ("no policy", kode 4) på macOS 26.5. Det er uafklaret for macOS 27.
- Strøm: segmentering og 30 fps-komposition koster mærkbart, men kun mens kameraet er i brug.
- Kvalitet: Teams' egen baggrundssløring/-udskiftning skal være slået fra, ellers konkurrerer de.

**Omfang:** Ny extension-target (kræver Xcode-projekt, ikke kun Swift Package), en delt tegnemotor (scenen genbruges offscreen), segmentering og komposition, samt installation og aktivering i appen. Nogle dages arbejde, når signering er på plads.

### B. Dagens julebillede som stillbillede (virker med det samme, ingen signering)
Appen gemmer et 1920×1080 PNG af dagens scene: snemanden på dagens trin, julelys, nisser og lidt sne, eventuelt med dagens låge. Brugeren uploader det under *Videoeffekter → Tilføj nyt* i Teams. Det kan være et menupunkt "Gem dagens Teams-baggrund…".
- Det er ikke animeret, men følger juleforløbet dag for dag.
- Automatisk placering direkte i Teams' interne mappe for uploadede baggrunde er muligt, men udokumenteret og skrøbeligt. Det frarådes.

## Anbefaling
Byg **B** nu (lille, sikker, ingen certifikater). Tag stilling til **A**, hvis der er et Apple Developer-medlemskab til rådighed. Så kan det bygges som en rigtig "tredje skærm" bag dig i mødet.

## Kilder
- [Microsoft Message Center MC1307982 – custom backgrounds (kun billeder)](https://mc.merill.net/message/MC1307982)
- [Roadmap RM410366 – brugeruploadede baggrundsbilleder](https://mc.merill.net/message/RM410366)
- [Apple: Core Media I/O](https://developer.apple.com/documentation/coremediaio)
- [WWDC22: Create camera extensions with Core Media IO](https://developer.apple.com/videos/play/wwdc2022-10022)
- [Apple Developer Forums: CMIO extension – ugyldig signatur/manglende entitlement](https://developer.apple.com/forums/thread/736838)
- [Apple Developer Forums: manglende `system-extension.install`](https://developer.apple.com/forums/thread/793731)
- [Apple Developer Forums: CMIO "no policy" på 26.5](https://developer.apple.com/forums/thread/840312)
- [Apple Developer Forums: virtuelle kameraer og Teams på macOS](https://developer.apple.com/forums/thread/656944)
- [ManyCam: problemer med virtuelle kameraer i Teams](https://forum.manycam.com/t/issues-with-ms-teams/3090)
