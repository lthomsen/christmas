using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace JuleHygge
{
    class Settings
    {
        public bool Snow = true, SnowGround = true, Santa = true, Nisser = true, Lights = true,
                    PauseFullscreen = true, Snowman = true, AllScreens = true;
        public int SnowLevel = 1;          // 0 = let, 1 = normal, 2 = snestorm
        public int NisseCount = 3;         // pr. skærm
        public int SnowmanSeenStage = 0;
        public int CalendarYear = 0;
        public DateTime FirstRun = DateTime.MinValue, LastDoorNotice = DateTime.MinValue;
        public HashSet<int> OpenedDoors = new HashSet<int>();

        static string FilePath
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "JuleHygge", "settings.ini"); }
        }

        public static Settings Load()
        {
            var s = new Settings();
            var d = new Dictionary<string, string>();
            try
            {
                if (File.Exists(FilePath))
                    foreach (var line in File.ReadAllLines(FilePath))
                    {
                        int i = line.IndexOf('=');
                        if (i > 0) d[line.Substring(0, i).Trim()] = line.Substring(i + 1).Trim();
                    }
            }
            catch { }

            s.Snow = B(d, "Snow", s.Snow);
            s.SnowGround = B(d, "SnowGround", s.SnowGround);
            s.Santa = B(d, "Santa", s.Santa);
            s.Nisser = B(d, "Nisser", s.Nisser);
            s.Lights = B(d, "Lights", s.Lights);
            s.PauseFullscreen = B(d, "PauseFullscreen", s.PauseFullscreen);
            s.Snowman = B(d, "Snowman", s.Snowman);
            s.AllScreens = B(d, "AllScreens", s.AllScreens);
            s.SnowLevel = Math.Max(0, Math.Min(2, I(d, "SnowLevel", s.SnowLevel)));
            s.NisseCount = Math.Max(1, Math.Min(12, I(d, "NisseCount", s.NisseCount)));
            s.SnowmanSeenStage = I(d, "SnowmanSeenStage", 0);
            s.CalendarYear = I(d, "CalendarYear", 0);
            s.FirstRun = D(d, "FirstRun");
            s.LastDoorNotice = D(d, "LastDoorNotice");
            string od;
            if (d.TryGetValue("OpenedDoors", out od))
                foreach (var part in od.Split(','))
                {
                    int n;
                    if (int.TryParse(part, out n) && n >= 1 && n <= 24) s.OpenedDoors.Add(n);
                }
            return s;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
                File.WriteAllLines(FilePath, new[] {
                    "Snow=" + B(Snow), "SnowGround=" + B(SnowGround), "Santa=" + B(Santa),
                    "Nisser=" + B(Nisser), "Lights=" + B(Lights), "PauseFullscreen=" + B(PauseFullscreen),
                    "Snowman=" + B(Snowman), "AllScreens=" + B(AllScreens),
                    "SnowLevel=" + SnowLevel, "NisseCount=" + NisseCount,
                    "SnowmanSeenStage=" + SnowmanSeenStage, "CalendarYear=" + CalendarYear,
                    "FirstRun=" + Ds(FirstRun), "LastDoorNotice=" + Ds(LastDoorNotice),
                    "OpenedDoors=" + string.Join(",", OpenedDoors.OrderBy(x => x)) });
            }
            catch { }
        }

        static string B(bool b) { return b ? "1" : "0"; }
        static string Ds(DateTime d) { return d == DateTime.MinValue ? "" : d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture); }

        static bool B(Dictionary<string, string> d, string k, bool def)
        {
            string v;
            return d.TryGetValue(k, out v) ? v == "1" : def;
        }
        static int I(Dictionary<string, string> d, string k, int def)
        {
            string v; int n;
            return d.TryGetValue(k, out v) && int.TryParse(v, out n) ? n : def;
        }
        static DateTime D(Dictionary<string, string> d, string k)
        {
            string v; DateTime t;
            if (d.TryGetValue(k, out v) && DateTime.TryParseExact(v, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out t))
                return t;
            return DateTime.MinValue;
        }
    }
}
