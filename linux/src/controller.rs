//! The main loop: one overlay per monitor, the shared scene state (time, wind, weather), the frame timer, the
//! tray, and the test aids. Corresponds to `src/Controller.cs`.
//!
//! Everything stops while nobody can see it: the session is locked, the screen saver runs, or the display is
//! off. Each reason is tracked on its own, so e.g. the screen saver ending in front of the lock screen does not
//! wake the overlay.

use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver};
use std::time::{Duration, Instant};

use x11rb::protocol::Event;

use crate::layer::{Layer, PixelStore, Present, SceneState};
use crate::rng::Rng;
use crate::session::SessionWatch;
use crate::settings::Settings;
use crate::tray::{TrayHandle, TrayMsg};
use crate::weather::Weather;
use crate::x11::{Display, Monitor, OverlayWindow, Rect, Res};

pub struct Options {
    /// `--snapshot=DIR[,SEC]`: write each screen as a PNG after SEC seconds (default 5).
    pub snapshot: Option<(PathBuf, f32)>,
}

struct Screen {
    layer: Layer,
    /// None when no window can be shown (no compositor); the scene still runs for `--snapshot`.
    window: Option<OverlayWindow>,
    /// False while a fullscreen app pauses this screen.
    mapped: bool,
}

pub struct Controller {
    display: Display,
    cfg: Settings,
    screens: Vec<Screen>,
    monitors: Vec<Monitor>,
    weather: Weather,
    rng: Rng,
    tray: Option<TrayHandle>,
    tray_rx: Receiver<TrayMsg>,
    snapshot: Option<(PathBuf, f32)>,

    time: f32,
    wind: f32,
    wind_target: f32,
    wind_timer: f32,
    snow_phase_a: f64,
    snow_phase_b: f64,

    can_overlay: bool,
    compositor_timer: f32,
    top_timer: f32,
    /// Fullscreen window and panels, checked once a second.
    desktop_timer: f32,
    fullscreen: Option<Rect>,
    /// Battery state, checked every 5 seconds.
    power_timer: f32,
    power_save: bool,

    session: SessionWatch,
    display_off: bool,
    next_dpms_check: Instant,
    asleep: bool,
    /// Monitors changed: rebuild after this many seconds (RandR sends bursts of events).
    rebuild_in: Option<f32>,
}

impl Controller {
    pub fn new(opts: Options) -> Res<Controller> {
        let display = Display::open()?;
        let mut cfg = Settings::load();
        if cfg.first_run.is_none() {
            // the snowman is built over 12 days from the first start (phase 3)
            cfg.first_run = Some(crate::clock::today());
            cfg.save();
        }
        let mut rng = Rng::from_time();
        let can_overlay = display.can_overlay();
        let (tx, tray_rx) = channel();
        let tray = crate::tray::spawn(tx, status_text(can_overlay));
        let session = crate::session::spawn();
        let snow_phase_a = rng.f64() * 2.0 * std::f64::consts::PI;
        let snow_phase_b = rng.f64() * 2.0 * std::f64::consts::PI;
        let mut c = Controller {
            display,
            cfg,
            screens: Vec::new(),
            monitors: Vec::new(),
            weather: Weather::new(),
            rng,
            tray,
            tray_rx,
            snapshot: opts.snapshot,
            time: 0.0,
            wind: 0.0,
            wind_target: 0.0,
            wind_timer: 0.0,
            snow_phase_a,
            snow_phase_b,
            can_overlay,
            compositor_timer: 2.0,
            top_timer: 2.0,
            desktop_timer: 0.0,
            fullscreen: None,
            power_timer: 0.0,
            power_save: false,
            session,
            display_off: false,
            next_dpms_check: Instant::now(),
            asleep: false,
            rebuild_in: None,
        };
        c.update_power_save();
        c.build_screens();
        Ok(c)
    }

