//! The snowflake icon in the panel (StatusNotifierItem): Ubuntu shows it through its AppIndicator extension,
//! Cinnamon (Mint) natively. Corresponds to the `NotifyIcon` in `src/Controller.cs`.
//!
//! Phase 1 menu: a status line and Quit. The full menu (settings, calendar, Santa) follows in later phases.
//! Tray hosts deliver no double-clicks, so "call Santa" will be a menu item. Menu texts live in `text.rs`.
//!
//! The tray runs on its own thread; it only sends messages to the main loop.

use std::sync::mpsc::Sender;

use ksni::blocking::TrayMethods;

pub enum TrayMsg {
    Quit,
}

pub struct AppTray {
    tx: Sender<TrayMsg>,
    icons: Vec<ksni::Icon>,
    /// Shown greyed out at the top of the menu and in the tooltip (e.g. `text::NEEDS_COMPOSITOR`), or empty.
    pub status: String,
}

pub type TrayHandle = ksni::blocking::Handle<AppTray>;

impl ksni::Tray for AppTray {
    fn id(&self) -> String {
        "julehygge".into()
    }

    fn title(&self) -> String {
        "JuleHygge".into()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        self.icons.clone()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip { title: "JuleHygge".into(), description: self.status.clone(), ..Default::default() }
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::{MenuItem, StandardItem};
        let mut items: Vec<MenuItem<Self>> = Vec::new();
        if !self.status.is_empty() {
            items.push(StandardItem { label: self.status.clone(), enabled: false, ..Default::default() }.into());
            items.push(MenuItem::Separator);
        }
        items.push(
            StandardItem {
                label: crate::text::QUIT.into(),
                icon_name: "application-exit".into(),
                activate: Box::new(|t: &mut Self| {
                    let _ = t.tx.send(TrayMsg::Quit);
                }),
                ..Default::default()
            }
            .into(),
        );
        items
    }
}

/// Starts the tray icon. Without a tray host (or D-Bus) the app keeps running without it; it can then only be
/// stopped from a terminal (`pkill -x JuleHygge`).
pub fn spawn(tx: Sender<TrayMsg>, status: String) -> Option<TrayHandle> {
    let mut icons = Vec::new();
    for size in [16, 22, 24, 32, 48, 64] {
        match crate::icon::argb_be(size) {
            Ok(data) => icons.push(ksni::Icon { width: size, height: size, data }),
            Err(e) => crate::log::error(&format!("icon {size}: {e}")),
        }
    }
    match (AppTray { tx, icons, status }).spawn() {
        Ok(h) => Some(h),
        Err(e) => {
            crate::log::error(&format!("no tray icon: {e}"));
            None
        }
    }
}
