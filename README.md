# JuleHygge 🎄

Et lille juleoverlay til Windows og macOS: snevejr, sne der lægger sig på proceslinjen, julemanden i kane med rensdyr (og Rudolf), nisser der går rundt på proceslinjen, julelys langs toppen af skærmen, en snemand der bliver bygget lidt mere hver dag, og en julekalender med 24 låger.

- Overlayet er gennemsigtigt, og man kan klikke igennem det, så det forstyrrer ikke arbejdet.
- Det virker på **alle skærme**. Julemanden flyver hen over de skærme, der står ved siden af hinanden.
- Højreklik på snefnug-ikonet ved uret for **indstillinger** og **julekalenderen**. Dobbeltklik på ikonet kalder julemanden frem.
- **Julekalender:** Fra 1. december kan du åbne en ny låge hver dag. Bag lågerne er der vittigheder, hyggetips og julefakta, og nogle låger sætter gang i en effekt: julemanden, snestorm, nissefest eller stjerneregn. Du får en besked ved uret, når dagens låge er klar.
- **Snemand:** Står på proceslinjen og bliver bygget færdig over 12 dage, regnet fra første gang programmet startede. Først kommer sneboldene, så ansigtet, armene, halstørklædet og hatten, og til sidst kosten.
- Animationen pauser automatisk, når et program kører i fuldskærm (spil, film).
- Indstillingerne gemmes i `%APPDATA%\JuleHygge\settings.ini`.

## macOS
Se [macos/README.md](macos/README.md) — native Swift-udgave i menulinjen med samme figurer og julekalender. Byg med `macos/build.sh`.

## Byg og kør (Windows)

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
.\JuleHygge.exe              # start
.\JuleHygge.exe --kalender   # start og åbn julekalenderen med det samme
```

Kræver ikke nogen installation. Den bruger den C#-compiler, der følger med Windows (.NET Framework 4.x).
Al grafik tegnes i koden, så der ikke er billedfiler.

**Test med en anden dato:** Sæt `$env:JULE_DATE = '2026-12-10'`, før du starter programmet. Så opfører kalenderen og snemanden sig, som om det er den dag. Bemærk at åbnede låger og snemandens trin bliver gemt i indstillingerne.

## Kode

| Fil | Indhold |
|-----|---------|
| `src/Program.cs` | Opstart, testdato, små dataklasser |
| `src/Controller.cs` | Bakkeikon og menu, hovedløkke, julemanden, effekter, daglige beskeder |
| `src/Layer.cs` | Ét gennemsigtigt overlay-vindue pr. skærm: sne, nisser, julelys, snemand |
| `src/Calendar.cs` | Julekalender-vinduet og indholdet bag lågerne |
| `src/Settings.cs` | Indlæsning og gemning af indstillinger |

## Ideer til næste version
- Sne der lægger sig på toppen af åbne vinduer
- Lyd (bjælder når julemanden flyver forbi), slås til i menuen
