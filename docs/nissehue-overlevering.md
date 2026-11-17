# Nissehue, skæg og nissedragt i JuleHygge Kamera — overlevering (2026-11-17)

Dette dokument er skrevet til den model, der overtager arbejdet. Det beskriver tre ting: hvad vi forsøgte at opnå, hvilke metoder der er prøvet, og hvorfor de fejlede.

Det er ikke en anbefaling. Den nuværende løsning er bygget på en 3D-hovedmodel, men den metode har heller ikke virket godt nok. Brugeren (REL) synes, at det er blevet værre og værre, og vil prøve noget andet.

## Status
- **Kode:** Al kode til hue, skæg og dragt er **ikke committet**. Den ligger i arbejdskopien på `main`:
  - `macos/Sources/JuleHygge/Hat.swift`
  - `Costume.swift` (ny fil)
  - `VirtualCamera.swift`
  - `Controller.swift`, `Settings.swift` og `Util.swift`
- **Committet, ikke pushet:** Kun rettelsen af hukommelseslækken er committet, som `1baeaea`.
- **Installeret:** Den nuværende version er installeret i `/Applications/JuleHygge.app`.
- **Indgang:** `VirtualCamera.composite()` kører for hvert kamerabillede i denne rækkefølge:
  1. Udskæringsmasken (`VNGeneratePersonSegmentationRequest`, 512×384).
  2. Ansigtsrammer og ansigtspunkter (`VNDetectFaceRectanglesRequest` rev. 3 og `VNDetectFaceLandmarksRequest`).
  3. Dragten, før udskæringen.
  4. Skægget.
  5. Forgrunden.
  6. Huen.
- **Ydelse:** ~14–15 billeder/s ud. Udskæringen tager ~25 ms og hue, skæg og dragt tilsammen ~30–35 ms.

## Hvad vi forsøgte at opnå (brugerens krav, samlet)
1. **Huen sidder som en rigtig hue på hovedet, også når man drejer, nikker og hælder hovedet:**
   - Den følger hovedet i alle tre akser.
   - Den dækker hovedets top og hår.
   - Kanten sidder højere fortil end bagtil.
   - Den skifter ikke størrelse eller højde, når man drejer hovedet.
   - Den ryster ikke og flyver ikke rundt.
2. **Ingen mål må bygges ud fra brugerens egne billeder.** Billeder og logs må kun bruges til at finde fejl i antagelser og metoder. Alle mål skal tages, mens appen kører, ud fra situationen: personen, afstanden, lyset, håret osv. De skal blive ved med at følge med, fordi forholdene ændrer sig.
3. **Ansigtet er kun forsiden af hovedet.** Det kan hverken give hovedets dybde eller dets højde. Toppen af hovedet er ikke en del af ansigtet.
4. **Usandsynlige målinger skal frasorteres.** Viser flere målinger i træk, at hovedet drejer én vej, er en enkelt måling i en helt anden retning sandsynligvis en fejl.
5. **Huens form:**
   - Ingen "talje" lige over kanten. Formen skal gå fra kanten mod en kile.
   - Fyldigheden forneden skal komme fra den målte hovedform, så huen dækker hovedet.
   - Pelskanten skal være hvid (ikke gråblå), ikke for kraftig, og den skal omslutte hovedet.
   - Pelskanten må hverken stoppe i luften eller blive tegnet hen over personens omrids.
6. **Skæg:**
   - Det skal sidde tæt på personens omrids og følge ansigtets retning.
   - Det må gerne hænge ud over kroppens omrids.
   - Mundhullet må aldrig vise baggrunden.
7. **Nissedragt:** Kun tøjet farves rødt. Halsen og huden skal være fri, også når man kigger op.
8. **Kameraet må ikke grabbe stillbilleder.** Et forsøg med periodiske stillbilleder til kalibrering blev afvist og rullet tilbage.

## Metoder, der er prøvet, og hvorfor de fejlede

### Hue, 1: 2D-klistermærke ud fra ansigtsrammen (Visions rammer og vinkler)
- **Metode:**
  - Huens størrelse og placering kom fra `boundingBox` og roll.
  - Yaw og pitch bøjede og flyttede den.
- **Fejl:**
  - Huen så "klasket på" ud.
  - Den skrumpede eller steg, når man drejede hovedet, fordi ansigtsrammens bredde skrumper ved drejning.
  - Den faldt ned i øjnene, når man kiggede ned.
  - Rammen sidder foran hovedets midte, så placeringen ramte forkert, når hovedet drejede.

