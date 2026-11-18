//! Whether anyone can see the overlay, and whether the computer runs on battery. Corresponds to the
//! `SessionSwitch`/screen saver part of `src/Controller.cs`.
//!
//! A thread asks D-Bus once a second (polling also finds services that start later, and costs nothing next to
//! drawing):
//! - logind: the session's `LockedHint` (system bus);
//! - the screen saver's `GetActive`: Cinnamon, GNOME, and the freedesktop name used by Xfce and KDE (session bus).
//!   Only services that already run are asked, so no screen saver is started by D-Bus activation.
//!
//! Suspend needs no signal: the process is frozen while the computer sleeps, and the controller's frame-stall
//! check ends anything on its way when it wakes up. DPMS (display off) is read over X11 in `x11.rs`.
//!
//! The battery is read from `/sys/class/power_supply`, which is what UPower reads too.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use zbus::names::InterfaceName;
use zbus::Connection;

const SCREEN_SAVERS: [(&str, &str); 3] = [
    ("org.cinnamon.ScreenSaver", "/org/cinnamon/ScreenSaver"),
    ("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver"),
    ("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver"),
];

#[derive(Clone, Default)]
pub struct SessionWatch {
    locked: Arc<AtomicBool>,
    saver: Arc<AtomicBool>,
}

impl SessionWatch {
    pub fn locked(&self) -> bool {
        self.locked.load(Ordering::Relaxed)
    }
    pub fn screen_saver(&self) -> bool {
        self.saver.load(Ordering::Relaxed)
    }
}

/// Starts the D-Bus thread. Without D-Bus both stay false, and the overlay simply keeps running.
pub fn spawn() -> SessionWatch {
    let watch = SessionWatch::default();
    let w = watch.clone();
    let started = std::thread::Builder::new().name("session".into()).spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(rt) => rt,
            Err(e) => {
                crate::log::error(&format!("session watch: {e}"));
                return;
            }
        };
        let (mut system, mut session) = (None, None);
        loop {
            rt.block_on(poll(&w, &mut system, &mut session));
            std::thread::sleep(Duration::from_secs(1));
        }
    });
    if let Err(e) = started {
        crate::log::error(&format!("session watch: {e}"));
    }
    watch
}

/// One round of questions. A bus that cannot be reached is tried again on the next round.
async fn poll(w: &SessionWatch, system: &mut Option<Connection>, session: &mut Option<Connection>) {
    if system.is_none() {
        *system = Connection::system().await.ok();
    }
    if session.is_none() {
        *session = Connection::session().await.ok();
    }
    if let Some(c) = system.as_ref() {
        let locked = locked_hint(c).await.unwrap_or(false);
        if w.locked.swap(locked, Ordering::Relaxed) != locked {
            crate::log::debug(&format!("session locked: {locked}"));
        }
    }
    if let Some(c) = session.as_ref() {
        let mut active = false;
        for (name, path) in SCREEN_SAVERS {
            if screen_saver_active(c, name, path).await.unwrap_or(false) {
                active = true;
                break;
            }
        }
        if w.saver.swap(active, Ordering::Relaxed) != active {
            crate::log::debug(&format!("screen saver active: {active}"));
        }
    }
}

/// logind's `LockedHint` for the session this process belongs to (`session/auto`).
async fn locked_hint(c: &Connection) -> zbus::Result<bool> {
    let props = zbus::fdo::PropertiesProxy::builder(c)
        .destination("org.freedesktop.login1")?
        .path("/org/freedesktop/login1/session/auto")?
        .build()
        .await?;
    let v = props.get(InterfaceName::from_static_str_unchecked("org.freedesktop.login1.Session"), "LockedHint").await?;
    Ok(bool::try_from(v).unwrap_or(false))
}

async fn screen_saver_active(c: &Connection, name: &'static str, path: &'static str) -> zbus::Result<bool> {
    let dbus = zbus::fdo::DBusProxy::new(c).await?;
    if !dbus.name_has_owner(name.try_into()?).await? {
        return Ok(false);
    }
    let reply = c.call_method(Some(name), path, Some(name), "GetActive", &()).await?;
    reply.body().deserialize::<bool>()
}

/// True when the computer has a battery of its own and no charger is plugged in. Batteries of wireless mice and
/// keyboards (`scope` = Device) do not count, so a desktop PC is never "on battery".
pub fn on_battery() -> bool {
    on_battery_in(std::path::Path::new("/sys/class/power_supply"))
}

fn on_battery_in(dir: &std::path::Path) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else { return false };
    let (mut battery, mut charger) = (false, false);
    for e in entries.flatten() {
        let read =
            |f: &str| std::fs::read_to_string(e.path().join(f)).map(|s| s.trim().to_string()).unwrap_or_default();
        match read("type").as_str() {
            "Battery" if read("scope") != "Device" => battery = true,
            "Mains" | "USB" if read("online") == "1" => charger = true,
            _ => {}
        }
    }
    battery && !charger
}

#[cfg(test)]
mod tests {
    use super::*;

    fn supply(dir: &std::path::Path, name: &str, files: &[(&str, &str)]) {
        let d = dir.join(name);
        std::fs::create_dir_all(&d).unwrap();
        for (f, v) in files {
            std::fs::write(d.join(f), format!("{v}\n")).unwrap();
        }
    }

    #[test]
    fn battery_detection() {
        let base = std::env::temp_dir().join(format!("julehygge-power-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);

        // desktop PC with two wireless mice: never on battery
        let pc = base.join("pc");
        supply(&pc, "hidpp_battery_0", &[("type", "Battery"), ("scope", "Device")]);
        supply(&pc, "hidpp_battery_1", &[("type", "Battery"), ("scope", "Device")]);
        assert!(!on_battery_in(&pc));

        // laptop: on battery when the charger is unplugged
        let laptop = base.join("laptop");
        supply(&laptop, "BAT0", &[("type", "Battery"), ("status", "Discharging")]);
        supply(&laptop, "AC", &[("type", "Mains"), ("online", "0")]);
        assert!(on_battery_in(&laptop));
        supply(&laptop, "AC", &[("type", "Mains"), ("online", "1")]);
        assert!(!on_battery_in(&laptop));

        assert!(!on_battery_in(&base.join("missing")));
        let _ = std::fs::remove_dir_all(&base);
    }
}
