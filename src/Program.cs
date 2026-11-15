using System;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JuleHygge
{
    static class Program
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

        [STAThread]
        static void Main(string[] args)
        {
            bool createdNew;
            using (var mutex = new System.Threading.Mutex(true, "JuleHygge_SingleInstance", out createdNew))
            {
                if (!createdNew) return;
                try { SetProcessDPIAware(); } catch { }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                // A decoration must never pop up crash dialogs: log UI-thread exceptions and keep running.
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += (s, e) => ErrorLog.Write(e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => ErrorLog.Write(e.ExceptionObject as Exception);
                var controller = new Controller();
                if (Array.IndexOf(args, "--kalender") >= 0) controller.ShowCalendar();
                // --sneplov sends the snow plow after 3 s; --sneplov=N after N seconds (handy for testing).
                foreach (var a in args)
                {
                    if (a == "--sneplov") controller.SendPlowAfter(3);
                    else if (a.StartsWith("--sneplov="))
                    {
                        float secs;
                        if (float.TryParse(a.Substring(10), NumberStyles.Float, CultureInfo.InvariantCulture, out secs))
                            controller.SendPlowAfter(secs);
                    }
                }
                Application.Run(controller);
            }
        }
    }

    // Appends errors to %TEMP%\julehygge-error.log, with a cap so a repeating error cannot grow it forever.
    static class ErrorLog
    {
        static int written;

        public static void Write(Exception ex)
        {
            if (ex == null || written >= 200) return;
            written++;
            try
            {
                System.IO.File.AppendAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "julehygge-error.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + " " + ex + Environment.NewLine + Environment.NewLine);
            }
            catch { }
        }
    }

    static class JuleClock
    {
        // Sæt miljøvariablen JULE_DATE=2026-12-10 for at teste julekalender og snemand på en anden dato.
        public static DateTime Today
        {
            get
            {
                string s = Environment.GetEnvironmentVariable("JULE_DATE");
                DateTime d;
                if (!string.IsNullOrEmpty(s) && DateTime.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out d))
                    return d;
                return DateTime.Today;
            }
        }
    }

    class Flake
    {
        public float X, Y, R, Vy, Phase, Sway, SwaySpd, Rot, RotSpd;
        public int A;
        public bool Crystal;
    }

    class Spark
    {
        public float X, Y, VX, VY, Life, Max, Size;
        public bool Gold, Star;
    }

    class Nisse
    {
        public float X, Dir, Speed, WalkPhase, T, StateTimer, Size;
        public int State;          // 0 = går, 1 = står stille, 2 = vinker
        public bool CarriesGift;
        public System.Drawing.Color Tunic, Mitten, Gift;
    }
}