### Hue, 2: placering fra udskæringsmasken og størrelse fra kalibrering
- **Metode:**
  - Huens top og midte blev taget fra masken i hvert billede.
  - Størrelsen kom fra et stillbillede analyseret hvert 10. sekund, mens man kiggede lige frem.
- **Fejl:**
  - Kanten voksede, når man drejede hovedet.
  - Huen var stadig flad og "for stiv".
  - Stillbillederne blev afvist af brugeren (krav 8) og rullet tilbage.

### Hue, 3: rigtig 3D med PnP (perspective-n-point)
- **Metode:**
  - Seks ansigtspunkter fra Vision (yderste øjenkroge, næsetip, mundvige, hage) blev tilpasset en standard-3D-ansigtsmodel med Levenberg–Marquardt.
  - Det giver hovedets rotation og position.
  - Huen er bygget på en ellipsoide-hovedmodel og projiceret med et pinhole-kamera med ~68° vandret synsfelt.
- **Fejl a) Huen flyver rundt:** Seks punkter med støj giver en ustabil løsning. Der blev lagt filtre på: One Euro-filter på punkterne, et træk mod sidste stilling og et filter på stillingen. Brugeren rapporterede senere, at det igen "fløj rundt".
- **Fejl b) Forkert drejning forfra:** Et ansigt set lige forfra blev løst som drejet 0,68 rad (~38°). Brugerens ansigtsproportioner afviger fra standardmodellen: munden er smallere og sidder lavere, og hagen sidder lavere. Det eneste, modellen kunne forklare det med, var en drejning.
  - **Rettelse:** modellens x/y lærer personens proportioner fra billeder set forfra.
- **Fejl c) Visions yaw er upålidelig:** Indlæringen krævede "Vision siger forfra" (|yaw| < 0,12). Men Vision meldte yaw ≈ −0,6 (35°), mens punkterne var symmetriske. Indlæringen skete derfor aldrig.
  - **Rettelse:** forfra afgøres ved, at ansigtet sidder midt i hovedets omrids i masken.
- **Fejl d) Ansigtspunkterne undervurderer drejningen kraftigt:**
  - Ved næsten profil (~80°) gav punkterne ~35°.
  - Visions punkter er for symmetriske, som om man kiggede mere lige frem, end man gør. Det bekræftede brugeren selv: ansigtet er drejet mere, end skægget og huen viser.
  - Punkterne på den bortvendte side er Visions gæt.
  - Konklusion: Visions ansigtspunkter er ikke en pålidelig måling af hovedets vinkel.

### Hue, 4: 3D-stilling løst sammen med hovedets omrids i masken (den nuværende kode)
- **Metode:**
  - Omridset måles i masken på to vandrette rækker over ansigtet (venstre og højre kant) og toppen af hovedet.
  - Det sammenlignes med den projicerede ellipsoide og indgår i samme løsning.
  - Hovedets bredde, højde og dybde er tre ekstra parametre i løsningen. Hver akse læres som glidende gennemsnit, kun når omridset viser den: dybden kun ved drejning, højden kun uden nik.
  - Punkter på den bortvendte side vægtes efter synlighed.
  - Punkter, der er uenige med resten, vægtes ned.
  - Et billede afvises, hvis det kræver en drejning over 8 rad/s, eller hvis mindst halvdelen af punkterne er uenige. Hvad "uenig" betyder, måles i forhold til den typiske afvigelse i situationen.
- **I simulering:** 1–2° fejl ved forfra, profil og nik (`--nissehue-test=MAPPE`).
- **Fejl live:**
  - Den første version af "afvis uenige billeder" havde en fast tolerance (~6 px). Live er den typiske afvigelse 8–9 px, så næsten alle billeder blev afvist, og huen stod fast. Tolerancen blev gjort relativ.
  - Ellipsoiden passer på de to målte rækker (inden for ~3 px), men et rigtigt hoved med hår og ører er ikke en ellipsoide. Alt, der afhænger af hovedets form uden for de to rækker, rammer forkert. Det gælder især hvad hovedet dækker, og hvor kanten og keglen skal sidde.
  - Brugeren oplevede stadig, at huen sad for lavt, og at vinklen var forkert.
  - **Grundlæggende problem:** Simuleringen tester mod en ellipsoide og Visions punkter med støj. Den fanger derfor ikke, at virkeligheden afviger fra begge antagelser: Visions punkter er systematisk for symmetriske, og hovedet er ikke en ellipsoide. Gode simuleringstal har ikke betydet god live-opførsel.

