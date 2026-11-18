# JuleHygge for Linux

A native Rust version of JuleHygge for **Ubuntu 22.04+** and **Linux Mint 21+**. The plan, the design choices and
the phases are in [docs/linux-plan.md](../docs/linux-plan.md).

> **Status: phase 2 (ground and stopping).** Snowflake icon in the panel with *Afslut*, one transparent
> click-through overlay per monitor, falling snow (dots and crystals, wind, changing weather), and a snow pile on
> top of the bottom panel (or the screen bottom) with storm drifts. A fullscreen app pauses its screen; a lock,
> the screen saver or a switched-off display stops everything; power-save follows the battery. There are no
> figures, calendar, sound or full menu yet (settings are changed in `settings.ini`).

## Build

```bash
sudo apt install build-essential pkg-config libcairo2-dev
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh     # Rust, if not installed (stable >= 1.89)
./build.sh                                                          # -> build/JuleHygge
```

## Run

```bash
build/JuleHygge                 # snow on every screen, snowflake in the panel; quit from its menu
pkill -x JuleHygge              # stop it from a terminal (e.g. when there is no tray icon)
```

- **Mint (Cinnamon, X11):** works directly. Needs the compositor, which Cinnamon always runs.
- **Ubuntu (GNOME, Wayland):** the app speaks X11 and runs through XWayland, which Ubuntu starts by itself.
  Whether the overlay stays on top of native Wayland windows is what phase 1 has to prove.
- **No compositor** (e.g. some Xfce/MATE setups): a see-through window is impossible, so the overlay stays off and
  the tray menu says *Kræver en compositor*. It turns on by itself when a compositor starts.

Only one JuleHygge runs per session (lock file `$XDG_RUNTIME_DIR/julehygge.lock`).

## Test aids

| Flag / environment variable | Effect |
|---|---|
| `--snapshot=DIR[,SEC]` | after SEC seconds (default 5) writes each screen's overlay over a dark background as `DIR/screenN.png`; also works without a compositor (e.g. Xvfb) |
| `--version` | prints the version |
| `JULE_SETTINGS=path` | uses another settings file, so tests never change the real one |
| `JULE_DATE=yyyy-MM-dd` | pretends it is another date (weather now; calendar and snowman later) |
| `JULE_WEATHER_TIME=HH:MM` | starts the day's weather at that time of day, to watch a change without waiting (the macOS name `JULE_VEJR_TID` works too) |
| `JULE_DEBUG=1` | debug lines in `$XDG_RUNTIME_DIR/julehygge-debug.log`, including fps, ms per frame and CPU % every 5 s |
| `JULE_FPS=N` | fixed frame rate (for measurements) |
| `JULE_SCALE=N` | overrides the desktop scale factor (otherwise `Xft.dpi / 96`) |
| `JULE_DEEPSNOW=1` | starts with a full snow pile |
| `JULE_NO_SHM=1` | sends pixels through the socket instead of MIT-SHM shared memory (to compare, or to rule it out) |

Settings: `~/.config/JuleHygge/settings.ini`, same keys as on Windows. Errors: `~/.local/state/JuleHygge/error.log`.

Unit tests (`cargo test`) cover the weather (against values computed with the Windows code), settings, the
snow layer (no trails left behind) and the icon.

## Phase 1 checklist (on real desktops)

On **Linux Mint** and on **Ubuntu 24.04 or newer (Wayland)**:

1. `JULE_DEBUG=1 build/JuleHygge` and watch: snow falls on every monitor, and clicks, scrolling and hovering
   reach the windows below the snow.
2. The snow stays above normal windows, also after clicking around and opening new windows (Ubuntu: also above
   native Wayland apps such as Files, Settings and Firefox).
3. The snowflake shows in the panel, and *Afslut* quits.
4. CPU: `grep fps $XDG_RUNTIME_DIR/julehygge-debug.log` after a minute, at 20 fps (default) and with
   `JULE_FPS=30`. Note the screen sizes and scale.
5. Plug or unplug a monitor, or change the resolution: the overlays follow within a second or two.
6. Fractional scaling on Ubuntu (e.g. 125 %): is the snow sharp, and does it cover the whole screen?

## Code

| File | Contents | Windows counterpart |
|---|---|---|
| `src/main.rs` | arguments, single instance | `Program.cs` |
| `src/controller.rs` | main loop, frame timer, wind, weather, screens, test aids | `Controller.cs` |
| `src/layer.rs` | one screen's scene and pixel buffer: snow, snow pile, fullscreen pause, dirty rectangles | `Layer.cs` |
| `src/x11.rs` | X11: monitors, overlay windows, click-through, MIT-SHM, panels, fullscreen window, DPMS | Win32 parts of `Layer.cs` |
| `src/session.rs` | lock and screen saver (D-Bus), battery | `SessionSwitch`, `PowerWatcher.cs` |
| `src/tray.rs`, `src/icon.rs` | panel icon and menu; the icon drawn with Cairo | `NotifyIcon`, `build.ps1` |
| `src/weather.rs` | changing weather (same random numbers as Windows and macOS) | `Weather.cs` |
| `src/settings.rs` | `settings.ini` | `Settings.cs` |
| `src/clock.rs`, `src/log.rs`, `src/rng.rs` | `JULE_DATE`, logs, random numbers | `JuleClock`, `ErrorLog` |
| `src/text.rs` | all user-facing text (Danish); code and comments are English | strings in the code |

Code, identifiers and comments are English. User-facing text is Danish and lives only in `src/text.rs`. Names
shared with the other versions keep their spelling: the `JULE_*` environment variables, the `settings.ini` keys
(`Nisser`, `NisseCount`) and the product name JuleHygge.
