import Foundation
import QuartzCore

/// "Skiftende vejr": the snow changes by itself between light snow, normal and snowstorm over the day.
///
/// The day is a row of spells of very different lengths: light snow lasts 8–90 minutes, normal snow 6–70, a
/// snowstorm 4–25, and short spells are the most common (a long one now and then). What follows is drawn by lot:
/// after light snow mostly normal, sometimes a storm straight away; after a storm mostly normal, sometimes light.
/// (First the spells were one to three hours, evenly spread: too slow and too regular to notice.)
///
/// The row is worked out from the date alone, so it is the same after a restart, on every screen, and in the
/// Windows version (src/Weather.cs follows this file line for line, with the same random numbers).
enum Weather {
    /// A spell starts `start` seconds after midnight and lasts until the next one.
    struct Spell { var start: Double, level: Int }

    /// The day's spells, in order; the first starts at midnight.
    static func spells(year: Int, month: Int, day: Int) -> [Spell] {
        var state = UInt64(year * 10000 + month * 100 + day) &* 0x9E3779B97F4A7C15 &+ 1
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 40) / 16777216
        }
        var out: [Spell] = []
        let first = next()
        var level = first < 0.45 ? 0 : first < 0.9 ? 1 : 2
        var t = 0.0
        while t < 86400 {
            out.append(Spell(start: t, level: level))
            let r = next()
            // (r·r: most spells are short, a few are long)
            let minutes = level == 0 ? 8 + 82 * r * r : level == 1 ? 6 + 64 * r * r : 4 + 21 * r * r
            t += minutes * 60
            let lot = next()
            switch level {
            case 0: level = lot < 0.8 ? 1 : 2
            case 1: level = lot < 0.65 ? 0 : 2
            default: level = lot < 0.65 ? 1 : 0
            }
        }
        return out
    }

    /// How long the snow takes to go from one level to another (seconds): a storm builds up in a minute and a
    /// half and dies down over three minutes; between light and normal it takes four.
    static func ramp(from: Int, to: Int) -> Double { to == 2 ? 90 : from == 2 ? 180 : 240 }

    /// How much it snows `seconds` after midnight on a day, as a number that glides: 0 light, 1 normal, 2 storm,
    /// and everything in between while one spell passes into the next. `before` is the level the day before ended on.
    static func amount(_ spells: [Spell], before: Int, at seconds: Double) -> Double {
        guard let k = spells.lastIndex(where: { $0.start <= seconds }) else { return Double(before) }
        let now = spells[k].level, was = k > 0 ? spells[k - 1].level : before
        let t = min(1, max(0, (seconds - spells[k].start) / ramp(from: was, to: now)))
        return Double(was) + Double(now - was) * (t * t * (3 - 2 * t))
    }

    private nonisolated(unsafe) static var cached = (at: -100.0, amount: 1.0)
    private static let started = Date()
    /// JULE_VEJR_TID=HH:MM starts the day's weather at that time of day (the clock runs on from there), to watch a
    /// change without waiting for it.
    private static let startAt: Double? = {
        guard let p = ProcessInfo.processInfo.environment["JULE_VEJR_TID"]?.split(separator: ":"), p.count == 2,
              let h = Double(p[0]), let m = Double(p[1]) else { return nil }
        return h * 3600 + m * 60
    }()

    /// How much it snows right now (0 light … 2 storm, gliding). Looked up at most once a second.
    static func amount() -> Double {
        let now = CACurrentMediaTime()
        if now - cached.at < 1 { return cached.amount }
        // (JULE_DATE moves the date, as for the calendar; the time of day is the real one)
        let today = JuleClock.today
        let d = JuleClock.parts(today)
        var seconds: Double
        if let startAt { seconds = (startAt + Date().timeIntervalSince(started)).truncatingRemainder(dividingBy: 86400) }
        else {
            let clock = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            let hour: Int = clock.hour ?? 0, minute: Int = clock.minute ?? 0, second: Int = clock.second ?? 0
            seconds = Double(hour * 3600 + minute * 60 + second)
        }
        let y = JuleClock.parts(Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today)
        let before = spells(year: y.year, month: y.month, day: y.day).last?.level ?? 1
        let a = amount(spells(year: d.year, month: d.month, day: d.day), before: before, at: seconds)
        cached = (now, a)
        return a
    }

    /// Test aid (--vejr-test[=DAYS]): prints the spells of today and the following days, and how the time is shared.
    static func test(days: Int) {
        let names = ["let sne", "normal", "snestorm"]
        var share = [0.0, 0.0, 0.0], count = [0, 0, 0]
        for i in 0..<max(1, days) {
            let date = Calendar.current.date(byAdding: .day, value: i, to: JuleClock.today)!
            let d = JuleClock.parts(date)
            let s = spells(year: d.year, month: d.month, day: d.day)
            var line = String(format: "%04d-%02d-%02d ", d.year, d.month, d.day)
            for (k, spell) in s.enumerated() {
                let end = k + 1 < s.count ? s[k + 1].start : 86400
                share[spell.level] += min(end, 86400) - spell.start; count[spell.level] += 1
                line += String(format: " %02d:%02d %@", Int(spell.start) / 3600, Int(spell.start) % 3600 / 60, names[spell.level])
            }
            if i < 4 { print(line) }
        }
        // the first change into a storm today, minute by minute, to see how it comes and goes
        let d = JuleClock.parts(JuleClock.today)
        let s = spells(year: d.year, month: d.month, day: d.day)
        if let k = s.firstIndex(where: { $0.level == 2 && $0.start > 0 }) {
            var line = "ind i og ud af første storm, hvert halve minut:"
            let end = k + 1 < s.count ? s[k + 1].start : s[k].start + 600
            for step in stride(from: s[k].start - 30, through: s[k].start + 150, by: 30) { line += String(format: " %.2f", amount(s, before: 1, at: step)) }
            line += " …"
            for step in stride(from: end - 30, through: end + 210, by: 30) { line += String(format: " %.2f", amount(s, before: 1, at: step)) }
            print(line)
        }
        let total = share.reduce(0, +)
        for l in 0..<3 {
            print(String(format: "%@: %.0f %% af tiden, %d perioder på %d dage, i snit %.0f min", names[l], share[l] / total * 100, count[l], max(1, days),
                         count[l] > 0 ? share[l] / Double(count[l]) / 60 : 0))
        }
    }
}