### Huens form og pelskant (alle afvist undervejs)
- **Kant med blågrå skygge og gennemsigtige kanter på pelskuglerne:** så gråblå ud ved siden af skægget. Rettet til hvid med lysegrå skygge og dækkende kugler.
- **Hue-stof, der følger kraniet tæt:** gav en "talje" lige over pelskanten, fordi pelsen stikker ud fra hovedet, og stoffet ligger ind mod hovedet.
- **Stof, der starter ude ved pelsen og glider ind mod issen:** rødt stof titter frem gennem pelsen. Det var et problem med dybdesorteringen.
- **To stykker med forskellig hældning** (kort stejlt stykke til issen, derefter en lang slank spids): overgangen så ud som en talje.
- **Hele keglen gjort bredere ved foden, så hovedet passer i den, med pelskanten flyttet med:** kanten blev for stor. Den passede før.
- **Én kegle med jævn aftagning langs midterlinjen:** "for simpel", den aftager for meget i starten og for lidt senere.
  - Brugerens krav: fyldigheden skal komme fra den **målte** hovedform og vinkel, ikke fra modellens.
- **Bagerste del af pelskanten skjult, fordi den vender væk fra kameraet:** kanten "stopper i luften" i siderne i stedet for at omslutte hovedet.
- **Bagerste del vist, men skjult hvor modellens ellipse dækker:** kanten tegnes hen over personens rigtige omrids, fordi ellipsen ikke er det rigtige omrids.
- **Bagerste del skåret til med personmasken pixel for pixel (sidste version):** brugeren siger, at det bliver værre og værre. Det er ikke undersøgt nærmere.

### Skæg (`Costume.swift`)
- **Metode:**
  - Tegnes i 2D ud fra Visions ansigtsomrids (kæbelinje), næse og læber.
  - Kanten skubbes udad fra ansigtets midte.
  - Der er et mundhul og et overskæg.
- **Fejl:**
  - **Drejer for lidt:** Visions punkter er for symmetriske, så skægget drejer mindre end ansigtet.
  - **Stikker frem i profil:** "Skub udad" sker til alle sider, så skægget stikker frem foran ansigtet og ud over baggrunden i profil.
  - **Mundhul ude over baggrunden:** Mundhullet kan så ligge ude over baggrunden, og så ses baggrunden gennem munden.
- **Afvist forsøg:** at beskære hele skægget til personens omrids. Det skar dele af skægget væk. Brugeren har ikke bedt om, at skægget skal holdes inden for omridset, kun at det skal sitte tæt på.
- **Nuværende:**
  - Skægget tegnes frit.
  - Mundhullet åbnes kun, hvor personen er bagved. Ellers tegnes skægget lukket.
  - Det drejer stadig forkert.

### Nissedragt og hals (`Costume.swift`, `applySuit`)
- **Mål:** Farv tøjet rødt, men lad hals og hud være.
- **Afviste metoder:**
  - **Fast halslinje under hagen:** passede ikke, når man kiggede op eller drejede.
  - **Oval omkring halsen:** samme problem.
  - **Lært tøjfarve:** fejlede med en grå hættetrøje i blåt lys, hvor huden og tøjet fik for ens farver. Det gav pletter.
  - **Lempelig halszone:** halsen blev stadig rød eller lyserød, når man kiggede op.
- **Nuværende:**
  - Halsen findes ved region growing fra hudfarvede frø under hagen.
  - Hudfarven sammenlignes med kindernes hudfarve, som kun læres forfra.
  - Desuden bruges en hudfarveregel (YCbCr) og en "aldrig over munden"-gradient.
  - Det er ikke bekræftet live, at halsen holder sig fri, når man kigger op.

## Erfaringer, der gælder uanset metode
- **Kameraadgang:** Start aldrig appen fra en terminal, mens kameraet skal virke. Brug `open -a /Applications/JuleHygge.app --args …`, ellers nægtes kameraadgang.
- **Diagnostik:** Læs `hue:`-loggen med `log show --predicate 'subsystem == "dk.julehygge.JuleHygge"'`. Hvert 2. sekund logger appen stillingen, Visions vinkler, punkterne, omridset fra masken mod modellen og hovedstørrelsen.
- **Masken:** Den dækker hele kamerabilledet (strakt fra 4:3 til 16:9) og flyttes med samme `aspectFill`-transformation som billedet.
- **Hukommelse:** Kør hvert billede i `autoreleasepool` og kald `ciContext.clearCaches()` jævnligt. Uden det lækkede kameraet 54 GB på en time.
- **Vision:**
  - Yaw passer ikke med det faktiske billede: −0,6 for et ansigt forfra.
  - Ansigtspunkterne er for symmetriske ved drejning. Brug dem ikke som eneste kilde til vinklen.
