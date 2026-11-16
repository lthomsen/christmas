# Virtuel nissehue i JuleHygge Kamera — undersøgelse (2026-11-16)

> **Status:** Bygget og testet live (2026-11-16), se `macos/Sources/JuleHygge/Hat.swift` og menupunktet "Nissehue på i kameraet". Den endelige løsning går videre end planen nedenfor:
> - **3D-hue:** hovedet modelleres ud fra Visions yaw/pitch/roll, og huen (oval pelskant, bøjet kegle, kvast) drejes med hovedet, belyses fra en fast lyskilde, skjules bag hovedet og kaster skygge på panden (~5 ms pr. hoved).
> - **Placering fra udskæringsmasken i hvert billede:** toppen af hovedets omrids (med hår) og midten i pandehøjde. At gætte hovedets midte ud fra ansigtsrammen alene ramte forkert, når hovedet drejes.
> - **Størrelse fra en kalibrering:** hvert 10. sekund analyseres et stillbillede i baggrunden (udskæring i højeste kvalitet), mens man kigger lige frem; bredden måles i forhold til ansigtsrammens højde, som ikke ændrer sig, når hovedet drejes.
> - Test uden kamera: `--nissehue-test=MAPPE[,BILLEDE]`.

**Ønske:** Brugeren af JuleHygge Kamera får en nissehue på i kamerabilledet, og huen følger hovedet.

## Konklusion
Det kan lade sig gøre med det, der allerede er i projektet. Der skal ikke bruges nye frameworks eller nye tilladelser, og kamera-udvidelsen skal ikke ændres, så der kræves ingen genstart. Huen bliver et 2D-klistermærke, der følger hovedets position, størrelse og hældning. Det ser naturligt ud, når man sidder nogenlunde ret foran kameraet. Når man drejer hovedet meget eller kigger op eller ned, ser det mindre overbevisende ud.

## Hvorfor det passer ind
Al billedbehandling sker i appen, i `VirtualCamera.composite()` (`macos/Sources/JuleHygge/VirtualCamera.swift`):

1. Vision kører allerede `VNGeneratePersonSegmentationRequest` på hvert kamerabillede med en `VNImageRequestHandler`.
2. Personen lægges oven på julescenen med `CIBlendWithMask`.

Ansigtsgenkendelse kan køre i samme `handler.perform([...])`-kald. Huen lægges som et ekstra Core Image-lag oven på resultatet, før billedet sendes til udvidelsen. Udvidelsen viser bare de billeder, den får.

## Head tracking med Vision
- **`VNDetectFaceRectanglesRequest`, revision 3** giver for hvert ansigt:
  - en ramme om ansigtet (`boundingBox`)
  - **roll** (hældning til siden)
  - **yaw** (drejning til siden)
  - **pitch** (nik op og ned; først i revision 3, før var den altid 0)

  Vinklerne er i radianer. Det er nok til at placere, skalere og dreje huen.
- **`VNDetectFaceLandmarksRequest`** giver også ansigtspunkter (øjne, bryn, ansigtsomrids). Den er dyrere: ældre målinger viser 10–16 billeder/s på gamle Macs. Den er ikke nødvendig til en hue, men kan bruges til at finde toppen af hovedet mere præcist, hvis rammen ikke er god nok.
- Fejl:
  - Hvis der ikke findes et ansigt et øjeblik (hånd foran, hurtig bevægelse), bliver huen stående i ca. et halvt sekund og fader derefter ud, så den ikke blinker.
  - Positionen udglattes, så huen ikke ryster.

## Sådan tegnes og placeres huen
- **Tegnet i koden** som resten af projektet, uden billedfiler: en original dansk nissehue med rød top, der hænger ned i en blød bue, hvid pelskant og en hvid kvast. Den tegnes én gang som et `CGImage` i høj opløsning.
- **For hvert billede:**
  - Ansigtsrammen bruger samme `aspectFill`-transformation som kameraet og masken, så huen rammer præcis samme sted.
  - Bredde: ca. 1,3 × ansigtets bredde.
  - Placering: pelskanten sidder lige over brynene. Rammen går fra brynene til hagen, så hovedets top ligger ca. 0,3 × ansigtshøjden over rammen.
  - Drejning: med **roll**.
  - **Yaw:** Huen trykkes en smule sammen vandret og skubbes til den side, hovedet drejer mod. Toppen hænger ned i modsat side.
  - **Pitch:** Huen flyttes lidt op eller ned.
- **Lagorden:** Huen ligger øverst, over både person og baggrund, så pelskanten dækker lidt af panden og håret. Det er sådan, en rigtig hue ser ud.
- **Flere personer:** én hue pr. ansigt, højst 3.
- **Menupunkt:** "Nissehue i kameraet" (`CameraHat`), slået til som standard, når kameraet er installeret.

## Pris
- Ansigtsrammer er langt billigere end udskæringen, som vi allerede laver for hvert billede. Ansigtsgenkendelse på Apple Silicon kører på Neural Engine. Det skal måles: `perf:`-loggen i `VirtualCamera` får en ekstra tid for ansigtet.
- Hvis det koster for meget, kan ansigtet findes på hvert 2. billede. Positionen udglattes alligevel.
- At tegne huen er én ekstra `CIImage`-transformation og en sammensætning på GPU'en. Det er ubetydeligt.

## Begrænsninger
- **Det er 2D, ikke 3D:**
  - Når man drejer hovedet mere end ca. 45°, ser huen flad ud.
  - Huen skjules ikke bag en hånd, der løftes op over hovedet.
  - Rigtig 3D-sporing af ansigtet (som ARKit på iPhone) findes ikke på macOS.
  - Et eget ansigtsnet (fx MediaPipe Face Mesh) kræver en ekstern model og pakke. Det strider mod projektets "ingen eksterne filer".
- **Teams' egne effekter** (baggrund, sløring, "reactions") skal være slået fra, ligesom i dag.
- **Spejling:** Teams viser dit eget billede spejlvendt, men det er kun i din egen visning. Huen hænger rigtigt for de andre deltagere.

## Omfang
Cirka en dags arbejde:
- **Ansigtssporing og udglatning** i `VirtualCamera.swift`.
- **Tegning af huen,** fx i en ny `Hat.swift`.
- **Menupunkt og indstilling.**
- **Test:**
  - et testflag, der lægger huen på et stillbillede med et ansigt
  - en rigtig test i Photo Booth eller Teams

## Kilder
- [Apple: VNFaceObservation.roll](https://developer.apple.com/documentation/vision/vnfaceobservation/roll)
- [Apple: VNFaceObservation init(requestRevision:boundingBox:roll:yaw:pitch:)](https://developer.apple.com/documentation/vision/vnfaceobservation/init(requestrevision:boundingbox:roll:yaw:))
- [Apple: VNDetectFaceLandmarksRequest](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest)
- [WWDC21: Detect people, faces, and poses using Vision](https://developer.apple.com/videos/play/wwdc2021/10040/)
- [Kodeco: Vision – what's new with face detection (pitch i revision 3)](https://www.kodeco.com/29023965-vision-tutorial-for-ios-what-s-new-with-face-detection?page=2)
- [Apple Developer Forums: forventet fps for face landmarks](https://developer.apple.com/forums/thread/92048)
