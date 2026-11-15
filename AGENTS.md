# AGENTS.md

JuleHygge er et juleoverlay til Windows (WinForms, .NET Framework 4.x). Al brugervendt tekst er på **dansk**.

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
- Remote er det **private** repo `rkl1976/christmas`.