- **Brugerens skærmbilleder:** De er Preview-vinduet med hue og skæg allerede tegnet. De kan ikke bruges som testinput til masken, fordi den tegnede hue tæller med i omridset.

## Testværktøjer
- `--nissehue-test=MAPPE[,BILLEDE]`:
  - testet af løseren;
  - rysten og efterslæb;
  - en logget forfra-case;
  - en simulering af drejning mod profil og nik med et andet ansigt og hoved og med fejlmålinger;
  - `hoveder.png`, huen i seks stillinger.

  Byg med `macos/build.sh` og kør `build/JuleHygge.app/Contents/MacOS/JuleHygge --nissehue-test=…`. Kameraet bruges ikke, så det er sikkert fra en terminal.
- `--nissedragt-test=MAPPE,BILLEDE` lægger skæg og dragt på et foto og skriver `med-nissedragt.png` og `hals.png`.
- **Installér appen og kameraet:** `macos/xcbuild.sh`.

## Åbne spørgsmål til næste forsøg
- **Hvordan måles hovedets vinkel pålideligt?** Både Visions yaw og Visions punkter er systematisk forkerte. Måske skal masken og dens form eller tekstur bære mere af målingen, eller der skal bruges en anden kilde til vinklen.
- **Hvordan får huen form og dækning fra det målte omrids?** Det skal ske i stedet for fra en ellipsoide, så den både dækker hovedet og ikke tegnes hen over personen.
- **Skal skægget følge samme stilling som huen?** Det kræver, at stillingen er rigtig først.

## Hue, 5: bygget på det målte omrids (2026-11-17, eftermiddag) — ikke afprøvet live endnu

### Hvad live-loggen viste (`docs/hue-log/hue-2026-11-17.log`)
Konklusionen "Visions yaw er upålidelig: −0,6 for et ansigt forfra" var forkert. Brugeren sad drejet ca. 30° i forhold til kameraet (forfra mod skærmen, ikke mod kameraet). Det ses af en uafhængig måling uden ansigtsmodel: øjnenes midtpunkt i forhold til midten af hovedets omrids i masken.

| Tid | Visions yaw | Ansigtets forskydning i omridset |
|---|---|---|
| 12:38:21 | −6° | −5° |
| 12:38:25 | −13° | −14° |
| 12:38:06 | −26° | −24° |
| 12:37:36 | −29° | −27° |
| 12:37:50 | −41° | −31° |
| 12:38:14 | −60° | −63° |
| 12:38:29 | −61° | −65° |

- `forfra` var `false` i alle 65 sekunder, så indlæringen af ansigtets proportioner kørte aldrig.
- Masken er stabil: hovedets top og kanter flytter sig ±3 px, mens man sidder stille.
- **Visions vinkelrækkefølge** er R = Rz(roll)·Rx(pitch)·Ry(yaw). Roll er retningen af hovedets lodrette akse i billedet, ikke øjenlinjens hældning. I loggen hælder øjenlinjen atan(sin pitch · tan yaw) mere end roll (fx 12:38:23: roll 0,56, forudsagt øjenlinje 0,71, målt 0,72). Den anden rækkefølge, hvor roll er øjenlinjen, passede ikke. Grundlaget er få billeder fra én person; det bør bekræftes live.
- Pitch er positiv, når man nikker ned (Apples header).

### Metoden (`Hat.swift`)
1. **Plads og form fra masken i hvert billede.** Omridset scannes langs hovedets akse fra under øjnene til issen.
2. **Pelskanten** er en skrå ring (højest fortil). Dens bredde er omridsets bredde der, hvor ringen møder det, og dens forkant ligger over de målte bryn. Den halvdel, der går bag om hovedet, holdes på det målte omrids.
3. **Stoffet** er den mindste form uden indsnævring om kanten, omridset over kanten og spidsen. Den kan ikke få en talje, og fyldigheden kommer fra personens hoved og hår.
4. **Vinkler** fra Visions ansigtsramme. De former kun huen. Yaw kontrolleres mod omridset, og en måling langt fra både omridset og de seneste billeders retning udelades (højst tre i træk).
5. **Målestok:** hovedets største bredde (med hår). Hovedets højde i billedet ændrer sig med nik og kameraets højde, så den bruges ikke.
6. **Dybde/bredde** starter som et almindeligt hoved (1,25) og læres af, hvordan omridsets bredde ændrer sig, når personen drejer.
7. PnP, ansigtsmodel og ellipsoide er fjernet. Den gamle kode ligger i `docs/hue-log/Hat-pnp-2026-11-17.swift.txt`.

