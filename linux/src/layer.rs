//! One screen's scene: a premultiplied ARGB32 pixel buffer the size of the monitor, and what is drawn on it.
//! Ported from `src/Layer.cs` (and `macos/Sources/JuleHygge/Overlay.swift`); origin top left, as in both.
//!
//! Phase 1: falling snow (dots and crystals). The ground pile, lights, elves, snowman, plow and Santa follow in
//! later phases (see docs/linux-plan.md).
//!
//! The Windows optimisations are kept, because the overlay covers whole 4K screens:
//! - only what was drawn in the previous frame is cleared (`mark()` and `clear_rects()`), and only that plus
//!   what is drawn now is sent to the X server;
//! - snowflakes are blended straight into the pixel buffer (`blend_dot()`), not drawn with Cairo;
//! - the number of flakes is scaled by the logical screen size.
//!
//! Everything drawn MUST be registered with `mark()`, or it stays on screen as a trail.

use cairo::{Context, Format, ImageSurface};

use crate::rng::Rng;
use crate::x11::{Rect, Res};

/// What the controller shares with every screen for one frame.
#[derive(Clone, Copy, Debug)]
pub struct SceneState {
    /// Seconds since start.
    pub time: f32,
    /// Horizontal wind in points per second (positive to the right).
    pub wind: f32,
    /// 0 light ... 2 storm, gliding while the weather changes.
    pub snow_amount: f32,
    /// 0 light, 1 normal, 2 storm.
    pub snow_level: i32,
    pub snow_on: bool,
    /// Drifts slowly between ~0.6 and ~1.4.
    pub snow_intensity: f32,
}

struct Flake {
    x: f32,
    y: f32,
    r: f32,
    vy: f32,
    phase: f32,
    sway: f32,
    sway_spd: f32,
    rot: f32,
    rot_spd: f32,
    a: i32,
    crystal: bool,
    /// About half the flakes can land on a window's top edge (phase 5).
    #[allow(dead_code)]
    catches: bool,
}

/// The pixel buffer with a Cairo surface drawing into the same memory.
/// Field order matters: the context and surface are dropped before the pixels they point into.
struct Canvas {
    cr: Context,
    surface: ImageSurface,
    pixels: Vec<u32>,
}

impl Canvas {
    fn new(w: i32, h: i32) -> Res<Canvas> {
        let mut pixels = vec![0u32; w as usize * h as usize];
        // SAFETY: the buffer is w*h*4 bytes with a stride of w*4 (valid for ARGB32), it is never reallocated
        // (its length never changes), and it outlives the surface and context (field order above).
        let surface =
            unsafe { ImageSurface::create_for_data_unsafe(pixels.as_mut_ptr() as *mut u8, Format::ARgb32, w, h, w * 4)? };
        let cr = Context::new(&surface)?;
        Ok(Canvas { cr, surface, pixels })
    }
}

/// What the controller should send to the window after a frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Present {
    Nothing,
    /// The rectangles in `Layer::present_rects()`.
    Rects,
    Full,
}

pub struct Layer {
    /// The monitor in global coordinates.
    pub rect: Rect,
    pub primary: bool,
    w: i32,
    h: i32,
    /// Scale of all figures: screen height / 1080 (at least 0.6), as on Windows.
    s: f32,
    dpi_scale: f32,
    ground_y: f32,
    canvas: Canvas,
    rng: Rng,
    flakes: Vec<Flake>,
    dirty: Vec<Rect>,
    prev_dirty: Vec<Rect>,
    present: Vec<Rect>,
    full_present: bool,
}

impl Layer {
    pub fn new(rect: Rect, primary: bool, dpi_scale: f32, seed: u64) -> Res<Layer> {
        let (w, h) = (rect.w, rect.h);
        Ok(Layer {
            rect,
            primary,
            w,
            h,
            s: (h as f32 / 1080.0).max(0.6),
            dpi_scale: dpi_scale.max(1.0),
            // Phase 2 moves this to the top of a bottom panel.
            ground_y: h as f32,
            canvas: Canvas::new(w, h)?,
            rng: Rng::new(seed),
            flakes: Vec::new(),
            dirty: Vec::new(),
            prev_dirty: Vec::new(),
            present: Vec::new(),
            full_present: true,
        })
    }

