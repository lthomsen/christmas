using System;
using System.Collections.Generic;

namespace JuleHygge
{
    // "Skiftende vejr": the snow changes by itself between light snow, normal and snowstorm over the day.
    //
    // The day is a row of spells of very different lengths: light snow lasts 8-90 minutes, normal snow 6-70, a
    // snowstorm 4-25, and short spells are the most common (a long one now and then). What follows is drawn by lot:
    // after light snow mostly normal, sometimes a storm straight away; after a storm mostly normal, sometimes light.
    //
    // The row is worked out from the date alone, so it is the same after a restart, on every screen, and in the
    // macOS version (macos/Sources/JuleHygge/Weather.swift is the same, line for line, with the same random numbers).
    static class Weather
    {
        // A spell starts Start seconds after midnight and lasts until the next one.
        public struct Spell { public double Start; public int Level; }

        // The day's spells, in order; the first starts at midnight.
        public static List<Spell> Spells(int year, int month, int day)
        {
            ulong state = unchecked((ulong)(year * 10000 + month * 100 + day) * 0x9E3779B97F4A7C15UL + 1UL);
            var result = new List<Spell>();
            double first = Next(ref state);
            int level = first < 0.45 ? 0 : first < 0.9 ? 1 : 2;
            double t = 0;
            while (t < 86400)
            {
                result.Add(new Spell { Start = t, Level = level });
                double r = Next(ref state);
                // (r*r: most spells are short, a few are long)
                double minutes = level == 0 ? 8 + 82 * r * r : level == 1 ? 6 + 64 * r * r : 4 + 21 * r * r;
                t += minutes * 60;
                double lot = Next(ref state);
                if (level == 0) level = lot < 0.8 ? 1 : 2;
                else if (level == 1) level = lot < 0.65 ? 0 : 2;
                else level = lot < 0.65 ? 1 : 0;
            }
            return result;
        }

        static double Next(ref ulong state)
        {
            state = unchecked(state * 6364136223846793005UL + 1442695040888963407UL);
            return (double)(state >> 40) / 16777216.0;
        }

        // How long the snow takes to go from one level to another (seconds): a storm builds up in a minute and a
        // half and dies down over three minutes; between light and normal it takes four.
        public static double Ramp(int from, int to) { return to == 2 ? 90 : from == 2 ? 180 : 240; }

        // How much it snows `seconds` after midnight on a day, as a number that glides: 0 light, 1 normal, 2 storm,
        // and everything in between while one spell passes into the next. `before` is the level the day before ended on.
        public static double Amount(List<Spell> spells, int before, double seconds)
        {
            int k = -1;
            for (int i = 0; i < spells.Count; i++) if (spells[i].Start <= seconds) k = i;
            if (k < 0) return before;
            int now = spells[k].Level, was = k > 0 ? spells[k - 1].Level : before;
            double t = Math.Min(1.0, Math.Max(0.0, (seconds - spells[k].Start) / Ramp(was, now)));
            return was + (now - was) * (t * t * (3 - 2 * t));
        }

        static double cachedAmount = 1;
        static long cachedAt = long.MinValue;

        // How much it snows right now (0 light ... 2 storm, gliding). Looked up at most once a second.
        public static double Amount()
        {
            long now = Environment.TickCount;
            if (cachedAt != long.MinValue && Math.Abs(now - cachedAt) < 1000) return cachedAmount;
            // (JULE_DATE moves the date, as for the calendar; the time of day is the real one)
            DateTime d = JuleClock.Today;
            DateTime y = d.AddDays(-1);
            List<Spell> yesterday = Spells(y.Year, y.Month, y.Day);
            int before = yesterday.Count > 0 ? yesterday[yesterday.Count - 1].Level : 1;
            cachedAmount = Amount(Spells(d.Year, d.Month, d.Day), before, DateTime.Now.TimeOfDay.TotalSeconds);
            cachedAt = now;
            return cachedAmount;
        }
    }
}