Intet er tilpasset én person, ét kamera eller én siddestilling. Kameraets højde (nedefra, oppefra) er bare en anden pitch.

### Simulering (`--nissehue-test=MAPPE`, `HatTest.swift`)
Syv hovedformer (almindeligt, smalt og skaldet, stort hår, knold, langt hår, barn, hestehale i siden) og fire kameraopstillinger (lige på; 30° nedefra med vidvinkel; 18° oppefra og til siden; 12° nedefra med en person, der sidder drejet 30°). Personerne er 3D-legemer set med perspektiv, ikke den form, huekoden regner med. "Vision" er de sande vinkler og punkter med støj, fejlmålinger og et for symmetrisk gæt på det fjerne øje.

Resultat over alle 14 opstillinger:
- **Udækket hoved over kanten:** højst 1,4 % (knold på baghovedet), ellers under 1 %.
- **Huen dækker et øje:** 0 billeder.
- **Kantens forside over brynene:** 0,03–0,19 hovedhøjder.
- **Rysten i huens spids (stille hoved, støj på):** 0,7–3,0 px vandret.
- **Huens størrelse:** svinger 10–15 % for almindelige hoveder (en del er ægte: hovedet kommer nærmere, når man nikker). Ved stort hår og hestehale i siden svinger den op til 25 % ved første drejning, indtil dybden er lært.
- **Tabt:** ved 30° nedefra og samtidig nik op (over 50° i alt) findes hovedets omrids ikke, og huen forsvinder.

### Hvad simuleringen ikke kan vise
- Den bruger samme vinkelrækkefølge som koden. En forkert antagelse om Vision opdages kun live.
- Om Vision finder ansigtet og giver brugbare vinkler helt ud i profil (loggen når 60°).
- Hvordan den rigtige maske opfører sig med hår, høretelefoner, hænder ved hovedet og ryglæn.
- Om huen ser rigtig ud på et rigtigt menneske. Simuleringens hoveder er simple legemer.

### Skæg og dragt
Ikke rørt. Skægget bør kunne bruge samme vinkler (Visions yaw direkte), når huen er bekræftet live.

## Live-afprøvning og rettelser (2026-11-17, kl. 13–14:40)
Huen er installeret og afprøvet live af brugeren: "ellers ser det fint ud". Loggen ligger i `docs/hue-log/hue-2026-11-17-ny-metode.log`.

- **Visions yaw når profil:** målt til ca. 78° og 73°, og den følges med omridsets egen måling.
- **Størrelse:** halv hovedbredde 87–110 px gennem drej, nik og hældning.
- **Fejl fundet live i huen:**
  - Skuldrene kom med i breddemålingen, når man kiggede ned, og huen blev tre gange for stor. Bredden måles nu fra pelskantens sider og op.
  - Stof længere rundt om hovedet blev tegnet foran pelsen ved omridset (set fra siden var pelsen næsten væk ved panden). Den nære halvdel af pelsen tegnes nu altid efter stoffet.
  - Én gang startede huen forfra ca. hvert sekund. Loggen viste en værdi, der ikke var et tal, i et kendt hoved. Kilden er ikke fundet. Nu kontrolleres målingerne, og et hoved med en ugyldig værdi droppes og logges (`hue: hoved droppet, ugyldig værdi i …`).
- **Åbent i huen:** mange kantpunkter udelades under bevægelse (op til ca. 190 pr. 2 s). Ikke undersøgt.