    pub fn width(&self) -> i32 {
        self.w
    }
    pub fn pixels(&self) -> &[u32] {
        &self.canvas.pixels
    }
    pub fn present_rects(&self) -> &[Rect] {
        &self.present
    }
    /// The window was exposed (e.g. just mapped): send everything next frame.
    pub fn invalidate(&mut self) {
        self.full_present = true;
    }
    pub fn flake_count(&self) -> usize {
        self.flakes.len()
    }

    fn mark(&mut self, x: f32, y: f32, w: f32, h: f32) {
        self.dirty.push(Rect::new(x.floor() as i32 - 2, y.floor() as i32 - 2, w.ceil() as i32 + 5, h.ceil() as i32 + 5));
    }

    // ------------------------------------------------------------------ one frame
    pub fn frame(&mut self, dt: f32, st: &SceneState) -> Present {
        self.update_snow(dt, st);

        // Clear what was drawn last frame (Cairo must finish before the buffer is touched directly).
        self.canvas.surface.flush();
        let cleared = std::mem::take(&mut self.prev_dirty);
        self.clear_rects(&cleared);
        self.canvas.surface.mark_dirty();

        self.draw_snow();
        self.canvas.surface.flush();

        let result = self.plan_present(&cleared);
        // What was drawn now is cleared next frame; reuse the old list's memory.
        self.prev_dirty = std::mem::replace(&mut self.dirty, cleared);
        self.dirty.clear();
        result
    }

    /// Collects the rectangles that changed on screen: last frame's (now cleared) and this frame's.
    /// Unlike Windows, which merges them into three boxes for UpdateLayeredWindowIndirect, X11 gets each small
    /// rectangle on its own: a few thousand tiny PutImage requests cost far less than one full 4K upload.
    fn plan_present(&mut self, cleared: &[Rect]) -> Present {
        if self.full_present {
            self.full_present = false;
            return Present::Full;
        }
        self.present.clear();
        let mut area = 0i64;
        for r in cleared.iter().chain(self.dirty.iter()) {
            let c = r.clip(self.w, self.h);
            if c.is_empty() {
                continue;
            }
            area += c.area();
            self.present.push(c);
        }
        if self.present.is_empty() {
            return Present::Nothing;
        }
        // mostly everything changed: one full update is cheaper
        if area > self.w as i64 * self.h as i64 / 2 {
            return Present::Full;
        }
        Present::Rects
    }

    fn clear_rects(&mut self, rects: &[Rect]) {
        let w = self.w as usize;
        for r in rects {
            let c = r.clip(self.w, self.h);
            if c.is_empty() {
                continue;
            }
            for y in c.y..c.bottom() {
                let start = y as usize * w + c.x as usize;
                self.canvas.pixels[start..start + c.w as usize].fill(0);
            }
        }
    }

    // ------------------------------------------------------------------ snow
    fn update_snow(&mut self, dt: f32, st: &SceneState) {
        const BASE: [f32; 3] = [110.0, 260.0, 650.0];
        // between two levels while the weather changes
        let amount = st.snow_amount.clamp(0.0, 2.0);
        let lower = (amount as usize).min(1);
        let wanted = BASE[lower] + (BASE[lower + 1] - BASE[lower]) * (amount - lower as f32);
        let logical_area = self.w as f32 * self.h as f32 / (self.dpi_scale * self.dpi_scale);
        // Snow covers the whole screen also in power-save mode; power-save only lowers the frame rate.
        let target = if st.snow_on {
            (wanted * (logical_area / (1920.0 * 1080.0)).min(2.0) * st.snow_intensity) as usize
        } else {
            0
        };
        // new flakes come in from the top; extra flakes only disappear when they land
        let add = if self.flakes.is_empty() { target } else { (target / 60).max(1) };
        for _ in 0..add {
            if self.flakes.len() >= target {
                break;
            }
            let anywhere = self.flakes.is_empty() || st.time < 1.0;
            let f = self.new_flake(anywhere, st);
            self.flakes.push(f);
        }

        let wind = st.wind * self.s;
        let (w, s, ground) = (self.w as f32, self.s, self.ground_y);
        let mut i = self.flakes.len();
        while i > 0 {
            i -= 1;
            let f = &mut self.flakes[i];
            f.y += f.vy * dt;
            f.x += (wind * (0.4 + f.r / (4.0 * s)) + (st.time * f.sway_spd + f.phase).cos() * f.sway) * dt;
            f.rot += f.rot_spd * dt;
            if f.x < -60.0 {
                f.x += w + 120.0;
            } else if f.x > w + 60.0 {
                f.x -= w + 120.0;
            }
            // Phase 2: flakes add to the ground pile here (Deposit) and land on its surface (HeapAt).
            if f.y >= ground {
                if self.flakes.len() > target {
                    self.flakes.swap_remove(i);
                } else {
                    let nf = self.new_flake(false, st);
                    self.flakes[i] = nf;
                }
            }
        }
    }

