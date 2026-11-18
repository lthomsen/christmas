//! JuleHygge for Linux (Ubuntu and Linux Mint): snow over the desktop, with a snowflake in the panel.
//! See linux/README.md and docs/linux-plan.md. All user-facing text is Danish.

mod clock;
mod controller;
mod icon;
mod layer;
mod log;
mod rng;
mod settings;
mod tray;
mod weather;
mod x11;

use std::path::PathBuf;

pub const VERSION: &str = env!("JULE_VERSION");

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut opts = controller::Options { snapshot: None };
    for a in &args {
        if a == "--version" {
            println!("JuleHygge {VERSION}");
            return;
        } else if let Some(v) = a.strip_prefix("--snapshot=") {
            // --snapshot=DIR[,SECONDS]: writes each screen's overlay as screenN.png after SECONDS (default 5)
            let (dir, secs) = match v.rsplit_once(',') {
                Some((d, s)) if s.parse::<f32>().is_ok() => (d, s.parse::<f32>().unwrap_or(5.0)),
                _ => (v, 5.0),
            };
            opts.snapshot = Some((PathBuf::from(dir), secs));
        } else {
            eprintln!("JuleHygge: unknown argument {a}");
        }
    }

    // Only one JuleHygge per user session. The lock is released when the process ends, also after a crash.
    let lock_path = log::runtime_dir().join("julehygge.lock");
    let _lock = match std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(&lock_path) {
        Ok(f) => match f.try_lock() {
            Ok(()) => Some(f),
            Err(std::fs::TryLockError::WouldBlock) => {
                eprintln!("JuleHygge kører allerede.");
                return;
            }
            Err(std::fs::TryLockError::Error(e)) => {
                log::error(&format!("lock {}: {e}", lock_path.display()));
                None
            }
        },
        Err(e) => {
            log::error(&format!("lock {}: {e}", lock_path.display()));
            None
        }
    };

    log::debug(&format!("JuleHygge {VERSION} starting, args {args:?}"));
    let result = controller::Controller::new(opts).and_then(|mut c| c.run());
    if let Err(e) = result {
        log::error(&format!("{e}"));
        std::process::exit(1);
    }
}
