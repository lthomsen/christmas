# JuleHygge 🎄

Et lille juleoverlay til Windows: snevejr, sne der lægger sig på proceslinjen, julemanden i kane med rensdyr (og Rudolf), nisser der går rundt på proceslinjen og julelys langs toppen af skærmen.

- Overlayet er gennemsigtigt, og man kan klikke igennem det, så det forstyrrer ikke arbejdet.
- Indstillinger findes ved at højreklikke på snefnug-ikonet ved uret.
- Dobbeltklik på ikonet kalder julemanden frem med det samme.
- Animationen pauser automatisk, når et program kører i fuldskærm (spil, film).
- Indstillingerne gemmes i `%APPDATA%\JuleHygge\settings.ini`.

## Byg

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

Kræver ikke nogen installation. Den bruger den C#-compiler, der følger med Windows (.NET Framework 4.x).
Al grafik tegnes i koden, så der ikke er billedfiler.

## Ideer til næste version
- Understøttelse af flere skærme
- Snemand der bygges op over dagen, julekalender-låge hver dag i december
- Lyd (bjælder når julemanden flyver forbi), slås til i menuen
- Sne der lægger sig på toppen af åbne vinduer