    fn new_flake(&mut self, anywhere: bool, st: &SceneState) -> Flake {
        let s = self.s;
        let depth = self.rng.f();
        let mut r = (1.0 + depth * depth * 3.5) * s;
        let vy = (25.0 + depth * 55.0 + self.rng.f() * 15.0) * s * if st.snow_level == 2 { 1.5 } else { 1.0 };
        let x = self.rng.range(-50, self.w + 50) as f32;
        let y = if anywhere { self.rng.f() * self.ground_y } else { -10.0 - self.rng.f() * 60.0 };
        let phase = self.rng.f() * 6.28;
        let sway = (8.0 + self.rng.f() * 20.0) * s;
        let sway_spd = 0.5 + self.rng.f() * 1.2;
        let a = (110.0 + depth * 145.0) as i32;
        let crystal = depth > 0.8 && self.rng.f() < 0.5;
        if crystal {
            r *= 1.6;
        }
        let rot = self.rng.f() * 6.28;
        let rot_spd = (self.rng.f() - 0.5) * 2.0;
        let catches = self.rng.f() < 0.5;
        Flake { x, y, r, vy, phase, sway, sway_spd, rot, rot_spd, a, crystal, catches }
    }

    /// A soft white dot blended straight into the premultiplied buffer (much faster than Cairo for thousands
    /// of tiny dots). Same arithmetic as `BlendDot` in `src/Layer.cs`.
    fn blend_dot(&mut self, cx: f32, cy: f32, r: f32, alpha: i32) {
        let x0 = ((cx - r - 1.0) as i32).max(0);
        let x1 = ((cx + r + 1.0) as i32).min(self.w - 1);
        let y0 = ((cy - r - 1.0) as i32).max(0);
        let y1 = ((cy + r + 1.0) as i32).min(self.h - 1);
        if x0 > x1 || y0 > y1 {
            return;
        }
        let w = self.w as usize;
        for y in y0..=y1 {
            let dy = y as f32 + 0.5 - cy;
            let row = &mut self.canvas.pixels[y as usize * w..(y as usize + 1) * w];
            for x in x0..=x1 {
                let dx = x as f32 + 0.5 - cx;
                let mut cov = r + 0.5 - (dx * dx + dy * dy).sqrt();
                if cov <= 0.0 {
                    continue;
                }
                if cov > 1.0 {
                    cov = 1.0;
                }
                let a = (alpha as f32 * cov) as u32;
                if a == 0 {
                    continue;
                }
                let d = row[x as usize];
                let inv = 255 - a;
                let da = a + ((d >> 24) & 0xFF) * inv / 255;
                let dr = a + ((d >> 16) & 0xFF) * inv / 255;
                let dg = a + ((d >> 8) & 0xFF) * inv / 255;
                let db = a + (d & 0xFF) * inv / 255;
                row[x as usize] = (da << 24) | (dr << 16) | (dg << 8) | db;
            }
        }
    }

