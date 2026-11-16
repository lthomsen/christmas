using System;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JuleHygge
{
    static class Program
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

        // Test flags run the app directly, without the restart supervisor.
        static readonly string[] TestFlags = { "--kalender", "--julemand", "--sneplov", "--effekt", "--lyd-test" };

        [STAThread]
        static void Main(string[] args)
        {
            // --lyd-test=DIR: write the synthesized sounds as WAV files (to listen to them) and quit.
            foreach (var a in args)
                if (a.StartsWith("--lyd-test=")) { Synth.WriteTestFiles(a.Substring(11)); return; }

            bool isChild = Environment.GetEnvironmentVariable("JULE_SUPERVISOR") != null;
            bool testRun = false;
            foreach (var a in args) foreach (var f in TestFlags) if (a.StartsWith(f)) testRun = true;
            if (!isChild && !testRun && Environment.GetEnvironmentVariable("JULE_NO_SUPERVISOR") == null)
            {
                Supervise(args);
                return;
            }
            RunApp(args);
        }

        // The app first starts as a small watchdog that runs the real app as a child process and restarts it if
        // it crashes (after 5 s; it gives up after 3 crashes within a minute of each start). A normal quit
        // ("Afslut") exits with code 0, and then the watchdog quits too. Ported from macos/.../main.swift.
        static void Supervise(string[] args)
        {
            bool createdNew;
            using (var mutex = new System.Threading.Mutex(true, "JuleHygge_Supervisor", out createdNew))
            {
                if (!createdNew) return;   // already running
                var cmd = new System.Text.StringBuilder();
                foreach (var a in args) cmd.Append(cmd.Length > 0 ? " " : "").Append(a.IndexOf(' ') >= 0 ? "\"" + a + "\"" : a);
                int quickCrashes = 0;
                while (true)
                {
                    var psi = new System.Diagnostics.ProcessStartInfo(Application.ExecutablePath, cmd.ToString());
                    psi.UseShellExecute = false;
                    psi.EnvironmentVariables["JULE_SUPERVISOR"] = System.Diagnostics.Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture);
                    var started = DateTime.Now;
                    int code;
                    try
                    {
                        using (var child = System.Diagnostics.Process.Start(psi))
                        {
                            child.WaitForExit();
                            code = child.ExitCode;
                        }
                    }
                    catch (Exception ex) { ErrorLog.Write(ex); return; }
                    if (code == 0) return;   // normal quit
                    ErrorLog.Write("JuleHygge stoppede uventet (kode " + code + "); genstarter");
                    quickCrashes = (DateTime.Now - started).TotalSeconds < 60 ? quickCrashes + 1 : 0;
                    if (quickCrashes >= 3) { ErrorLog.Write("supervisor: crasher igen og igen, giver op"); return; }
                    System.Threading.Thread.Sleep(5000);
                }
            }
        }

        static void RunApp(string[] args)
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
                    // --julemand sends Santa right away, --effekt=N triggers a calendar effect (testing).
                    else if (a == "--julemand") controller.LaunchSanta();
                    else if (a.StartsWith("--effekt="))
                    {
                        int n;
                        if (int.TryParse(a.Substring(9), NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) controller.TriggerEffect(n);
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

        // With JULE_DEBUG=1, writes a line to %TEMP%\julehygge-debug.log (for testing).
        public static void Debug(string msg)
        {
            if (Environment.GetEnvironmentVariable("JULE_DEBUG") != "1") return;
            try
            {
                System.IO.File.AppendAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "julehygge-debug.log"),
                    DateTime.Now.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture) + " " + msg + Environment.NewLine);
            }
            catch { }
        }

        public static void Write(string msg) { Write(new Exception(msg)); }

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
        // Walking in from an edge, walking out for good, or walking over to the neighbouring screen.
        public bool Entering, Leaving, Crossing;
        public System.Drawing.Color Tunic, Mitten, Gift;
    }
}
