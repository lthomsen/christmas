//! JuleHygge for Linux (Ubuntu and Linux Mint): snow over the desktop, with a snowflake in the panel.
//! See linux/README.md and docs/linux-plan.md. All user-facing text is Danish.

mod autostart;
mod calendar;
mod clock;
mod controller;
mod figures;
mod icon;
mod layer;
mod log;
mod rng;
mod session;
mod settings;
mod sound;
mod text;
mod tray;
mod weather;
mod x11;

use std::path::PathBuf;

pub const VERSION: &str = env!("APP_VERSION");

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut opts = controller::Options::default();
    for a in &args {
        if a == "--version" {
            println!("JuleHygge {VERSION}");
            return;
        } else if let Some(file) = a.strip_prefix("--calendar-snapshot=") {
            // draws the calendar into a PNG file without opening a window (at JULE_SCALE, default 2)
            let k = std::env::var("JULE_SCALE").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(2.0);
            if let Err(e) = calendar::render_to_png(&settings::Settings::load(), k, std::path::Path::new(file)) {
                eprintln!("JuleHygge: {file}: {e}");
                std::process::exit(1);
            }
            return;
        } else if let Some(dir) = a.strip_prefix("--sound-test=").or_else(|| a.strip_prefix("--lyd-test=")) {
            // writes the synthesized sounds as WAV files and a summary, without starting the app
            match sound::write_test_files(std::path::Path::new(dir)) {
                Ok(()) => println!("sounds written to {dir}"),
                Err(e) => {
                    eprintln!("JuleHygge: {dir}: {e}");
                    std::process::exit(1);
                }
            }
            return;
        } else if let Some(v) = a.strip_prefix("--snapshot=") {
            // --snapshot=DIR[,SECONDS]: writes each screen's overlay as screenN.png after SECONDS (default 5)
            let (dir, secs) = match v.rsplit_once(',') {
                Some((d, s)) if s.parse::<f32>().is_ok() => (d, s.parse::<f32>().unwrap_or(5.0)),
                _ => (v, 5.0),
            };
            opts.snapshot = Some((PathBuf::from(dir), secs));
        } else if a == "--calendar" || a == "--kalender" {
            opts.calendar = true;
        } else if let Some(v) = a.strip_prefix("--effect=").or_else(|| a.strip_prefix("--effekt=")) {
            match v.parse::<i32>() {
                Ok(n) => opts.effect = Some(n),
                Err(_) => eprintln!("JuleHygge: {a}: not an effect number (1-5)"),
            }
        } else if a == "--santa" || a == "--julemand" {
            opts.santa = true;
        } else if a == "--plow" || a == "--sneplov" {
            // --plow sends the snow plow after 3 s, --plow=N after N seconds (the Danish names work too)
            opts.plow_after = Some(3.0);
        } else if let Some(v) = a.strip_prefix("--plow=").or_else(|| a.strip_prefix("--sneplov=")) {
            match v.parse::<f32>() {
                Ok(secs) => opts.plow_after = Some(secs),
                Err(_) => eprintln!("JuleHygge: {a}: not a number of seconds"),
            }
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
                eprintln!("{}", text::ALREADY_RUNNING);
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