    // ------------------------------------------------------------------ screens
    fn build_screens(&mut self) {
        for s in self.screens.drain(..) {
            if let Some(w) = &s.window {
                self.display.destroy_overlay(w);
            }
        }
        self.monitors = self.display.monitors();
        if !self.can_overlay && self.snapshot.is_none() {
            crate::log::error("no compositor (or no 32-bit visual): the overlay stays off until one runs");
            return;
        }
        for m in &self.monitors {
            if !self.cfg.all_screens && !m.primary {
                continue;
            }
            let seed = self.rng.next_u64();
            // shared memory only for a real window (a --snapshot run without a compositor has none)
            let shm = if self.can_overlay { self.display.shm_buffer(m.rect.w, m.rect.h) } else { None };
            let seg = shm.as_ref().map(|(_, seg)| *seg);
            let pixels: Box<dyn PixelStore> = match shm {
                Some((buf, _)) => Box::new(buf),
                None => Box::new(vec![0u32; m.rect.w as usize * m.rect.h as usize]),
            };
            let layer = match Layer::with_pixels(m.rect, m.primary, self.display.dpi_scale, seed, pixels) {
                Ok(l) => l,
                Err(e) => {
                    crate::log::error(&format!("screen {} {:?}: {e}", m.name, m.rect));
                    continue;
                }
            };
            let window = if self.can_overlay {
                match self.display.create_overlay(m.rect, seg) {
                    Ok(w) => Some(w),
                    Err(e) => {
                        crate::log::error(&format!("overlay for {}: {e}", m.name));
                        None
                    }
                }
            } else {
                None
            };
            crate::log::debug(&format!(
                "screen {} {}x{}+{}+{} primary {} window {} shm {}",
                m.name,
                m.rect.w,
                m.rect.h,
                m.rect.x,
                m.rect.y,
                m.primary,
                window.is_some(),
                seg.is_some()
            ));
            self.screens.push(Screen { layer, window, mapped: true });
        }
        self.update_desktop();
    }

    fn handle_event(&mut self, e: Event) {
        match e {
            Event::Expose(x) => {
                for s in &mut self.screens {
                    if s.window.as_ref().map(|w| w.win) == Some(x.window) {
                        s.layer.invalidate();
                    }
                }
            }
            Event::RandrScreenChangeNotify(_) | Event::RandrNotify(_) => {
                self.rebuild_in = Some(1.0);
            }
            Event::Error(err) => crate::log::debug(&format!("X error: {err:?}")),
            _ => {}
        }
    }

    // ------------------------------------------------------------------ scene state
    /// 0 light ... 2 storm, gliding. Setting 3 (changing weather) lets the weather choose.
    fn snow_amount(&mut self) -> f32 {
        if self.cfg.snow_level == 3 {
            self.weather.amount() as f32
        } else {
            self.cfg.snow_level as f32
        }
    }

    /// Snowfall drifts between ~60% and ~140% of the chosen amount (two slow waves of about 3 and 7 minutes).
    fn snow_intensity(&self) -> f32 {
        let t = self.time as f64;
        let tau = 2.0 * std::f64::consts::PI;
        (1.0 + 0.25 * (t * tau / 190.0 + self.snow_phase_a).sin() + 0.15 * (t * tau / 430.0 + self.snow_phase_b).sin())
            as f32
    }

    fn update_wind(&mut self, dt: f32, level: i32) {
        self.wind_timer -= dt;
        if self.wind_timer <= 0.0 {
            self.wind_timer = 3.0 + self.rng.f() * 6.0;
            let storm = level == 2;
            self.wind_target =
                (self.rng.f() * 2.0 - 1.0) * if storm { 140.0 } else { 30.0 } + if storm { 60.0 } else { 0.0 };
        }
        self.wind += (self.wind_target - self.wind) * (dt * 0.5).min(1.0);
    }

    /// Power-save: always (1), or only while a laptop runs on battery (2, the default).
    fn update_power_save(&mut self) {
        let on = self.cfg.power_save == 1 || (self.cfg.power_save == 2 && crate::session::on_battery());
        if on != self.power_save {
            crate::log::debug(&format!("power-save {}", if on { "on" } else { "off" }));
            self.power_save = on;
        }
    }

    /// Where each screen's snow lies (panels can be moved, hidden or resized) and whether a fullscreen app is
    /// active. Always detected: screens either pause or move their ground to the screen bottom.
    fn update_desktop(&mut self) {
        let fs = self.display.fullscreen_window();
        if fs != self.fullscreen {
            crate::log::debug(&format!("fullscreen window: {fs:?}"));
            self.fullscreen = fs;
        }
        let rects: Vec<Rect> = self.screens.iter().map(|s| s.layer.rect).collect();
        for (s, top) in self.screens.iter_mut().zip(self.display.panel_tops(&rects)) {
            s.layer.set_panel_top(top);
        }
    }

    // ------------------------------------------------------------------ sleep
    /// True while nobody can see the overlay. DPMS is asked every 2 seconds; lock and screen saver come from the
    /// session thread.
    fn check_asleep(&mut self) -> bool {
        let now = Instant::now();
        if now >= self.next_dpms_check {
            self.next_dpms_check = now + Duration::from_secs(2);
            let off = self.display.display_off();
            if off != self.display_off {
                crate::log::debug(&format!("display {}", if off { "off" } else { "on" }));
                self.display_off = off;
            }
        }
        let (locked, saver) = (self.session.locked(), self.session.screen_saver());
        let asleep = locked || saver || self.display_off;
        if asleep != self.asleep {
            self.asleep = asleep;
            if asleep {
                self.finish_runs();
                crate::log::debug(&format!("asleep (locked={locked} saver={saver} display_off={})", self.display_off));
            } else {
                crate::log::debug("awake");
            }
        }
        asleep
    }