### Dragten (`Costume.swift`) — ændret samme dag
- **Før:** det røde måtte aldrig gå over en vandret linje i mundhøjde tværs over hele billedet. Når man kiggede ned, blev skuldre og hætte ikke røde.
- **Nu:** tøjet findes ud fra tøjet selv (`clothMask`): en ansigtshøjde under hagen er alt på personen tøj, og derfra vokser området op over personen, så længe farven ændrer sig gradvist (gitter 160 celler bredt, lysstyrke vægtet 0,35).
- **Hår er aldrig tøj:** alt inden for hovedets målte omrids (`NisseHat.headOutlines`) holdes fri. Over øjenlinjen er det maskens omrids. Under øjenlinjen kan masken ikke vise hovedet (det flyder sammen med hals, skuldre og hætte), så der bruges en afrundet kæbe fra omridsets to kanter ned til den målte hage. En lige kant i hagens højde (første udgave) holdt det røde væk fra et bånd af tøjet ved siden af kæben.
- **Blå kant:** den røde farve tonede ud med udskæringsmasken, så tøjets egen farve stod tilbage i overgangen. Nu dækker den røde hele overgangen, og hudmasken er strammet.
- **Ikke bekræftet live:** den afrundede kæbe. Svagheder: hår i tøjets farve, der rører tøjet uden for hovedområdet (langt hår), og skarpe mønstre over startlinjen.

### Skæg og overskæg på det målte ansigt (2026-11-17, eftermiddag)
- **Problemet:** forfra så skægget rigtigt ud, men så snart hovedet var drejet, blev det en kasse midt på ansigtet: den bortvendte side stak ud i luften, og den nære nåede ikke om til øret. Kanten fulgte Visions kæbelinje, hvis bortvendte side er et gæt.
- **Fire forsøg i blinde blev afvist live** (overskæg med fuld dybde: skævt; drejet kant målt ved kæbelinjens ender: for bredt, hang i luften; bredde i mundhøjde fra kæbelinjen: stadig forkert; sider op til ørerne: spids ved øret). Lærestreg: skægget skal ses i billedtesten, før det installeres.
- **Nu (`measureFace`, `wrappedBeard`):** ansigtet ses ovenfra som en halv oval om hovedets lodrette akse. Aksen er midten af hovedets omrids (huens origo). Dybden til ansigtets midterlinje måles af, hvor langt punktet under næsen ligger fra aksen, når hovedet er drejet. Bredden måles som maskens kant i mundhøjde på den side, ansigtet vender mod (kind mod baggrund, under ørerne); forfra begrænses den af Visions kæbelinje, så hår ved kinderne ikke tæller med. Skægget er et bånd på den flade fra øre til øre, og kun den del, der vender mod kameraet, tegnes. Overskægget ligger på samme flade.
- **Punktet under næsen** rykkes frem til overfladen (næseborenes midte ligger inde i ansigtet og flytter sig for lidt ved drejning).
- **Billedtest:** `--nissehue-test` tegner nu også skæg og overskæg på de simulerede hoveder (`HUE_NOBEARD=1` slår det fra). "Vision" giver her en kæbelinje, hvis bortvendte side er den nære side spejlet, som set live.
- **Kendt svaghed:** ansigtets oval antages at have centrum i hovedets akse. I simuleringen ligger ansigtet foran aksen, og bredden bliver da ca. 20 % for stor ved 30° drejning. Nik indgår ikke i skæggets form. Uden målt hoved bruges den flade kant fra kæbelinjen (`flatBeard`).

### Skæggets mål og materiale, efter live-billeder (2026-11-17, ca. kl. 15–16)
- **Fejlsøgning:** `--kamera-debug=MAPPE` gemmer hvert 3. sekund det færdige billede med målepunkter, det rå kamerabillede (`raa-NNN.jpg`) og målingerne (`log.txt`). `--kamera-replay=MAPPE` kører hue, skæg og dragt igen på de rå billeder og skriver `ud-NNN.png`. Brug det, før noget installeres: fire rettelser af skægget i blinde blev alle afvist live.
- **Mål, som billederne rettede:** bredden kan ikke regnes ud af en drejet visning (49–128 px for samme ansigt) og læres kun lige forfra uden nik; skægget slutter foran øret (0,84 af hovedets halve bredde, 0,2 bag aksen); punktet under næsen er midten af Visions næseomrids, ikke gennemsnittet af de laveste punkter; længder følger hovedets bredde, fordi Visions ansigtshøjde skrumper ca. 25 % ved drejning; på ansigtet holdes skægget inden for personens omrids i samme højde.
- **Materiale:** tre forsøg blev afvist (pelskugler: "cirkler oven på hinanden"; bølgede streger: "hvidt garn"; bløde runde toninger: "en plade med boldtryk"). Nu (`cotton`): formen blødgøres, klumper i flere størrelser lægges til, og hvor summen er over en tærskel, er der vat. Kanten bliver ujævn og halvgennemsigtig, og summens hældning mod lyset giver hver klump en lys og en skygget side. Regnes i halv størrelse.
