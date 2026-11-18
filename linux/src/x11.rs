//! Everything that talks to the X server: monitors, the transparent click-through overlay windows, and pushing
//! changed pixels to them. On Ubuntu's Wayland desktop this runs through XWayland.
//!
//! The overlay windows correspond to the `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST` forms in `src/Layer.cs`:
//! - a 32-bit ARGB visual, so the compositor blends them with alpha (needs a running compositor);
//! - `override_redirect`, so the window manager neither decorates them nor lists them in the taskbar or alt-tab,
//!   and they are raised again every 2 seconds like `KeepOnTop()`;
//! - an empty input shape (XFixes), so every click goes through to the windows below.

use x11rb::connection::{Connection, RequestConnection};
use x11rb::protocol::randr::{self, ConnectionExt as _};
use x11rb::protocol::shape;
use x11rb::protocol::xfixes::ConnectionExt as _;
use x11rb::protocol::xproto::{
    AtomEnum, ColormapAlloc, ConfigureWindowAux, ConnectionExt as _, CreateGCAux, CreateWindowAux, EventMask,
    ImageFormat, ImageOrder, PropMode, StackMode, VisualClass, Window, WindowClass,
};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

pub type Res<T> = Result<T, Box<dyn std::error::Error>>;

/// A rectangle in pixels. `w` and `h` are never negative after `clip`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub fn new(x: i32, y: i32, w: i32, h: i32) -> Self {
        Rect { x, y, w, h }
    }
    pub fn right(&self) -> i32 {
        self.x + self.w
    }
    pub fn bottom(&self) -> i32 {
        self.y + self.h
    }
    pub fn is_empty(&self) -> bool {
        self.w <= 0 || self.h <= 0
    }
    pub fn area(&self) -> i64 {
        if self.is_empty() {
            0
        } else {
            self.w as i64 * self.h as i64
        }
    }
    /// The part of `self` inside a `w` x `h` surface.
    pub fn clip(&self, w: i32, h: i32) -> Rect {
        let x0 = self.x.max(0);
        let y0 = self.y.max(0);
        let x1 = self.right().min(w);
        let y1 = self.bottom().min(h);
        Rect { x: x0, y: y0, w: (x1 - x0).max(0), h: (y1 - y0).max(0) }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Monitor {
    /// In global (root window) coordinates.
    pub rect: Rect,
    pub primary: bool,
    pub name: String,
}

x11rb::atom_manager! {
    pub Atoms: AtomsCookie {
        _NET_WM_NAME,
        _NET_WM_WINDOW_TYPE,
        _NET_WM_WINDOW_TYPE_NOTIFICATION,
        _NET_WM_BYPASS_COMPOSITOR,
        UTF8_STRING,
    }
}

/// One overlay window (one per monitor).
pub struct OverlayWindow {
    pub win: Window,
    gc: u32,
}

pub struct Display {
    pub conn: RustConnection,
    pub root: Window,
    screen_w: i32,
    screen_h: i32,
    /// The 32-bit TrueColor (ARGB) visual, if the server has one.
    argb_visual: Option<(u32, u32)>, // (visual id, colormap)
    lsb_first: bool,
    max_request_bytes: usize,
    atoms: Atoms,
    cm_atom: u32,
    randr_monitors: bool,
    /// Xft.dpi / 96 (or JULE_SCALE), at least 1.
    pub dpi_scale: f32,
    scratch: Vec<u8>,
}

impl Display {
    pub fn open() -> Res<Display> {
        let (conn, screen_num) = x11rb::connect(None)?;
        let (root, screen_w, screen_h, argb_visual_id) = {
            let screen = &conn.setup().roots[screen_num];
            let mut visual = None;
            for d in screen.allowed_depths.iter().filter(|d| d.depth == 32) {
                if let Some(v) = d.visuals.iter().find(|v| v.class == VisualClass::TRUE_COLOR) {
                    visual = Some(v.visual_id);
                    break;
                }
            }
            (screen.root, screen.width_in_pixels as i32, screen.height_in_pixels as i32, visual)
        };
        let lsb_first = conn.setup().image_byte_order == ImageOrder::LSB_FIRST;

        let atoms = Atoms::new(&conn)?.reply()?;
        let cm_atom = conn.intern_atom(false, format!("_NET_WM_CM_S{screen_num}").as_bytes())?.reply()?.atom;

        // XFixes must be told which version we speak before its requests can be used (input shapes).
        conn.xfixes_query_version(5, 0)?.reply()?;
        let randr_monitors = match conn.randr_query_version(1, 5) {
            Ok(c) => c.reply().map(|r| r.major_version > 1 || r.minor_version >= 5).unwrap_or(false),
            Err(_) => false,
        };
        if randr_monitors {
            let mask =
                randr::NotifyMask::SCREEN_CHANGE | randr::NotifyMask::CRTC_CHANGE | randr::NotifyMask::OUTPUT_CHANGE;
            conn.randr_select_input(root, mask)?;
        }

        let argb_visual = match argb_visual_id {
            Some(v) => {
                let cmap = conn.generate_id()?;
                conn.create_colormap(ColormapAlloc::NONE, cmap, root, v)?;
                Some((v, cmap))
            }
            None => None,
        };

        let max_request_bytes = conn.maximum_request_bytes();
        let dpi_scale = read_dpi_scale(&conn, root);
        conn.flush()?;
        crate::log::debug(&format!(
            "X11: screen {screen_w}x{screen_h}, argb visual {:?}, randr 1.5 {randr_monitors}, lsb {lsb_first}, max request {max_request_bytes} bytes, scale {dpi_scale}",
            argb_visual_id
        ));
        Ok(Display {
            conn,
            root,
            screen_w,
            screen_h,
            argb_visual,
            lsb_first,
            max_request_bytes,
            atoms,
            cm_atom,
            randr_monitors,
            dpi_scale,
            scratch: Vec::new(),
        })
    }

    /// True when a compositing manager runs (it owns `_NET_WM_CM_S<n>`) and the server has an ARGB visual.
    /// Without both, a 32-bit window shows black instead of being see-through.
    pub fn can_overlay(&self) -> bool {
        self.argb_visual.is_some() && self.has_compositor()
    }

    pub fn has_compositor(&self) -> bool {
        match self.conn.get_selection_owner(self.cm_atom) {
            Ok(c) => c.reply().map(|r| r.owner != x11rb::NONE).unwrap_or(false),
            Err(_) => false,
        }
    }

    /// The monitors in global coordinates (RandR 1.5), or the whole screen as one monitor.
    pub fn monitors(&self) -> Vec<Monitor> {
        let mut out = Vec::new();
        if self.randr_monitors {
            if let Ok(reply) = self
                .conn
                .randr_get_monitors(self.root, true)
                .map_err(|e| e.to_string())
                .and_then(|c| c.reply().map_err(|e| e.to_string()))
            {
                for m in reply.monitors {
                    if m.width == 0 || m.height == 0 {
                        continue;
                    }
                    let name = self
                        .conn
                        .get_atom_name(m.name)
                        .ok()
                        .and_then(|c| c.reply().ok())
                        .map(|r| String::from_utf8_lossy(&r.name).into_owned())
                        .unwrap_or_default();
                    out.push(Monitor {
                        rect: Rect::new(m.x as i32, m.y as i32, m.width as i32, m.height as i32),
                        primary: m.primary,
                        name,
                    });
                }
            }
        }
        if out.is_empty() {
            out.push(Monitor {
                rect: Rect::new(0, 0, self.screen_w, self.screen_h),
                primary: true,
                name: "screen".into(),
            });
        }
        if !out.iter().any(|m| m.primary) {
            out[0].primary = true;
        }
        out
    }

    /// Creates and shows a transparent, click-through, always-on-top window covering `r` (global coordinates).
    pub fn create_overlay(&self, r: Rect) -> Res<OverlayWindow> {
        let (visual, colormap) = self.argb_visual.ok_or("no 32-bit visual")?;
        let win = self.conn.generate_id()?;
        // border_pixel and colormap are required when the visual differs from the root's (else BadMatch).
        let aux = CreateWindowAux::new()
            .background_pixel(0)
            .border_pixel(0)
            .colormap(colormap)
            .override_redirect(1)
            .event_mask(EventMask::EXPOSURE);
        self.conn.create_window(
            32,
            win,
            self.root,
            r.x as i16,
            r.y as i16,
            r.w as u16,
            r.h as u16,
            0,
            WindowClass::INPUT_OUTPUT,
            visual,
            &aux,
        )?;
        self.conn.change_property8(PropMode::REPLACE, win, AtomEnum::WM_NAME, AtomEnum::STRING, b"JuleHygge")?;
        self.conn.change_property8(
            PropMode::REPLACE,
            win,
            self.atoms._NET_WM_NAME,
            self.atoms.UTF8_STRING,
            b"JuleHygge",
        )?;
        self.conn.change_property8(
            PropMode::REPLACE,
            win,
            AtomEnum::WM_CLASS,
            AtomEnum::STRING,
            b"julehygge\0JuleHygge\0",
        )?;
        // Hints for compositors: a notification-like window, and never unredirect (2 = do not bypass compositing).
        self.conn.change_property32(
            PropMode::REPLACE,
            win,
            self.atoms._NET_WM_WINDOW_TYPE,
            AtomEnum::ATOM,
            &[self.atoms._NET_WM_WINDOW_TYPE_NOTIFICATION],
        )?;
        self.conn.change_property32(
            PropMode::REPLACE,
            win,
            self.atoms._NET_WM_BYPASS_COMPOSITOR,
            AtomEnum::CARDINAL,
            &[2],
        )?;

        // Empty input region: clicks, scrolling and hovering all reach the windows below.
        let region = self.conn.generate_id()?;
        self.conn.xfixes_create_region(region, &[])?;
        self.conn.xfixes_set_window_shape_region(win, shape::SK::INPUT, 0, 0, region)?;
        self.conn.xfixes_destroy_region(region)?;

        let gc = self.conn.generate_id()?;
        self.conn.create_gc(gc, win, &CreateGCAux::new().graphics_exposures(0))?;
        self.conn.map_window(win)?;
        self.conn.flush()?;
        Ok(OverlayWindow { win, gc })
    }

    pub fn destroy_overlay(&self, w: &OverlayWindow) {
        let _ = self.conn.free_gc(w.gc);
        let _ = self.conn.destroy_window(w.win);
        let _ = self.conn.flush();
    }

    /// Puts the window above all others again (the `KeepOnTop()` of `src/Layer.cs`).
    pub fn raise(&self, w: &OverlayWindow) {
        let _ = self.conn.configure_window(w.win, &ConfigureWindowAux::new().stack_mode(StackMode::ABOVE));
    }

    /// Sends the given rectangles of a premultiplied ARGB32 buffer (`stride` pixels per row) to the window.
    /// Each rectangle is split into bands of rows that fit in one request.
    pub fn put(&mut self, w: &OverlayWindow, pixels: &[u32], stride: usize, rects: &[Rect]) -> Res<()> {
        for r in rects {
            if r.is_empty() {
                continue;
            }
            let row_bytes = r.w as usize * 4;
            // PutImage header is 24 bytes; keep a little room.
            let rows_per_req = ((self.max_request_bytes.saturating_sub(64)) / row_bytes).max(1);
            let mut y = r.y;
            while y < r.bottom() {
                let rows = (r.bottom() - y).min(rows_per_req as i32);
                self.scratch.clear();
                self.scratch.reserve(rows as usize * row_bytes);
                for yy in y..y + rows {
                    let start = yy as usize * stride + r.x as usize;
                    let row = &pixels[start..start + r.w as usize];
                    if self.lsb_first {
                        for p in row {
                            self.scratch.extend_from_slice(&p.to_le_bytes());
                        }
                    } else {
                        for p in row {
                            self.scratch.extend_from_slice(&p.to_be_bytes());
                        }
                    }
                }
                self.conn.put_image(
                    ImageFormat::Z_PIXMAP,
                    w.win,
                    w.gc,
                    r.w as u16,
                    rows as u16,
                    r.x as i16,
                    y as i16,
                    0,
                    32,
                    &self.scratch,
                )?;
                y += rows;
            }
        }
        Ok(())
    }

    pub fn flush(&self) -> Res<()> {
        self.conn.flush()?;
        Ok(())
    }

    /// All events that have arrived, without waiting. An error here means the X server is gone.
    pub fn poll_events(&self) -> Res<Vec<Event>> {
        let mut v = Vec::new();
        while let Some(e) = self.conn.poll_for_event()? {
            v.push(e);
        }
        Ok(v)
    }
}

/// The desktop's scale factor: `JULE_SCALE`, else `Xft.dpi / 96` from the X resources (set by GNOME and Cinnamon
/// for HiDPI), at least 1. X11 has no per-monitor scale.
fn read_dpi_scale(conn: &RustConnection, root: Window) -> f32 {
    if let Some(s) = std::env::var("JULE_SCALE").ok().and_then(|v| v.trim().parse::<f32>().ok()) {
        if s > 0.0 {
            return s.max(1.0);
        }
    }
    let prop = conn
        .get_property(false, root, AtomEnum::RESOURCE_MANAGER, AtomEnum::STRING, 0, 1 << 20)
        .ok()
        .and_then(|c| c.reply().ok());
    if let Some(p) = prop {
        let text = String::from_utf8_lossy(&p.value);
        if let Some(dpi) = parse_xft_dpi(&text) {
            return (dpi / 96.0).max(1.0);
        }
    }
    1.0
}

fn parse_xft_dpi(resources: &str) -> Option<f32> {
    resources.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        if k.trim() == "Xft.dpi" {
            v.trim().parse::<f32>().ok()
        } else {
            None
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clip_keeps_inside() {
        assert_eq!(Rect::new(-5, -5, 20, 20).clip(10, 10), Rect::new(0, 0, 10, 10));
        assert!(Rect::new(50, 0, 5, 5).clip(10, 10).is_empty());
        assert_eq!(Rect::new(2, 3, 4, 5).clip(100, 100), Rect::new(2, 3, 4, 5));
    }

    #[test]
    fn xft_dpi() {
        assert_eq!(parse_xft_dpi("Xft.antialias:\t1\nXft.dpi:\t168\nXcursor.size:\t24\n"), Some(168.0));
        assert_eq!(parse_xft_dpi("Xcursor.size: 24"), None);
    }
}