    /// Ends everything that is on its way, as if it had arrived, when the overlay stops (lock, screen saver,
    /// display off) or frames stalled (e.g. after suspend): otherwise it stays "on the way" while nothing moves.
    /// Phase 3 ends Santa's trip and the plow run here, phase 4 stops their sound (`FinishRuns()` on Windows).
    fn finish_runs(&mut self) {
        crate::log::debug("finish runs");
    }

    /// The calm scene runs at the chosen frame rate (power-save caps it at 12). JULE_FPS overrides it.
    /// Phase 3 boosts to 30 fps while Santa or the plow move, as on Windows.
    fn desired_fps(&self) -> f64 {
        if let Some(f) = std::env::var("JULE_FPS").ok().and_then(|v| v.trim().parse::<f64>().ok()) {
            if f > 0.0 {
                return f;
            }
        }
        let fr = self.cfg.frame_rate as f64;
        if self.power_save {
            fr.min(12.0)
        } else {
            fr
        }
    }

    // ------------------------------------------------------------------ main loop
    pub fn run(&mut self) -> Res<()> {
        let mut last = Instant::now();
        let mut next_frame = Instant::now();
        let mut stats = Stats::new();
        loop {
            for e in self.display.poll_events()? {
                self.handle_event(e);
            }
            #[allow(clippy::never_loop)] // Quit is the only tray message until the full menu arrives
            while let Ok(msg) = self.tray_rx.try_recv() {
                match msg {
                    TrayMsg::Quit => {
                        self.shutdown();
                        return Ok(());
                    }
                }
            }

            if self.check_asleep() {
                // Keep handling events and the tray, but draw nothing (and do not raise the windows above a
                // lock screen).
                std::thread::sleep(Duration::from_millis(250));
                last = Instant::now();
                next_frame = last;
                continue;
            }

            let now = Instant::now();
            let gap = (now - last).as_secs_f32();
            // frames stopped for a while (e.g. suspend, or a screen saver we got no notice of)
            if gap > 2.0 {
                crate::log::debug(&format!("frames stalled for {gap:.1} s"));
                self.finish_runs();
            }
            let dt = gap.min(0.1);
            last = now;
            self.time += dt;
            self.timers(dt);

            let amount = self.snow_amount();
            let level = if amount > 1.5 {
                2
            } else if amount > 0.5 {
                1
            } else {
                0
            };
            self.update_wind(dt, level);
            let st = SceneState {
                time: self.time,
                wind: self.wind,
                snow_amount: amount,
                snow_level: level,
                snow_on: self.cfg.snow,
                snow_intensity: self.snow_intensity(),
                snow_ground: self.cfg.snow_ground,
                fullscreen: self.fullscreen,
                pause_fullscreen: self.cfg.pause_fullscreen,
            };
            let busy = Instant::now();
            self.frame_all(dt, &st);
            self.display.flush()?;
            stats.frame(busy.elapsed(), self.desired_fps(), self.screens.iter().map(|s| s.layer.flake_count()).sum());

            if let Some((dir, at)) = &self.snapshot {
                if self.time >= *at {
                    let dir = dir.clone();
                    self.snapshot = None;
                    self.write_snapshots(&dir);
                }
            }

            // Sleep until the next frame; after a stall, start counting again from now.
            let period = Duration::from_secs_f64(1.0 / self.desired_fps());
            next_frame += period;
            let now = Instant::now();
            if next_frame > now {
                std::thread::sleep(next_frame - now);
            } else {
                next_frame = now;
            }
        }
    }

    fn timers(&mut self, dt: f32) {
        self.compositor_timer -= dt;
        if self.compositor_timer <= 0.0 {
            self.compositor_timer = 2.0;
            let ok = self.display.can_overlay();
            if ok != self.can_overlay {
                crate::log::debug(&format!("compositor {}", if ok { "started" } else { "stopped" }));
                self.can_overlay = ok;
                if let Some(t) = &self.tray {
                    let text = status_text(ok);
                    let _ = t.update(move |tray: &mut crate::tray::AppTray| tray.status = text);
                }
                self.build_screens();
            }
        }
        if let Some(t) = self.rebuild_in.as_mut() {
            *t -= dt;
            if *t <= 0.0 {
                self.rebuild_in = None;
                if self.display.monitors() != self.monitors {
                    crate::log::debug("monitors changed: rebuilding the overlays");
                    self.build_screens();
                }
            }
        }
        self.power_timer -= dt;
        if self.power_timer <= 0.0 {
            self.power_timer = 5.0;
            self.update_power_save();
        }
        self.desktop_timer -= dt;
        if self.desktop_timer <= 0.0 {
            self.desktop_timer = 1.0;
            self.update_desktop();
        }
        self.top_timer -= dt;
        if self.top_timer <= 0.0 {
            self.top_timer = 2.0;
            for s in &self.screens {
                if let Some(w) = &s.window {
                    self.display.raise(w);
                }
            }
        }
    }

