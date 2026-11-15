using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace JuleHygge
{
    // Styrer det hele: bakkeikon, hovedløkke, julemanden (på tværs af skærme), effekter og daglige begivenheder.
    // Selve tegningen sker i ét Layer-vindue pr. skærm.
    class Controller : ApplicationContext
    {
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);

        public readonly Settings Cfg = Settings.Load();
        public readonly Random Rnd = new Random();
        // Seconds since start. A double, because a float loses precision after a few days of uptime
        // and animations would start to stutter.
        public double Time, StormUntil = -1;
        public float Wind;
        public Rectangle FullscreenRect = Rectangle.Empty;
        public Icon AppIcon;

        // julemanden, i virtuelle skærmkoordinater
        public bool SantaActive;
        public float SantaX, SantaY0, SantaDir = 1, SantaSpeed, SantaPhase, SantaScale = 1f;
        float santaMinX, santaMaxX;
        public readonly List<Spark> Sparks = new List<Spark>();

        public const int SnowmanMaxStage = 12;
        public int SnowmanStage = 1;
        static readonly string[] SnowmanSteps = {
            "en lille snebold", "en stor snebold", "maven", "hovedet", "øjne af kul", "en gulerodsnæse",
            "knapper", "arme af grene", "et smil", "et rødt halstørklæde", "en høj hat", "en kost - snemanden er færdig!" };

        readonly List<Layer> layers = new List<Layer>();
        readonly Timer timer;
        readonly Stopwatch clock = Stopwatch.StartNew();
        readonly Control invoker;
        double lastT;
        float windTarget, windTimer, santaNext = 5f, sparkAcc, fsTimer, topTimer, dayTimer;
        double celebrateAt = -1;
        DateTime lastDay;
        NotifyIcon tray;
        ToolStripMenuItem countdownItem, snowmanItem;
        CalendarForm calendar;
        bool balloonOpensCalendar;

        public float SantaY { get { return SantaY0 + (float)Math.Sin(SantaPhase * 0.9) * 40 * SantaScale; } }
        public int EffectiveSnowLevel { get { return Time < StormUntil ? 2 : Cfg.SnowLevel; } }
        public bool SnowOn { get { return Cfg.Snow || Time < StormUntil; } }

        // Power-save mode: snow only in a band above the taskbar, partial screen updates, lower frame rate.
        public bool PowerSave { get; private set; }
        float powerTimer;

        void UpdatePowerSave()
        {
            bool onBattery = SystemInformation.PowerStatus.PowerLineStatus == PowerLineStatus.Offline;
            PowerSave = Cfg.PowerSave == 1 || (Cfg.PowerSave == 2 && onBattery);
            int interval = PowerSave ? 50 : 33;
            if (timer != null && timer.Interval != interval) timer.Interval = interval;
        }

        public Controller()
        {
            invoker = new Control();
            var h = invoker.Handle;   // sikrer et vindueshåndtag til BeginInvoke

            if (Cfg.FirstRun == DateTime.MinValue) { Cfg.FirstRun = JuleClock.Today; Cfg.Save(); }

            AppIcon = MakeIcon();
            BuildTray();
            BuildLayers();
            UpdateDaily(true);
            SystemEvents.DisplaySettingsChanged += OnDisplayChanged;

            timer = new Timer();
            timer.Interval = 33;
            timer.Tick += Tick;
            UpdatePowerSave();
            lastT = clock.Elapsed.TotalSeconds;
            timer.Start();
        }

        float R() { return (float)Rnd.NextDouble(); }

        // ------------------------------------------------------------------ skærme
        void BuildLayers()
        {
            foreach (var l in layers) { l.Close(); l.Dispose(); }
            layers.Clear();
            foreach (var s in Screen.AllScreens)
            {
                if (!Cfg.AllScreens && !s.Primary) continue;
                var l = new Layer(this, s);
                layers.Add(l);
                l.Show();
            }
            if (SantaActive) SantaActive = false;
        }

        void OnDisplayChanged(object sender, EventArgs e)
        {
            invoker.BeginInvoke(new Action(BuildLayers));
        }

        // ------------------------------------------------------------------ hovedløkke
        // Any error skips just this frame and is logged; the overlay must never show crash dialogs.
        void Tick(object sender, EventArgs e)
        {
            try { TickCore(); }
            catch (Exception ex) { ErrorLog.Write(ex); }
        }

        void TickCore()
        {
            double now = clock.Elapsed.TotalSeconds;
            float dt = (float)Math.Min(0.1, now - lastT);
            lastT = now;
            Time += dt;

            dayTimer -= dt;
            if (dayTimer <= 0)
            {
                dayTimer = 30;
                if (JuleClock.Today != lastDay) UpdateDaily(false);
            }

            powerTimer -= dt;
            if (powerTimer <= 0)
            {
                powerTimer = 5;
                UpdatePowerSave();
            }

            fsTimer -= dt;
            if (fsTimer <= 0)
            {
                fsTimer = 1;
                FullscreenRect = Cfg.PauseFullscreen ? GetFullscreenRect() : Rectangle.Empty;
            }

            topTimer -= dt;
            if (topTimer <= 0)
            {
                topTimer = 2;
                foreach (var l in layers) l.KeepOnTop();
            }

            UpdateWind(dt);
            UpdateSanta(dt);
            UpdateSparks(dt);
            if (celebrateAt > 0 && Time >= celebrateAt) { celebrateAt = -1; SnowmanCelebrate(); }
            if (plowAt >= 0 && Time >= plowAt) { plowAt = -1; SendPlow(); }

            // Per screen, so a failing screen (e.g. mid display change) does not stop the others.
            foreach (var l in layers)
            {
                try { l.Frame(dt); }
                catch (Exception ex) { ErrorLog.Write(ex); }
            }
        }

        void UpdateWind(float dt)
        {
            windTimer -= dt;
            if (windTimer <= 0)
            {
                windTimer = 3 + R() * 6;
                bool storm = EffectiveSnowLevel == 2;
                windTarget = (R() * 2 - 1) * (storm ? 140 : 30) + (storm ? 60 : 0);
            }
            Wind += (windTarget - Wind) * Math.Min(1f, dt * 0.5f);
        }

        Rectangle GetFullscreenRect()
        {
            IntPtr fg = GetForegroundWindow();
            if (fg == IntPtr.Zero) return Rectangle.Empty;
            var sb = new StringBuilder(256);
            GetClassName(fg, sb, 256);
            string c = sb.ToString();
            if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return Rectangle.Empty;
            RECT r;
            if (!GetWindowRect(fg, out r)) return Rectangle.Empty;
            return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
        }

        // ------------------------------------------------------------------ julemanden
        public void LaunchSanta()
        {
            if (SantaActive || layers.Count == 0) return;
            var target = layers[Rnd.Next(layers.Count)];
            var b = target.ScreenBounds;
            SantaScale = target.S;
            SantaY0 = b.Y + b.Height * (0.12f + R() * 0.25f);

            // flyv over alle skærme der ligger i samme højde
            santaMinX = b.Left; santaMaxX = b.Right;
            foreach (var l in layers)
            {
                var lb = l.ScreenBounds;
                if (SantaY0 >= lb.Top && SantaY0 < lb.Bottom)
                {
                    santaMinX = Math.Min(santaMinX, lb.Left);
                    santaMaxX = Math.Max(santaMaxX, lb.Right);
                }
            }
            SantaDir = R() < 0.5f ? 1 : -1;
            SantaX = SantaDir > 0 ? santaMinX - 420 * SantaScale : santaMaxX + 420 * SantaScale;
            SantaSpeed = (190 + R() * 80) * SantaScale * (santaMaxX - santaMinX > b.Width * 1.5f ? 1.6f : 1f);
            SantaPhase = 0;
            SantaActive = true;
        }

        void UpdateSanta(float dt)
        {
            if (!SantaActive)
            {
                if (Cfg.Santa) { santaNext -= dt; if (santaNext <= 0) { LaunchSanta(); santaNext = 60 + R() * 120; } }
                return;
            }
            SantaX += SantaDir * SantaSpeed * dt;
            SantaPhase += dt;
            sparkAcc += dt * 45;
            while (sparkAcc >= 1)
            {
                sparkAcc -= 1;
                var sp = new Spark();
                sp.X = SantaX - SantaDir * 90 * SantaScale + (R() - 0.5f) * 10 * SantaScale;
                sp.Y = SantaY + (R() - 0.3f) * 20 * SantaScale;
                sp.VX = -SantaDir * (10 + R() * 30) * SantaScale;
                sp.VY = (R() - 0.5f) * 20 * SantaScale;
                sp.Max = sp.Life = 0.8f + R() * 1.4f;
                sp.Size = (1.5f + R() * 3f) * SantaScale;
                sp.Gold = R() < 0.6f;
                Sparks.Add(sp);
            }
            if ((SantaDir > 0 && SantaX > santaMaxX + 450 * SantaScale) || (SantaDir < 0 && SantaX < santaMinX - 450 * SantaScale))
            {
                SantaActive = false;
                santaNext = 60 + R() * 120;
            }
        }

        void UpdateSparks(float dt)
        {
            for (int i = Sparks.Count - 1; i >= 0; i--)
            {
                var sp = Sparks[i];
                sp.Life -= dt;
                if (sp.Life <= 0) { Sparks.RemoveAt(i); continue; }
                sp.X += sp.VX * dt;
                sp.Y += sp.VY * dt;
                sp.VY += 12 * SantaScale * dt;
            }
        }

        // ------------------------------------------------------------------ effekter (bruges af julekalenderen)
        public void TriggerEffect(int effect)
        {
            switch (effect)
            {
                case 1: LaunchSanta(); break;
                case 2: StormUntil = Time + 25; break;
                case 3: NisseParty(); break;
                case 4: StarShower(); break;
                case 5: LaunchSanta(); StarShower(); NisseParty(); break;
            }
        }

        // Sends the snow plow across every screen right away (from the tray menu or --sneplov).
        public void SendPlow()
        {
            foreach (var l in layers) l.StartPlow();
        }

        // Schedules a plow run a number of seconds from now (used by the --sneplov=N test flag).
        public void SendPlowAfter(float seconds)
        {
            plowAt = Time + (seconds > 0 ? seconds : 0);   // also covers 0, negative and NaN
        }
        double plowAt = -1;

        void NisseParty()
        {
            foreach (var l in layers) l.NisseWave(6f);
        }

        void StarShower()
        {
            foreach (var l in layers)
            {
                var b = l.ScreenBounds;
                for (int i = 0; i < 90; i++)
                {
                    var sp = new Spark();
                    sp.X = b.X + R() * b.Width;
                    sp.Y = b.Y - R() * b.Height * 0.8f;
                    sp.VX = (R() - 0.5f) * 20 * l.S;
                    sp.VY = (140 + R() * 140) * l.S;
                    sp.Max = sp.Life = 5 + R() * 3;
                    sp.Size = (3 + R() * 4) * l.S;
                    sp.Gold = R() < 0.8f;
                    sp.Star = true;
                    Sparks.Add(sp);
                }
            }
        }

        void SnowmanCelebrate()
        {
            if (!Cfg.Snowman) return;
            foreach (var l in layers)
            {
                if (!l.IsPrimary || l.SnowmanPos.IsEmpty) continue;
                var p = l.SnowmanPos;
                float s = l.S;
                for (int i = 0; i < 70; i++)
                {
                    var sp = new Spark();
                    sp.X = p.X + (R() - 0.5f) * 90 * s;
                    sp.Y = p.Y - R() * 120 * s;
                    sp.VX = (R() - 0.5f) * 60 * s;
                    sp.VY = -(20 + R() * 60) * s;
                    sp.Max = sp.Life = 1.5f + R() * 1.5f;
                    sp.Size = (2 + R() * 3) * s;
                    sp.Gold = R() < 0.6f;
                    Sparks.Add(sp);
                }
            }
        }

        // ------------------------------------------------------------------ daglige begivenheder
        void UpdateDaily(bool startup)
        {
            var today = JuleClock.Today;
            lastDay = today;
            CalendarContent.SyncYear(Cfg, today);

            SnowmanStage = Math.Max(1, Math.Min(SnowmanMaxStage, (today - Cfg.FirstRun).Days + 1));

            string title = null, msg = null;
            balloonOpensCalendar = false;
            if (SnowmanStage > Cfg.SnowmanSeenStage)
            {
                if (Cfg.SnowmanSeenStage > 0 && Cfg.Snowman)
                {
                    title = "Snemanden vokser!";
                    msg = "Nisserne har bygget videre på snemanden. I dag fik den " + SnowmanSteps[SnowmanStage - 1];
                    celebrateAt = Time + 2;
                }
                Cfg.SnowmanSeenStage = SnowmanStage;
                Cfg.Save();
            }
            if (today.Month == 12 && today.Day <= 24 && !Cfg.OpenedDoors.Contains(today.Day) && Cfg.LastDoorNotice != today)
            {
                title = "Dagens låge er klar!";
                msg = "Låge " + today.Day + " i julekalenderen venter på dig. Klik her for at åbne kalenderen.";
                balloonOpensCalendar = true;
                Cfg.LastDoorNotice = today;
                Cfg.Save();
            }
            if (msg == null && startup)
            {
                title = "Jule-hygge er tændt";
                msg = "Højreklik på snefnug-ikonet ved uret for indstillinger og julekalender. Dobbeltklik for at kalde på julemanden!";
            }
            if (msg != null) tray.ShowBalloonTip(6000, title, msg, ToolTipIcon.None);
        }

        public void ShowCalendar()
        {
            if (calendar == null || calendar.IsDisposed) calendar = new CalendarForm(this);
            calendar.Show();
            if (calendar.WindowState == FormWindowState.Minimized) calendar.WindowState = FormWindowState.Normal;
            // kort TopMost-trick, så vinduet også kommer forrest når Windows nægter at give fokus
            calendar.TopMost = true;
            calendar.Activate();
            calendar.TopMost = false;
        }

        // ------------------------------------------------------------------ bakkeikon og menu
        void BuildTray()
        {
            tray = new NotifyIcon();
            tray.Icon = AppIcon;
            tray.Text = "Jule-hygge";
            tray.Visible = true;
            tray.DoubleClick += (s, e) => LaunchSanta();
            tray.BalloonTipClicked += (s, e) => { if (balloonOpensCalendar) ShowCalendar(); };

            var menu = new ContextMenuStrip();
            var cal = new ToolStripMenuItem("Julekalender...");
            cal.Font = new Font(cal.Font, FontStyle.Bold);
            cal.Click += (s, e) => ShowCalendar();
            menu.Items.Add(cal);
            countdownItem = new ToolStripMenuItem(Countdown());
            countdownItem.Enabled = false;
            menu.Items.Add(countdownItem);
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(Toggle("Snevejr", () => Cfg.Snow, v => Cfg.Snow = v));
            var level = new ToolStripMenuItem("Snemængde");
            string[] names = { "Let sne", "Normal", "Snestorm" };
            for (int i = 0; i < names.Length; i++)
            {
                int li = i;
                var it = new ToolStripMenuItem(names[i]);
                it.Checked = Cfg.SnowLevel == li;
                it.Click += (s, e) =>
                {
                    Cfg.SnowLevel = li;
                    foreach (ToolStripMenuItem o in level.DropDownItems) o.Checked = o == it;
                    Cfg.Save();
                };
                level.DropDownItems.Add(it);
            }
            menu.Items.Add(level);
            menu.Items.Add(Toggle("Sne på proceslinjen", () => Cfg.SnowGround, v => Cfg.SnowGround = v));
            snowmanItem = Toggle("Snemand", () => Cfg.Snowman, v => Cfg.Snowman = v);
            menu.Items.Add(snowmanItem);
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(Toggle("Julemanden", () => Cfg.Santa, v => Cfg.Santa = v));
            var send = new ToolStripMenuItem("Send julemanden afsted nu!");
            send.Click += (s, e) => LaunchSanta();
            menu.Items.Add(send);
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(Toggle("Sneplov rydder proceslinjen", () => Cfg.Plow, v => Cfg.Plow = v));
            var plow = new ToolStripMenuItem("Send sneploven ud nu!");
            plow.Click += (s, e) => SendPlow();
            menu.Items.Add(plow);
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(Toggle("Nisser", () => Cfg.Nisser, v => Cfg.Nisser = v));
            var count = new ToolStripMenuItem("Antal nisser pr. skærm");
            foreach (int c in new[] { 1, 2, 3, 5, 8, 12 })
            {
                int ci = c;
                var it = new ToolStripMenuItem(c.ToString());
                it.Checked = Cfg.NisseCount == ci;
                it.Click += (s, e) =>
                {
                    Cfg.NisseCount = ci;
                    foreach (ToolStripMenuItem o in count.DropDownItems) o.Checked = o == it;
                    Cfg.Save();
                };
                count.DropDownItems.Add(it);
            }
            menu.Items.Add(count);
            menu.Items.Add(new ToolStripSeparator());

            var power = new ToolStripMenuItem("Strømspare");
            string[] powerNames = { "Fra - fuld sne på hele skærmen", "Til - sne over proceslinjen, stille blæser", "Kun når den bærbare kører på batteri" };
            int[] powerValues = { 1, 2, 0 };
            foreach (int pv in powerValues)
            {
                int pvi = pv;
                var it = new ToolStripMenuItem(powerNames[pv]);
                it.Checked = Cfg.PowerSave == pvi;
                it.Click += (s, e) =>
                {
                    Cfg.PowerSave = pvi;
                    foreach (ToolStripMenuItem o in power.DropDownItems) o.Checked = o == it;
                    Cfg.Save();
                    UpdatePowerSave();
                };
                power.DropDownItems.Add(it);
            }
            menu.Items.Add(power);
            menu.Items.Add(Toggle("Julelys", () => Cfg.Lights, v => Cfg.Lights = v));
            menu.Items.Add(Toggle("Vis på alle skærme", () => Cfg.AllScreens, v => { Cfg.AllScreens = v; BuildLayers(); }));
            menu.Items.Add(Toggle("Pause ved fuldskærm (spil/film)", () => Cfg.PauseFullscreen, v => Cfg.PauseFullscreen = v));
            // The checkmark always mirrors the registry (re-read when the menu opens), and a failed
            // write (e.g. locked down by policy) just leaves the checkmark showing the real state.
            var autostart = new ToolStripMenuItem("Start med Windows");
            autostart.Checked = GetAutostart();
            autostart.CheckOnClick = true;
            autostart.CheckedChanged += (s, e) =>
            {
                if (syncingMenu) return;
                SetAutostart(autostart.Checked);
                syncingMenu = true;
                autostart.Checked = GetAutostart();
                syncingMenu = false;
            };
            menu.Items.Add(autostart);
            menu.Items.Add(new ToolStripSeparator());

            var exit = new ToolStripMenuItem("Afslut");
            exit.Click += (s, e) => Exit();
            menu.Items.Add(exit);

            menu.Opening += (s, e) =>
            {
                countdownItem.Text = Countdown();
                snowmanItem.Text = "Snemand (trin " + SnowmanStage + " af " + SnowmanMaxStage + ")";
                syncingMenu = true;
                autostart.Checked = GetAutostart();
                syncingMenu = false;
            };
            tray.ContextMenuStrip = menu;
        }

        ToolStripMenuItem Toggle(string text, Func<bool> get, Action<bool> set)
        {
            var item = new ToolStripMenuItem(text);
            item.Checked = get();
            item.CheckOnClick = true;
            item.CheckedChanged += (s, e) => { set(item.Checked); Cfg.Save(); };
            return item;
        }

        void Exit()
        {
            timer.Stop();
            SystemEvents.DisplaySettingsChanged -= OnDisplayChanged;
            if (calendar != null && !calendar.IsDisposed) calendar.Close();
            foreach (var l in layers) { l.Close(); l.Dispose(); }
            layers.Clear();
            tray.Visible = false;
            tray.Dispose();
            Cfg.Save();
            ExitThread();
        }

        static string Countdown()
        {
            var today = JuleClock.Today;
            var eve = new DateTime(today.Year, 12, 24);
            if (today > eve) eve = eve.AddYears(1);
            int d = (int)(eve - today).TotalDays;
            if (d == 0) return "★ Glædelig jul! ★";
            if (d == 1) return "★ 1 dag til juleaften ★";
            return "★ " + d + " dage til juleaften ★";
        }

        bool syncingMenu;

        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        static string AutostartCommand { get { return "\"" + Application.ExecutablePath + "\""; } }

        // True only if the Run entry points at this exe; an entry for a moved or old copy counts as off.
        static bool GetAutostart()
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(RunKey))
                    return k != null && string.Equals(k.GetValue("JuleHygge") as string, AutostartCommand, StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception ex) { ErrorLog.Write(ex); return false; }
        }

        static void SetAutostart(bool on)
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(RunKey, true))
                {
                    if (k == null) return;
                    if (on) k.SetValue("JuleHygge", AutostartCommand);
                    else k.DeleteValue("JuleHygge", false);
                }
            }
            catch (Exception ex) { ErrorLog.Write(ex); }
        }

        static Icon MakeIcon()
        {
            var bmp = new Bitmap(32, 32, PixelFormat.Format32bppArgb);
            using (var gg = Graphics.FromImage(bmp))
            {
                gg.SmoothingMode = SmoothingMode.AntiAlias;
                gg.Clear(Color.Transparent);
                using (var b = new SolidBrush(Color.FromArgb(200, 25, 35))) gg.FillEllipse(b, 1, 1, 30, 30);
                using (var p = new Pen(Color.White, 2.2f))
                {
                    p.StartCap = p.EndCap = LineCap.Round;
                    for (int k = 0; k < 3; k++)
                    {
                        double a = k * Math.PI / 3 + Math.PI / 2;
                        float dx = (float)Math.Cos(a) * 11, dy = (float)Math.Sin(a) * 11;
                        gg.DrawLine(p, 16 - dx, 16 - dy, 16 + dx, 16 + dy);
                        for (int sgn = -1; sgn <= 1; sgn += 2)
                        {
                            float ex = 16 + sgn * dx * 0.65f, ey = 16 + sgn * dy * 0.65f;
                            double a1 = a + (sgn > 0 ? 0 : Math.PI);
                            for (int side = -1; side <= 1; side += 2)
                            {
                                double ba = a1 + side * 2.4;
                                gg.DrawLine(p, ex, ey, ex + (float)Math.Cos(ba) * 4, ey + (float)Math.Sin(ba) * 4);
                            }
                        }
                    }
                }
            }
            return Icon.FromHandle(bmp.GetHicon());
        }
    }
}
