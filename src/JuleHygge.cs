// JuleHygge - et hyggeligt juleoverlay til Windows
// Snevejr, sne på proceslinjen, julemanden i kane, nisser og julelys.
// Bygges med build.ps1 (bruger den indbyggede .NET Framework C#-compiler).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace JuleHygge
{
    static class Program
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

        [STAThread]
        static void Main()
        {
            bool createdNew;
            using (var mutex = new System.Threading.Mutex(true, "JuleHygge_SingleInstance", out createdNew))
            {
                if (!createdNew) return;
                try { SetProcessDPIAware(); } catch { }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new Overlay());
            }
        }
    }

    // ------------------------------------------------------------------ indstillinger
    class Settings
    {
        public bool Snow = true, SnowGround = true, Santa = true, Nisser = true, Lights = true, PauseFullscreen = true;
        public int SnowLevel = 1;   // 0 = let, 1 = normal, 2 = snestorm
        public int NisseCount = 3;

        static string FilePath
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "JuleHygge", "settings.ini"); }
        }

        public static Settings Load()
        {
            var s = new Settings();
            try
            {
                if (!File.Exists(FilePath)) return s;
                foreach (var line in File.ReadAllLines(FilePath))
                {
                    int i = line.IndexOf('=');
                    if (i < 0) continue;
                    string k = line.Substring(0, i).Trim(), v = line.Substring(i + 1).Trim();
                    switch (k)
                    {
                        case "Snow": s.Snow = v == "1"; break;
                        case "SnowGround": s.SnowGround = v == "1"; break;
                        case "Santa": s.Santa = v == "1"; break;
                        case "Nisser": s.Nisser = v == "1"; break;
                        case "Lights": s.Lights = v == "1"; break;
                        case "PauseFullscreen": s.PauseFullscreen = v == "1"; break;
                        case "SnowLevel": int.TryParse(v, out s.SnowLevel); break;
                        case "NisseCount": int.TryParse(v, out s.NisseCount); break;
                    }
                }
            }
            catch { }
            s.SnowLevel = Math.Max(0, Math.Min(2, s.SnowLevel));
            s.NisseCount = Math.Max(1, Math.Min(12, s.NisseCount));
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
                    "SnowLevel=" + SnowLevel, "NisseCount=" + NisseCount });
            }
            catch { }
        }
        static string B(bool b) { return b ? "1" : "0"; }
    }

    // ------------------------------------------------------------------ objekter
    class Flake
    {
        public float X, Y, R, Vy, Phase, Sway, SwaySpd, Rot, RotSpd;
        public int A;
        public bool Crystal;
    }

    class Spark
    {
        public float X, Y, VX, VY, Life, Max, Size;
        public bool Gold;
    }

    class Nisse
    {
        public float X, Dir, Speed, WalkPhase, T, StateTimer, Size;
        public int State;          // 0 = går, 1 = står stille, 2 = vinker
        public bool CarriesGift;
        public Color Tunic, Mitten, Gift;
    }

    // ------------------------------------------------------------------ overlay-vinduet
    class Overlay : Form
    {
        #region Win32
        const int WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80,
                  WS_EX_NOACTIVATE = 0x8000000, WS_EX_TOPMOST = 0x8;

        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
        [StructLayout(LayoutKind.Sequential)] struct SIZE { public int CX, CY; public SIZE(int a, int b) { CX = a; CY = b; } }
        [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        struct BITMAPINFOHEADER
        {
            public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount;
            public uint biCompression, biSizeImage; public int biXPelsPerMeter, biYPelsPerMeter;
            public uint biClrUsed, biClrImportant;
        }

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pprSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
        [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr hSection, uint offset);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
        #endregion

        Settings cfg = Settings.Load();
        Random rnd = new Random();

        Rectangle bounds; int W, H; float groundY, S, dpiScale = 1f;
        IntPtr pixels;
        IntPtr memDc, hDib, hOldBmp; Bitmap canvas; Graphics g;

        Timer timer;
        Stopwatch clock = Stopwatch.StartNew();
        double lastT; float time;

        NotifyIcon tray;
        ToolStripMenuItem countdownItem;

        List<Flake> flakes = new List<Flake>();
        float[] heap; const int HeapStep = 4;
        float wind, windTarget, windTimer;

        bool santaActive; float santaX, santaY0, santaDir = 1, santaSpeed, santaNext = 5f, santaPhase, sparkAcc;
        List<Spark> sparks = new List<Spark>();
        List<Nisse> nisser = new List<Nisse>();

        bool paused, needClear; float fsCheckTimer, topmostTimer;

        // farver
        static readonly Color SantaRed = Color.FromArgb(205, 25, 35), Gold = Color.FromArgb(235, 195, 70),
            Skin = Color.FromArgb(255, 214, 186), Deer = Color.FromArgb(145, 95, 55), DeerDark = Color.FromArgb(100, 62, 32),
            HatRed = Color.FromArgb(210, 30, 40);
        SolidBrush[] flakeBrushes = new SolidBrush[16];
        Pen[] flakePens = new Pen[16];

        public Overlay()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            Text = "JuleHygge";
            for (int i = 0; i < 16; i++)
            {
                flakeBrushes[i] = new SolidBrush(Color.FromArgb(60 + i * 13, 255, 255, 255));
                flakePens[i] = new Pen(Color.FromArgb(60 + i * 13, 255, 255, 255), 1.2f);
            }
            InitSurface();
            BuildTray();
            SystemEvents.DisplaySettingsChanged += OnDisplayChanged;

            timer = new Timer();
            timer.Interval = 33;
            timer.Tick += Tick;
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
                return cp;
            }
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e) { }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            lastT = clock.Elapsed.TotalSeconds;
            timer.Start();
            tray.ShowBalloonTip(4000, "Jule-hygge er tændt",
                "Højreklik på snefnug-ikonet ved uret for indstillinger. Dobbeltklik for at kalde på julemanden!", ToolTipIcon.None);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            timer.Stop();
            SystemEvents.DisplaySettingsChanged -= OnDisplayChanged;
            tray.Visible = false;
            tray.Dispose();
            cfg.Save();
            FreeSurface();
            base.OnFormClosing(e);
        }

        void OnDisplayChanged(object sender, EventArgs e)
        {
            BeginInvoke(new Action(() => { InitSurface(); flakes.Clear(); }));
        }

        // ------------------------------------------------------------------ tegneflade
        void InitSurface()
        {
            FreeSurface();
            var scr = Screen.PrimaryScreen;
            bounds = scr.Bounds; W = bounds.Width; H = bounds.Height;
            groundY = scr.WorkingArea.Bottom - bounds.Top;
            S = Math.Max(0.6f, H / 1080f);
            using (var sg = Graphics.FromHwnd(IntPtr.Zero)) dpiScale = Math.Max(1f, sg.DpiX / 96f);

            var bih = new BITMAPINFOHEADER();
            bih.biSize = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
            bih.biWidth = W; bih.biHeight = -H; bih.biPlanes = 1; bih.biBitCount = 32;
            IntPtr screenDc = GetDC(IntPtr.Zero);
            memDc = CreateCompatibleDC(screenDc);
            IntPtr bits;
            hDib = CreateDIBSection(screenDc, ref bih, 0, out bits, IntPtr.Zero, 0);
            ReleaseDC(IntPtr.Zero, screenDc);
            hOldBmp = SelectObject(memDc, hDib);

            pixels = bits;
            canvas = new Bitmap(W, H, W * 4, PixelFormat.Format32bppPArgb, bits);
            g = Graphics.FromImage(canvas);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.CompositingQuality = CompositingQuality.HighSpeed;

            heap = new float[W / HeapStep + 2];
            Bounds = bounds;
        }

        void FreeSurface()
        {
            if (g != null) { g.Dispose(); g = null; }
            if (canvas != null) { canvas.Dispose(); canvas = null; }
            if (memDc != IntPtr.Zero)
            {
                SelectObject(memDc, hOldBmp);
                DeleteObject(hDib);
                DeleteDC(memDc);
                memDc = IntPtr.Zero;
            }
        }

        void Present()
        {
            g.Flush(FlushIntention.Sync);
            IntPtr screenDc = GetDC(IntPtr.Zero);
            var dst = new POINT(bounds.X, bounds.Y);
            var size = new SIZE(W, H);
            var src = new POINT(0, 0);
            var bf = new BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
            UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref bf, 2);
            ReleaseDC(IntPtr.Zero, screenDc);
        }

        // ------------------------------------------------------------------ hovedløkke
        void Tick(object sender, EventArgs e)
        {
            double now = clock.Elapsed.TotalSeconds;
            float dt = (float)Math.Min(0.1, now - lastT);
            lastT = now;

            topmostTimer -= dt;
            if (topmostTimer <= 0)
            {
                topmostTimer = 2f;
                SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10);
            }

            fsCheckTimer -= dt;
            if (fsCheckTimer <= 0)
            {
                fsCheckTimer = 1f;
                bool p = cfg.PauseFullscreen && IsFullscreenAppActive();
                if (p && !paused) needClear = true;
                paused = p;
            }
            if (paused)
            {
                if (needClear) { g.Clear(Color.Transparent); Present(); needClear = false; }
                return;
            }

            time += dt;
            UpdateSnow(dt);
            UpdateSanta(dt);
            UpdateNisser(dt);

            long t0 = clock.ElapsedTicks;
            ClearCanvas();
            long t1 = clock.ElapsedTicks;
            if (cfg.Lights) DrawLights();
            if (santaActive || sparks.Count > 0) DrawSanta();
            DrawGround();
            foreach (var n in nisser) DrawNisse(n);
            long t2 = clock.ElapsedTicks;
            DrawSnow();
            long t3 = clock.ElapsedTicks;
            Present();
            long t4 = clock.ElapsedTicks;
            if (Environment.GetEnvironmentVariable("JULE_PROFILE") == "1")
            {
                prof[0] += t1 - t0; prof[1] += t2 - t1; prof[2] += t3 - t2; prof[3] += t4 - t3; profFrames++;
                if (profFrames == 150)
                {
                    double f = 1000.0 / Stopwatch.Frequency / profFrames;
                    File.WriteAllText(Path.Combine(Path.GetTempPath(), "jule_profile.txt"),
                        string.Format("clear {0:F2}ms  scene {1:F2}ms  snow {2:F2}ms  present {3:F2}ms  flakes {4}",
                        prof[0] * f, prof[1] * f, prof[2] * f, prof[3] * f, flakes.Count));
                }
            }
        }
        long[] prof = new long[4]; int profFrames;

        bool IsFullscreenAppActive()
        {
            IntPtr fg = GetForegroundWindow();
            if (fg == IntPtr.Zero || fg == Handle) return false;
            var sb = new StringBuilder(256);
            GetClassName(fg, sb, 256);
            string c = sb.ToString();
            if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd") return false;
            RECT r;
            if (!GetWindowRect(fg, out r)) return false;
            return r.Left <= bounds.Left && r.Top <= bounds.Top && r.Right >= bounds.Right && r.Bottom >= bounds.Bottom;
        }

        float Rnd() { return (float)rnd.NextDouble(); }

        // ------------------------------------------------------------------ sne
        void UpdateSnow(float dt)
        {
            int[] baseCount = { 110, 260, 650 };
            // antal fnug efter "logisk" skærmstørrelse, så høj-DPI skærme ikke får 3x så mange
            float logicalArea = W * (float)H / (dpiScale * dpiScale);
            int target = cfg.Snow ? (int)(baseCount[cfg.SnowLevel] * Math.Min(2f, logicalArea / (1920f * 1080f))) : 0;
            while (flakes.Count < target) flakes.Add(NewFlake(flakes.Count < target / 2 && time < 1f));
            if (flakes.Count > target) flakes.RemoveRange(target, flakes.Count - target);

            windTimer -= dt;
            if (windTimer <= 0)
            {
                windTimer = 3 + Rnd() * 6;
                float range = cfg.SnowLevel == 2 ? 140 : 30;
                windTarget = (Rnd() * 2 - 1) * range * S + (cfg.SnowLevel == 2 ? 60 * S : 0);
            }
            wind += (windTarget - wind) * Math.Min(1f, dt * 0.5f);

            for (int i = 0; i < flakes.Count; i++)
            {
                var f = flakes[i];
                f.Y += f.Vy * dt;
                f.X += (wind * (0.4f + f.R / (4 * S)) + (float)Math.Cos(time * f.SwaySpd + f.Phase) * f.Sway) * dt;
                f.Rot += f.RotSpd * dt;
                if (f.X < -60) f.X += W + 120; else if (f.X > W + 60) f.X -= W + 120;
                if (f.Y >= groundY - HeapAt(f.X))
                {
                    if (cfg.SnowGround) Deposit(f.X, f.R);
                    flakes[i] = NewFlake(false);
                }
            }

            // sne på proceslinjen: udglatning og (evt.) smeltning
            float maxH = 18 * S, slope = 1.2f * S;
            for (int i = 0; i < heap.Length - 1; i++)
            {
                float d = heap[i] - heap[i + 1];
                if (d > slope) { float m = (d - slope) * 0.3f; heap[i] -= m; heap[i + 1] += m; }
                else if (d < -slope) { float m = (-d - slope) * 0.3f; heap[i] += m; heap[i + 1] -= m; }
            }
            bool melt = !cfg.Snow || !cfg.SnowGround;
            for (int i = 0; i < heap.Length; i++)
            {
                if (melt) heap[i] = Math.Max(0, heap[i] - 3 * S * dt);
                if (heap[i] > maxH) heap[i] = maxH;
            }
        }

        Flake NewFlake(bool anywhere)
        {
            var f = new Flake();
            float depth = Rnd();
            f.R = (1f + depth * depth * 3.5f) * S;
            f.Vy = (25f + depth * 55f + Rnd() * 15f) * S * (cfg.SnowLevel == 2 ? 1.5f : 1f);
            f.X = rnd.Next(-50, W + 50);
            f.Y = anywhere ? Rnd() * groundY : -10 - Rnd() * 60;
            f.Phase = Rnd() * 6.28f;
            f.Sway = (8 + Rnd() * 20) * S;
            f.SwaySpd = 0.5f + Rnd() * 1.2f;
            f.A = (int)(110 + depth * 145);
            f.Crystal = depth > 0.8f && Rnd() < 0.5f;
            if (f.Crystal) f.R *= 1.6f;
            f.Rot = Rnd() * 6.28f;
            f.RotSpd = (Rnd() - 0.5f) * 2f;
            return f;
        }

        void Deposit(float x, float r)
        {
            int idx = (int)(x / HeapStep);
            float amount = 0.35f * r / S * S;
            for (int k = -1; k <= 1; k++)
            {
                int j = idx + k;
                if (j >= 0 && j < heap.Length) heap[j] += k == 0 ? amount : amount * 0.5f;
            }
        }

        float HeapAt(float x)
        {
            float fx = x / HeapStep;
            int i = (int)Math.Floor(fx);
            if (i < 0) return heap[0];
            if (i >= heap.Length - 1) return heap[heap.Length - 1];
            float t = fx - i;
            return heap[i] * (1 - t) + heap[i + 1] * t;
        }

        [DllImport("msvcrt.dll", CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr memset(IntPtr dest, int c, UIntPtr count);

        void ClearCanvas()
        {
            g.Flush(FlushIntention.Sync);
            memset(pixels, 0, new UIntPtr((ulong)W * (ulong)H * 4));
        }

        // Tegner en blød, hvid prik direkte i den præmultiplicerede pixelbuffer (meget hurtigere end GDI+)
        unsafe void BlendDot(float cx, float cy, float r, int alpha)
        {
            int x0 = Math.Max(0, (int)(cx - r - 1)), x1 = Math.Min(W - 1, (int)(cx + r + 1));
            int y0 = Math.Max(0, (int)(cy - r - 1)), y1 = Math.Min(H - 1, (int)(cy + r + 1));
            if (x0 > x1 || y0 > y1) return;
            uint* buf = (uint*)pixels.ToPointer();
            for (int y = y0; y <= y1; y++)
            {
                float dy = y + 0.5f - cy;
                uint* row = buf + (long)y * W;
                for (int x = x0; x <= x1; x++)
                {
                    float dx = x + 0.5f - cx;
                    float cov = r + 0.5f - (float)Math.Sqrt(dx * dx + dy * dy);
                    if (cov <= 0) continue;
                    if (cov > 1) cov = 1;
                    int a = (int)(alpha * cov);
                    if (a <= 0) continue;
                    uint d = row[x];
                    int inv = 255 - a;
                    uint da = (uint)(a + (((d >> 24) & 0xFF) * inv) / 255);
                    uint dr = (uint)(a + (((d >> 16) & 0xFF) * inv) / 255);
                    uint dg = (uint)(a + (((d >> 8) & 0xFF) * inv) / 255);
                    uint db = (uint)(a + ((d & 0xFF) * inv) / 255);
                    row[x] = (da << 24) | (dr << 16) | (dg << 8) | db;
                }
            }
        }

        void DrawSnow()
        {
            g.Flush(FlushIntention.Sync);
            foreach (var f in flakes)
                if (!f.Crystal) BlendDot(f.X, f.Y, f.R, f.A);

            foreach (var f in flakes)
            {
                int bi = Math.Max(0, Math.Min(15, (f.A - 60) / 13));
                if (f.Crystal)
                {
                    var pen = flakePens[bi];
                    pen.Width = Math.Max(1f, 0.9f * S);
                    for (int k = 0; k < 3; k++)
                    {
                        float a = f.Rot + k * 1.0472f;
                        float dx = (float)Math.Cos(a) * f.R, dy = (float)Math.Sin(a) * f.R;
                        g.DrawLine(pen, f.X - dx, f.Y - dy, f.X + dx, f.Y + dy);
                    }
                }
            }
        }

        void DrawGround()
        {
            float max = 0;
            for (int i = 0; i < heap.Length; i++) if (heap[i] > max) max = heap[i];
            if (max < 0.5f) return;
            var pts = new PointF[heap.Length + 2];
            for (int i = 0; i < heap.Length; i++) pts[i] = new PointF(i * HeapStep, groundY - heap[i]);
            pts[heap.Length] = new PointF(W, groundY + 1);
            pts[heap.Length + 1] = new PointF(0, groundY + 1);
            using (var b = new SolidBrush(Color.FromArgb(245, 248, 252, 255))) g.FillPolygon(b, pts);
            using (var p = new Pen(Color.FromArgb(110, 170, 200, 230), 1.5f * S))
            {
                var top = new PointF[heap.Length];
                Array.Copy(pts, top, heap.Length);
                g.DrawLines(p, top);
            }
        }

        // ------------------------------------------------------------------ julemanden
        void LaunchSanta()
        {
            santaActive = true;
            santaDir = Rnd() < 0.5f ? 1 : -1;
            santaX = santaDir > 0 ? -420 * S : W + 420 * S;
            santaY0 = H * (0.12f + Rnd() * 0.25f);
            santaSpeed = (190 + Rnd() * 80) * S;
            santaPhase = 0;
        }

        float SantaY() { return santaY0 + (float)Math.Sin(santaPhase * 0.9) * 40 * S; }

        void UpdateSanta(float dt)
        {
            if (!santaActive)
            {
                if (cfg.Santa) { santaNext -= dt; if (santaNext <= 0) LaunchSanta(); }
            }
            else
            {
                santaX += santaDir * santaSpeed * dt;
                santaPhase += dt;
                sparkAcc += dt * 45;
                while (sparkAcc >= 1)
                {
                    sparkAcc -= 1;
                    var sp = new Spark();
                    sp.X = santaX - santaDir * 90 * S + (Rnd() - 0.5f) * 10 * S;
                    sp.Y = SantaY() + (Rnd() - 0.3f) * 20 * S;
                    sp.VX = -santaDir * (10 + Rnd() * 30) * S;
                    sp.VY = (Rnd() - 0.5f) * 20 * S;
                    sp.Max = sp.Life = 0.8f + Rnd() * 1.4f;
                    sp.Size = (1.5f + Rnd() * 3f) * S;
                    sp.Gold = Rnd() < 0.6f;
                    sparks.Add(sp);
                }
                if ((santaDir > 0 && santaX > W + 450 * S) || (santaDir < 0 && santaX < -450 * S))
                {
                    santaActive = false;
                    santaNext = 60 + Rnd() * 120;
                }
            }
            for (int i = sparks.Count - 1; i >= 0; i--)
            {
                var sp = sparks[i];
                sp.Life -= dt;
                if (sp.Life <= 0) { sparks.RemoveAt(i); continue; }
                sp.X += sp.VX * dt; sp.Y += sp.VY * dt; sp.VY += 12 * S * dt;
            }
        }

        void DrawSanta()
        {
            foreach (var sp in sparks)
            {
                int a = (int)(255 * sp.Life / sp.Max);
                Color c = sp.Gold ? Color.FromArgb(a, 255, 220, 120) : Color.FromArgb(a, 255, 255, 255);
                using (var b = new SolidBrush(c)) g.FillEllipse(b, sp.X - sp.Size / 2, sp.Y - sp.Size / 2, sp.Size, sp.Size);
                if (sp.Size > 3.5f * S)
                    using (var p = new Pen(c, 1f))
                    {
                        g.DrawLine(p, sp.X - sp.Size * 1.5f, sp.Y, sp.X + sp.Size * 1.5f, sp.Y);
                        g.DrawLine(p, sp.X, sp.Y - sp.Size * 1.5f, sp.X, sp.Y + sp.Size * 1.5f);
                    }
            }
            if (!santaActive) return;

            var st = g.Save();
            g.TranslateTransform(santaX, SantaY());
            g.ScaleTransform(santaDir * S * 1.1f, S * 1.1f);
            g.RotateTransform((float)Math.Cos(santaPhase * 0.9) * -4f * santaDir);
            float t = santaPhase;

            float[] rx = { 80, 140, 200, 260 };
            float[] ry = new float[4];
            for (int i = 0; i < 4; i++) ry[i] = -40 + (float)Math.Sin(t * 6 + i * 0.8) * 3;

            using (var rein = new Pen(Color.FromArgb(120, 60, 30), 1.4f))
                for (int i = 0; i < 4; i++) g.DrawLine(rein, -14, -44, rx[i] + 4, ry[i] - 6);
            for (int i = 0; i < 4; i++) DrawReindeer(rx[i], ry[i], i * 0.8f, i == 3, t);

            using (var red = new SolidBrush(SantaRed))
            using (var white = new SolidBrush(Color.White))
            using (var skin = new SolidBrush(Skin))
            using (var black = new SolidBrush(Color.FromArgb(30, 30, 30)))
            using (var sack = new SolidBrush(Color.FromArgb(150, 110, 60)))
            using (var gold = new SolidBrush(Gold))
            {
                // sæk med gaver
                g.FillEllipse(sack, -92, -66, 36, 40);
                using (var gb = new SolidBrush(Color.FromArgb(40, 140, 70))) g.FillRectangle(gb, -84, -74, 12, 12);
                using (var gb = new SolidBrush(Color.FromArgb(60, 100, 200))) g.FillRectangle(gb, -72, -70, 10, 9);
                g.FillRectangle(gold, -79, -74, 2, 12);

                // julemanden
                g.FillEllipse(red, -52, -58, 32, 42);
                using (var arm = new Pen(SantaRed, 7f)) { arm.StartCap = arm.EndCap = LineCap.Round; g.DrawLine(arm, -32, -48, -16, -44); }
                g.FillEllipse(black, -19, -48, 8, 8);
                g.FillEllipse(skin, -45, -76, 19, 19);
                g.FillEllipse(white, -42, -68, 18, 20);
                g.FillEllipse(white, -31, -70, 9, 5);
                using (var nose = new SolidBrush(Color.FromArgb(240, 150, 140))) g.FillEllipse(nose, -28, -71, 5, 5);
                g.FillEllipse(black, -32, -74, 2.6f, 2.6f);
                g.FillPolygon(red, new[] { new PointF(-47, -72), new PointF(-25, -74), new PointF(-40, -90), new PointF(-56, -86) });
                g.FillRectangle(white, -48, -76, 25, 5);
                g.FillEllipse(white, -61, -91, 9, 9);
            }

            // kanen
            using (var path = new GraphicsPath())
            {
                path.AddBezier(-82, -46, -70, -36, -78, -4, -60, 2);
                path.AddLine(-60, 2, 12, 2);
                path.AddBezier(12, 2, 26, 2, 30, -18, 40, -22);
                path.AddLine(40, -22, 34, -27);
                path.AddBezier(34, -27, 22, -16, 0, -21, -48, -23);
                path.AddLine(-48, -23, -72, -48);
                path.CloseFigure();
                using (var b = new LinearGradientBrush(new PointF(0, -46), new PointF(0, 4), Color.FromArgb(200, 30, 40), Color.FromArgb(120, 10, 20)))
                    g.FillPath(b, path);
                using (var p = new Pen(Gold, 2f)) g.DrawPath(p, path);
            }
            using (var p = new Pen(Gold, 3f))
            {
                p.StartCap = p.EndCap = LineCap.Round;
                g.DrawLine(p, -55, 2, -55, 12);
                g.DrawLine(p, 5, 2, 5, 12);
                g.DrawLine(p, -72, 12, 22, 12);
                g.DrawBezier(p, 22, 12, 36, 12, 38, -2, 28, -4);
                g.DrawBezier(p, -72, 12, -80, 12, -80, 4, -74, 4);
            }
            g.Restore(st);
        }

        void DrawReindeer(float x, float y, float phase, bool rudolph, float t)
        {
            float gal = t * 9 + phase;
            using (var legFar = new Pen(Color.FromArgb(85, 52, 28), 3.2f))
            using (var legNear = new Pen(DeerDark, 3.6f))
            {
                legFar.StartCap = legFar.EndCap = legNear.StartCap = legNear.EndCap = LineCap.Round;
                Leg(legFar, x + 9, y + 4, (float)Math.Sin(gal + 0.6) * 0.8f + 0.5f);
                Leg(legFar, x - 9, y + 4, (float)Math.Sin(gal + Math.PI + 0.6) * 0.8f - 0.4f);
                Leg(legNear, x + 14, y + 4, (float)Math.Sin(gal) * 0.8f + 0.5f);
                Leg(legNear, x - 14, y + 4, (float)Math.Sin(gal + Math.PI) * 0.8f - 0.4f);
            }
            using (var deer = new SolidBrush(Deer))
            using (var dark = new SolidBrush(DeerDark))
            using (var light = new SolidBrush(Color.FromArgb(200, 160, 110)))
            using (var white = new SolidBrush(Color.White))
            {
                g.FillEllipse(white, x - 27, y - 9, 8, 7);
                g.FillEllipse(deer, x - 22, y - 10, 44, 20);
                g.FillEllipse(light, x - 14, y - 1, 28, 8);
                g.FillPolygon(deer, new[] { new PointF(x + 10, y - 6), new PointF(x + 18, y - 25), new PointF(x + 26, y - 22), new PointF(x + 21, y + 2) });
                g.FillEllipse(deer, x + 16, y - 32, 16, 11);
                g.FillEllipse(deer, x + 26, y - 29, 11, 8);
                g.FillEllipse(dark, x + 14, y - 33, 7, 4);
                using (var eye = new SolidBrush(Color.Black)) g.FillEllipse(eye, x + 23, y - 30, 2.5f, 2.5f);
            }
            using (var ant = new Pen(Color.FromArgb(205, 175, 125), 2f))
            {
                ant.StartCap = ant.EndCap = LineCap.Round;
                g.DrawLine(ant, x + 20, y - 31, x + 16, y - 45);
                g.DrawLine(ant, x + 17, y - 41, x + 11, y - 45);
                g.DrawLine(ant, x + 16, y - 45, x + 20, y - 51);
                g.DrawLine(ant, x + 23, y - 31, x + 27, y - 45);
                g.DrawLine(ant, x + 26, y - 41, x + 32, y - 44);
            }
            using (var harness = new Pen(Color.FromArgb(190, 20, 30), 3f)) g.DrawLine(harness, x + 8, y - 9, x + 5, y + 9);
            using (var bell = new SolidBrush(Gold)) g.FillEllipse(bell, x + 3, y + 5, 4.5f, 4.5f);

            if (rudolph)
            {
                int a = (int)(90 + 70 * Math.Sin(t * 6));
                using (var glow = new SolidBrush(Color.FromArgb(a, 255, 60, 50))) g.FillEllipse(glow, x + 30, y - 33, 15, 15);
                using (var nose = new SolidBrush(Color.FromArgb(240, 30, 30))) g.FillEllipse(nose, x + 34, y - 29, 7, 7);
            }
            else using (var nose = new SolidBrush(Color.FromArgb(40, 25, 15))) g.FillEllipse(nose, x + 35, y - 27, 4, 4);
        }

        void Leg(Pen p, float hx, float hy, float a)
        {
            g.DrawLine(p, hx, hy, hx + (float)Math.Sin(a) * 15, hy + (float)Math.Cos(a) * 15);
        }

        // ------------------------------------------------------------------ nisser
        static readonly Color[] Tunics = {
            Color.FromArgb(115, 120, 130), Color.FromArgb(40, 105, 65), Color.FromArgb(150, 35, 45), Color.FromArgb(70, 85, 145) };
        static readonly Color[] Gifts = {
            Color.FromArgb(40, 140, 70), Color.FromArgb(60, 100, 200), Color.FromArgb(200, 40, 60), Color.FromArgb(150, 80, 180) };

        void UpdateNisser(float dt)
        {
            int target = cfg.Nisser ? cfg.NisseCount : 0;
            while (nisser.Count < target)
            {
                var n = new Nisse();
                n.X = 60 * S + Rnd() * (W - 120 * S);
                n.Dir = Rnd() < 0.5f ? -1 : 1;
                n.Speed = (22 + Rnd() * 18) * S;
                n.Size = 0.85f + Rnd() * 0.3f;
                n.Tunic = Tunics[rnd.Next(Tunics.Length)];
                n.Mitten = n.Tunic.R > 140 ? Color.FromArgb(40, 105, 65) : HatRed;
                n.CarriesGift = Rnd() < 0.4f;
                n.Gift = Gifts[rnd.Next(Gifts.Length)];
                n.StateTimer = 3 + Rnd() * 6;
                n.T = Rnd() * 10;
                nisser.Add(n);
            }
            if (nisser.Count > target) nisser.RemoveRange(target, nisser.Count - target);

            foreach (var n in nisser)
            {
                n.T += dt;
                n.StateTimer -= dt;
                if (n.State == 0)
                {
                    n.X += n.Dir * n.Speed * dt;
                    n.WalkPhase += dt * n.Speed / (4.5f * S);
                    if (n.X < 30 * S) { n.X = 30 * S; n.Dir = 1; }
                    if (n.X > W - 30 * S) { n.X = W - 30 * S; n.Dir = -1; }
                    if (n.StateTimer <= 0)
                    {
                        float r = Rnd();
                        if (r < 0.3f) { n.State = 1; n.StateTimer = 2 + Rnd() * 3; }
                        else if (r < 0.5f) { n.State = 2; n.StateTimer = 2.5f; }
                        else { if (r < 0.7f) n.Dir = -n.Dir; n.StateTimer = 4 + Rnd() * 8; }
                    }
                }
                else if (n.StateTimer <= 0)
                {
                    n.State = 0;
                    n.StateTimer = 4 + Rnd() * 8;
                    if (Rnd() < 0.4f) n.Dir = -n.Dir;
                }
            }
        }

        void DrawNisse(Nisse n)
        {
            var st = g.Save();
            g.TranslateTransform(n.X, groundY - HeapAt(n.X) + 2 * S);
            g.ScaleTransform(n.Dir * S * n.Size, S * n.Size);

            bool walking = n.State == 0;
            float p = n.WalkPhase;
            float legA = walking ? (float)Math.Sin(p) * 0.55f : 0f;
            float bob = walking ? -Math.Abs((float)Math.Sin(p)) * 1.5f : 0f;

            using (var shadow = new SolidBrush(Color.FromArgb(50, 60, 80, 110))) g.FillEllipse(shadow, -11, -2, 22, 4);

            using (var pants = new Pen(Color.FromArgb(80, 80, 92), 5f))
            using (var boot = new SolidBrush(Color.FromArgb(62, 40, 28)))
            {
                pants.StartCap = pants.EndCap = LineCap.Round;
                NisseLeg(pants, boot, -2, -15 + bob, legA);
                NisseLeg(pants, boot, 2, -15 + bob, -legA);
            }

            g.TranslateTransform(0, bob);
            float backArm, frontArm;
            if (n.State == 2) { backArm = -legA * 0.8f; frontArm = 2.5f + (float)Math.Sin(n.T * 11) * 0.45f; }
            else if (n.CarriesGift) { backArm = 1.3f; frontArm = 1.3f; }
            else { backArm = -legA * 0.9f; frontArm = legA * 0.9f; }

            using (var tunic = new SolidBrush(n.Tunic))
            using (var armPen = new Pen(n.Tunic, 4.2f))
            using (var mitten = new SolidBrush(n.Mitten))
            {
                armPen.StartCap = armPen.EndCap = LineCap.Round;
                NisseArm(armPen, mitten, -1, -29, backArm);
                g.FillEllipse(tunic, -10, -34, 20, 22);
                using (var belt = new SolidBrush(Color.FromArgb(35, 30, 30))) g.FillRectangle(belt, -9.5f, -20, 19, 3);
                using (var buckle = new SolidBrush(Gold)) g.FillRectangle(buckle, 2, -20.5f, 3.5f, 4);

                if (n.CarriesGift && n.State != 2)
                {
                    using (var gift = new SolidBrush(n.Gift)) g.FillRectangle(gift, 6, -31, 11, 10);
                    using (var rib = new Pen(Gold, 1.6f))
                    {
                        g.DrawLine(rib, 11.5f, -31, 11.5f, -21);
                        g.DrawLine(rib, 6, -26, 17, -26);
                        g.DrawEllipse(rib, 9, -34, 3, 3);
                        g.DrawEllipse(rib, 12, -34, 3, 3);
                    }
                }

                using (var skin = new SolidBrush(Skin)) g.FillEllipse(skin, -6, -44, 13, 12);
                using (var beard = new GraphicsPath())
                {
                    beard.AddBezier(-6, -39, -7, -30, -2, -22, 3, -20);
                    beard.AddBezier(3, -20, 7, -24, 9, -32, 7.5f, -39);
                    beard.CloseFigure();
                    using (var white = new SolidBrush(Color.FromArgb(250, 250, 250))) g.FillPath(white, beard);
                }
                NisseArm(armPen, mitten, 1, -29, frontArm);
                using (var nose = new SolidBrush(Color.FromArgb(240, 160, 150))) g.FillEllipse(nose, 4, -40, 5, 5);

                float sway = (float)Math.Sin(walking ? p * 0.5f : n.T * 1.5f) * 2.5f;
                float tipX = -14 + sway, tipY = -57;
                using (var hat = new GraphicsPath())
                {
                    hat.AddLine(-7.5f, -39, 8, -39);
                    hat.AddBezier(8, -39, 9, -54, 0, -62, tipX, tipY);
                    hat.AddBezier(tipX, tipY, -6, -57, -7, -49, -7.5f, -39);
                    hat.CloseFigure();
                    using (var hb = new SolidBrush(HatRed)) g.FillPath(hb, hat);
                }
                using (var brim = new Pen(Color.FromArgb(150, 15, 25), 2f)) g.DrawLine(brim, -7.5f, -39.5f, 8, -39.5f);
                using (var pom = new SolidBrush(Color.White)) g.FillEllipse(pom, tipX - 3, tipY - 3, 6, 6);
            }
            g.Restore(st);
        }

        void NisseLeg(Pen pants, Brush boot, float hx, float hy, float a)
        {
            float fx = hx + (float)Math.Sin(a) * 12, fy = hy + (float)Math.Cos(a) * 12;
            g.DrawLine(pants, hx, hy, fx, fy);
            g.FillEllipse(boot, fx - 3, fy - 2, 9, 5);
        }

        void NisseArm(Pen arm, Brush mitten, float sx, float sy, float a)
        {
            float hx = sx + (float)Math.Sin(a) * 10, hy = sy + (float)Math.Cos(a) * 10;
            g.DrawLine(arm, sx, sy, hx, hy);
            g.FillEllipse(mitten, hx - 2.5f, hy - 2.5f, 5, 5);
        }

        // ------------------------------------------------------------------ julelys
        static readonly Color[] BulbColors = {
            Color.FromArgb(255, 60, 60), Color.FromArgb(60, 220, 90), Color.FromArgb(255, 200, 60),
            Color.FromArgb(80, 150, 255), Color.FromArgb(255, 110, 200) };

        Bitmap lightsBmp; float lightsTimer;

        void DrawLights()
        {
            int lh = (int)(70 * S);
            if (lightsBmp == null || lightsBmp.Width != W || lightsBmp.Height != lh)
            {
                if (lightsBmp != null) lightsBmp.Dispose();
                lightsBmp = new Bitmap(W, lh, PixelFormat.Format32bppPArgb);
                lightsTimer = 0;
            }
            lightsTimer -= 0.033f;
            if (lightsTimer <= 0)
            {
                lightsTimer = 0.1f;
                var main = g;
                using (g = Graphics.FromImage(lightsBmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    RenderLights();
                }
                g = main;
            }
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImageUnscaled(lightsBmp, 0, 0);
            g.CompositingMode = CompositingMode.SourceOver;
        }

        void RenderLights()
        {
            float span = 230 * S, sag = 22 * S, top = 1;
            int perSpan = 4, idx = 0;
            using (var wire = new Pen(Color.FromArgb(220, 25, 60, 35), 2f * S))
            using (var socket = new SolidBrush(Color.FromArgb(255, 30, 70, 40)))
            {
                for (float x0 = -span * 0.3f; x0 < W; x0 += span)
                {
                    var pts = new PointF[13];
                    for (int k = 0; k <= 12; k++)
                    {
                        float u = k / 12f;
                        pts[k] = new PointF(x0 + u * span, top + sag * (1 - (2 * u - 1) * (2 * u - 1)));
                    }
                    g.DrawCurve(wire, pts);

                    for (int b = 0; b < perSpan; b++, idx++)
                    {
                        float u = (b + 0.5f) / perSpan;
                        float bx = x0 + u * span, by = top + sag * (1 - (2 * u - 1) * (2 * u - 1));
                        Color c = BulbColors[idx % BulbColors.Length];
                        float br = 0.55f + 0.45f * (float)Math.Sin(time * (1.3 + (idx * 37 % 10) * 0.12) + idx * 1.7);
                        float w = 7 * S, h = 11 * S;
                        using (var glow = new SolidBrush(Color.FromArgb((int)(70 * br), c)))
                            g.FillEllipse(glow, bx - 13 * S, by + 1 * S, 26 * S, 26 * S);
                        g.FillRectangle(socket, bx - 2.5f * S, by, 5 * S, 4 * S);
                        Color bc = Color.FromArgb(255,
                            (int)(c.R * (0.5f + 0.5f * br)), (int)(c.G * (0.5f + 0.5f * br)), (int)(c.B * (0.5f + 0.5f * br)));
                        using (var bulb = new SolidBrush(bc)) g.FillEllipse(bulb, bx - w / 2, by + 3 * S, w, h);
                        using (var shine = new SolidBrush(Color.FromArgb((int)(160 * br), 255, 255, 255)))
                            g.FillEllipse(shine, bx - w / 4, by + 5 * S, w / 3, h / 3);
                    }
                }
            }
        }

        // ------------------------------------------------------------------ bakkeikon og menu
        void BuildTray()
        {
            tray = new NotifyIcon();
            tray.Icon = MakeIcon();
            tray.Text = "Jule-hygge";
            tray.Visible = true;
            tray.DoubleClick += (s, e) => { if (!santaActive) LaunchSanta(); };

            var menu = new ContextMenuStrip();
            countdownItem = new ToolStripMenuItem(Countdown());
            countdownItem.Enabled = false;
            menu.Items.Add(countdownItem);
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(Toggle("Snevejr", () => cfg.Snow, v => cfg.Snow = v));
            var level = new ToolStripMenuItem("Snemængde");
            string[] names = { "Let sne", "Normal", "Snestorm" };
            for (int i = 0; i < names.Length; i++)
            {
                int li = i;
                var it = new ToolStripMenuItem(names[i]);
                it.Checked = cfg.SnowLevel == li;
                it.Click += (s, e) =>
                {
                    cfg.SnowLevel = li;
                    foreach (ToolStripMenuItem o in level.DropDownItems) o.Checked = o == it;
                    flakes.Clear();
                    cfg.Save();
                };
                level.DropDownItems.Add(it);
            }
            menu.Items.Add(level);
            menu.Items.Add(Toggle("Sne på proceslinjen", () => cfg.SnowGround, v => cfg.SnowGround = v));
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(Toggle("Julemanden", () => cfg.Santa, v => cfg.Santa = v));
            var send = new ToolStripMenuItem("Send julemanden afsted nu!");
            send.Click += (s, e) => { if (!santaActive) LaunchSanta(); };
            menu.Items.Add(send);
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(Toggle("Nisser", () => cfg.Nisser, v => cfg.Nisser = v));
            var count = new ToolStripMenuItem("Antal nisser");
            foreach (int c in new[] { 1, 2, 3, 5, 8, 12 })
            {
                int ci = c;
                var it = new ToolStripMenuItem(c.ToString());
                it.Checked = cfg.NisseCount == ci;
                it.Click += (s, e) =>
                {
                    cfg.NisseCount = ci;
                    foreach (ToolStripMenuItem o in count.DropDownItems) o.Checked = o == it;
                    cfg.Save();
                };
                count.DropDownItems.Add(it);
            }
            menu.Items.Add(count);
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(Toggle("Julelys", () => cfg.Lights, v => cfg.Lights = v));
            menu.Items.Add(Toggle("Pause ved fuldskærm (spil/film)", () => cfg.PauseFullscreen, v => cfg.PauseFullscreen = v));
            menu.Items.Add(Toggle("Start med Windows", GetAutostart, SetAutostart));
            menu.Items.Add(new ToolStripSeparator());

            var exit = new ToolStripMenuItem("Afslut");
            exit.Click += (s, e) => Close();
            menu.Items.Add(exit);

            menu.Opening += (s, e) => countdownItem.Text = Countdown();
            tray.ContextMenuStrip = menu;
        }

        ToolStripMenuItem Toggle(string text, Func<bool> get, Action<bool> set)
        {
            var item = new ToolStripMenuItem(text);
            item.Checked = get();
            item.CheckOnClick = true;
            item.CheckedChanged += (s, e) => { set(item.Checked); cfg.Save(); };
            return item;
        }

        static string Countdown()
        {
            var today = DateTime.Today;
            var eve = new DateTime(today.Year, 12, 24);
            if (today > eve) eve = eve.AddYears(1);
            int d = (int)(eve - today).TotalDays;
            if (d == 0) return "★ Glædelig jul! ★";
            if (d == 1) return "★ 1 dag til juleaften ★";
            return "★ " + d + " dage til juleaften ★";
        }

        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        static bool GetAutostart()
        {
            using (var k = Registry.CurrentUser.OpenSubKey(RunKey))
                return k != null && k.GetValue("JuleHygge") != null;
        }
        static void SetAutostart(bool on)
        {
            using (var k = Registry.CurrentUser.OpenSubKey(RunKey, true))
            {
                if (k == null) return;
                if (on) k.SetValue("JuleHygge", "\"" + Application.ExecutablePath + "\"");
                else k.DeleteValue("JuleHygge", false);
            }
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