    fn frame_all(&mut self, dt: f32, st: &SceneState) {
        // The X server reads shared memory when it gets to the request: let it finish last frame's first.
        if let Err(e) = self.display.sync() {
            crate::log::error(&format!("sync: {e}"));
        }
        // Per screen, so a failing screen (e.g. mid display change) does not stop the others.
        for s in &mut self.screens {
            let layer = &mut s.layer;
            let present = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| layer.frame(dt, st))) {
                Ok(p) => p,
                Err(_) => {
                    crate::log::error("a screen's frame panicked");
                    continue;
                }
            };
            let Some(w) = &s.window else { continue };
            // a fullscreen app pauses this screen: hide the window, and show it again afterwards
            if s.layer.paused() == s.mapped {
                s.mapped = !s.layer.paused();
                self.display.set_mapped(w, s.mapped);
                crate::log::debug(&format!(
                    "screen at {},{} {}",
                    s.layer.rect.x,
                    s.layer.rect.y,
                    if s.mapped { "resumed" } else { "paused for a fullscreen app" }
                ));
            }
            let width = s.layer.width();
            let result = match present {
                Present::Nothing => Ok(()),
                Present::Full => {
                    let full = [Rect::new(0, 0, s.layer.rect.w, s.layer.rect.h)];
                    self.display.put(w, s.layer.pixels(), width as usize, s.layer.height(), &full)
                }
                Present::Rects => {
                    self.display.put(w, s.layer.pixels(), width as usize, s.layer.height(), s.layer.present_rects())
                }
            };
            if let Err(e) = result {
                crate::log::error(&format!("present: {e}"));
            }
        }
    }

    fn write_snapshots(&self, dir: &std::path::Path) {
        if let Err(e) = std::fs::create_dir_all(dir) {
            crate::log::error(&format!("snapshot dir {}: {e}", dir.display()));
            return;
        }
        for (i, s) in self.screens.iter().enumerate() {
            let path = dir.join(format!("screen{i}.png"));
            if let Err(e) = s.layer.write_snapshot(&path) {
                crate::log::error(&format!("snapshot {}: {e}", path.display()));
            }
        }
        crate::log::debug(&format!("snapshot written to {}", dir.display()));
        println!("snapshot written to {}", dir.display());
    }

    fn shutdown(&mut self) {
        for s in self.screens.drain(..) {
            if let Some(w) = &s.window {
                self.display.destroy_overlay(w);
            }
        }
        if let Some(t) = self.tray.take() {
            let _ = t.shutdown();
        }
    }
}

fn status_text(can_overlay: bool) -> String {
    if can_overlay {
        String::new()
    } else {
        crate::text::NEEDS_COMPOSITOR.into()
    }
}

/// With JULE_DEBUG=1: the real frame rate, the time spent per frame, and the process's CPU use, every 5 seconds.
struct Stats {
    start: Instant,
    frames: u32,
    busy: Duration,
    cpu_start: Option<f64>,
}

impl Stats {
    fn new() -> Self {
        Stats { start: Instant::now(), frames: 0, busy: Duration::ZERO, cpu_start: cpu_seconds() }
    }

    fn frame(&mut self, busy: Duration, wanted: f64, flakes: usize) {
        self.frames += 1;
        self.busy += busy;
        let wall = self.start.elapsed().as_secs_f64();
        if wall < 5.0 {
            return;
        }
        if crate::log::debug_enabled() {
            let cpu = cpu_seconds();
            let cpu_pct = match (self.cpu_start, cpu) {
                (Some(a), Some(b)) => format!("{:.1}%", (b - a) / wall * 100.0),
                _ => "?".into(),
            };
            crate::log::debug(&format!(
                "fps {:.1} (wanted {wanted}), frame {:.2} ms, cpu {cpu_pct}, flakes {flakes}",
                self.frames as f64 / wall,
                self.busy.as_secs_f64() * 1000.0 / self.frames.max(1) as f64
            ));
        }
        *self = Stats::new();
    }
}

/// User + system CPU seconds of this process, from /proc/self/stat (clock ticks of 1/100 s, the Linux default).
fn cpu_seconds() -> Option<f64> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    // fields after the command name (which may contain spaces) start at field 3
    let rest = &stat[stat.rfind(')')? + 2..];
    let f: Vec<&str> = rest.split_whitespace().collect();
    let utime: f64 = f.get(11)?.parse().ok()?;
    let stime: f64 = f.get(12)?.parse().ok()?;
    Some((utime + stime) / 100.0)
}