    fn draw_snow(&mut self) {
        // Dots go straight into the buffer; Cairo has been flushed by the caller.
        for i in 0..self.flakes.len() {
            let (x, y, r, a, crystal) = {
                let f = &self.flakes[i];
                (f.x, f.y, f.r, f.a, f.crystal)
            };
            if y < -r * 2.0 {
                continue;
            }
            self.mark(x - r, y - r, r * 2.0, r * 2.0);
            if !crystal {
                self.blend_dot(x, y, r, a);
            }
        }
        // Phase 5: clumps falling off a window that went away.

        // Crystals: three crossing lines, drawn with Cairo.
        self.canvas.surface.mark_dirty();
        let cr = &self.canvas.cr;
        cr.set_line_width((0.9 * self.s).max(1.0) as f64);
        cr.set_line_cap(cairo::LineCap::Butt);
        for f in &self.flakes {
            if !f.crystal || f.y < -f.r * 2.0 || f.a < 60 {
                continue;
            }
            // 16 steps of alpha, as the 16 pens on Windows
            let step = ((f.a - 60) / 13).clamp(0, 15);
            cr.set_source_rgba(1.0, 1.0, 1.0, (60 + step * 13) as f64 / 255.0);
            for k in 0..3 {
                let a = f.rot + k as f32 * 1.0472;
                let (dx, dy) = (a.cos() * f.r, a.sin() * f.r);
                cr.move_to((f.x - dx) as f64, (f.y - dy) as f64);
                cr.line_to((f.x + dx) as f64, (f.y + dy) as f64);
            }
            let _ = cr.stroke();
        }
    }

    // ------------------------------------------------------------------ test aid
    /// Writes the overlay over a dark background as a PNG (`--snapshot`), like the macOS version.
    pub fn write_snapshot(&self, path: &std::path::Path) -> Res<()> {
        let out = ImageSurface::create(Format::ARgb32, self.w, self.h)?;
        {
            let cr = Context::new(&out)?;
            cr.set_source_rgb(40.0 / 255.0, 55.0 / 255.0, 80.0 / 255.0);
            cr.paint()?;
            cr.set_source_surface(&self.canvas.surface, 0.0, 0.0)?;
            cr.paint()?;
        }
        let mut file = std::fs::File::create(path)?;
        out.write_to_png(&mut file)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> SceneState {
        SceneState { time: 5.0, wind: 20.0, snow_amount: 1.0, snow_level: 1, snow_on: true, snow_intensity: 1.0 }
    }

    #[test]
    fn snow_fills_and_trails_are_cleared() {
        let mut l = Layer::new(Rect::new(0, 0, 640, 360), true, 1.0, 42).unwrap();
        let st = state();
        assert_eq!(l.frame(0.05, &st), Present::Full);
        assert!(l.flake_count() > 0);
        for _ in 0..200 {
            l.frame(0.05, &st);
        }
        // Every lit pixel must lie inside something drawn in the last frame: nothing is left behind.
        let w = l.width();
        for (i, p) in l.pixels().iter().enumerate() {
            if *p == 0 {
                continue;
            }
            let (x, y) = ((i as i32) % w, (i as i32) / w);
            assert!(
                l.prev_dirty.iter().any(|r| x >= r.x && x < r.right() && y >= r.y && y < r.bottom()),
                "trail at {x},{y}"
            );
        }
    }

    #[test]
    fn no_snow_means_nothing_drawn() {
        let mut l = Layer::new(Rect::new(0, 0, 320, 200), true, 1.0, 1).unwrap();
        let st = SceneState { snow_on: false, ..state() };
        l.frame(0.05, &st);
        assert_eq!(l.frame(0.05, &st), Present::Nothing);
        assert!(l.pixels().iter().all(|p| *p == 0));
    }

    #[test]
    fn blend_dot_is_premultiplied_white() {
        let mut l = Layer::new(Rect::new(0, 0, 20, 20), true, 1.0, 1).unwrap();
        l.blend_dot(10.0, 10.0, 3.0, 200);
        let p = l.pixels()[10 * 20 + 10];
        let (a, r, g, b) = (p >> 24, (p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF);
        assert_eq!(a, 200);
        assert!(r == a && g == a && b == a);
    }
}
