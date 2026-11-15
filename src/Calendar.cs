using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Windows.Forms;

namespace JuleHygge
{
    static class CalendarContent
    {
        // Effekter: 0 = ingen, 1 = julemanden, 2 = snestorm, 3 = nissefest, 4 = stjerneregn, 5 = det hele
        public static readonly string[] Texts = {
            /* 1 */ "Velkommen til december! Nisserne er klar og vinker til dig fra proceslinjen. Kan du se dem?",
            /* 2 */ "Hvad kalder man en snemand om sommeren? En vandpyt!",
            /* 3 */ "Hyggetip: Tænd et lys, lav en kop varm kakao og hold fem minutters pause. Arbejdet kan godt vente lidt.",
            /* 4 */ "Vidste du, at julemærket blev fundet på af den danske postmand Einar Holbøll? Det første kom i 1904.",
            /* 5 */ "Hvorfor er julemanden så god til karate? Fordi han har sort bælte!",
            /* 6 */ "Hyggetip: Send en julehilsen til én, du ikke har talt med længe. Det tager to minutter og gør dagen bedre for jer begge.",
            /* 7 */ "Vidste du, at det første kendte juletræ i Danmark blev tændt på Holsteinborg gods i 1808?",
            /* 8 */ "Vejrudsigten for i dag: Kraftigt snefald over skrivebordet. Find vanterne frem!",
            /* 9 */ "Hvad sagde den ene snemand til den anden? \"Kan du også lugte gulerødder?\"",
            /* 10 */ "Hyggetip: Gå en tur, når det bliver mørkt, og kig efter julelys i vinduerne.",
            /* 11 */ "I gamle dage boede nissen på gården. Fik han ikke sin risengrød juleaften, lavede han ballade. Nisserne her på skærmen er heldigvis nemmere at gøre glade.",
            /* 12 */ "Halvvejs til juleaften! Julemanden tager en ekstra prøvetur for at fejre det. Hold øje med himlen.",
            /* 13 */ "I dag er det Santa Lucia. Lyset fejres med optog og hvide kjoler. Her på skærmen fejrer vi det med et stjerneskud.",
            /* 14 */ "Hvad får man, hvis man krydser en snemand med en vampyr? Frostbid!",
            /* 15 */ "Hyggetip: Bag pebernødder. Dejen tager ti minutter, og hele huset kommer til at dufte af jul.",
            /* 16 */ "Vidste du, at Rudolf med den røde tud blev opfundet i 1939 til en lille julebog fra et amerikansk stormagasin?",
            /* 17 */ "Snestorm! Godt at du sidder indenfor i varmen.",
            /* 18 */ "Hvad siger man til en nisse, der er ked af det? Op med humøret, og op med huen!",
            /* 19 */ "Hyggetip: Sæt julemusik på og ryd op på skrivebordet. Både det rigtige og det her på skærmen.",
            /* 20 */ "Vidste du, at risalamande er dansk, selvom navnet lyder fransk? Det kommer af \"riz à l'amande\", som betyder ris med mandler.",
            /* 21 */ "Nisserne holder generalprøve på dansen om juletræet. Se dem lige vinke!",
            /* 22 */ "Hyggetip: Skriv en ønskeseddel, også selvom du er voksen. Julemanden flyver forbi lige om lidt og kan måske nå at tage den med.",
            /* 23 */ "Lillejuleaften! Husk at gemme en hel mandel til risalamanden. Den, der finder den, får mandelgaven.",
            /* 24 */ "Glædelig jul! I Danmark holder vi jul om aftenen den 24., mens mange andre lande først fejrer den den 25. om morgenen. Julemanden er på vej, så god jul og godt nytår!"
        };
        public static readonly int[] Effects = { 3, 0, 0, 4, 0, 0, 0, 2, 0, 0, 3, 1, 4, 0, 0, 0, 2, 0, 0, 4, 3, 1, 0, 5 };

        public static int CalendarYearFor(DateTime d) { return d.Month == 1 ? d.Year - 1 : d.Year; }

        // Højeste låge der må åbnes på datoen d (0 = ingen)
        public static int OpenableUpTo(DateTime d)
        {
            if (d.Month == 12) return Math.Min(24, d.Day);
            if (d.Month == 1) return 24;
            return 0;
        }

        public static void SyncYear(Settings s, DateTime d)
        {
            int y = CalendarYearFor(d);
            if (s.CalendarYear != y)
            {
                s.CalendarYear = y;
                s.OpenedDoors.Clear();
                s.Save();
            }
        }
    }

    class CalendarForm : Form
    {
        static readonly int[] Order = { 7, 15, 2, 22, 11, 18, 4, 20, 13, 1, 9, 24, 16, 6, 23, 10, 3, 19, 12, 21, 5, 17, 14, 8 };
        static readonly Color[] DoorFills = { Color.FromArgb(165, 28, 38), Color.FromArgb(238, 228, 204), Color.FromArgb(30, 105, 60) };
        static readonly Color GoldC = Color.FromArgb(240, 205, 110);

        readonly Controller c;
        readonly float k;
        readonly RectangleF[] doors = new RectangleF[25];
        readonly float[] openAnim = new float[25];
        readonly Timer anim;
        float pulse;
        int selected;
        string message;

        public CalendarForm(Controller controller)
        {
            c = controller;
            using (var gr = CreateGraphics()) k = gr.DpiX / 96f;
            Text = "Julekalender " + CalendarContent.CalendarYearFor(JuleClock.Today);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Icon = c.AppIcon;
            DoubleBuffered = true;
            BackColor = Color.FromArgb(15, 45, 30);
            ClientSize = new Size((int)(820 * k), (int)(720 * k));

            float size = 110 * k, gap = 15 * k;
            float left = (ClientSize.Width - (6 * size + 5 * gap)) / 2, top = 95 * k;
            for (int i = 0; i < 24; i++)
                doors[Order[i]] = new RectangleF(left + (i % 6) * (size + gap), top + (i / 6) * (size + gap), size, size);
            for (int d = 1; d <= 24; d++) if (c.Cfg.OpenedDoors.Contains(d)) openAnim[d] = 1;

            message = InitialMessage();

            anim = new Timer();
            anim.Interval = 40;
            anim.Tick += (s, e) => AnimTick();
            anim.Start();
        }

        // Fonts are created once instead of on every paint.
        readonly Font titleFont = new Font("Georgia", 24, FontStyle.Bold);
        readonly Font messageFont = new Font("Segoe UI", 12);
        readonly Font cornerFont = new Font("Georgia", 9, FontStyle.Bold);
        readonly Font numberFont = new Font("Georgia", 26, FontStyle.Bold);

        // Repaints only doors that are actually moving: an opening door, or an openable door whose gold
        // border pulses. Nothing is repainted while the window is minimized or when all is still.
        void AnimTick()
        {
            if (WindowState == FormWindowState.Minimized) return;
            pulse += 0.04f;
            // The pulse is slow, so its doors are repainted every other tick (12.5 fps) to save CPU.
            bool pulseFrame = (++tickCount & 1) == 0;
            int upTo = CalendarContent.OpenableUpTo(JuleClock.Today);
            for (int d = 1; d <= 24; d++)
            {
                if (openAnim[d] > 0 && openAnim[d] < 1)
                {
                    openAnim[d] = Math.Min(1, openAnim[d] + 0.07f);
                    InvalidateDoor(d);
                }
                else if (pulseFrame && d <= upTo && !c.Cfg.OpenedDoors.Contains(d)) InvalidateDoor(d);
            }
        }
        int tickCount;

        void InvalidateDoor(int d)
        {
            var r = doors[d];
            r.Inflate(8 * k, 8 * k);
            Invalidate(Rectangle.Round(r));
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            anim.Stop();
            anim.Dispose();
            titleFont.Dispose();
            messageFont.Dispose();
            cornerFont.Dispose();
            numberFont.Dispose();
            if (background != null) background.Dispose();
            base.OnFormClosed(e);
        }

        string InitialMessage()
        {
            var today = JuleClock.Today;
            if (CalendarContent.OpenableUpTo(today) == 0)
            {
                int n = (new DateTime(today.Year, 12, 1) - today).Days;
                return "Julekalenderen åbner den 1. december, om " + n + (n == 1 ? " dag" : " dage") + ". Indtil da må du nøjes med nisserne!";
            }
            if (today.Month == 12 && today.Day <= 24 && !c.Cfg.OpenedDoors.Contains(today.Day))
                return "Dagens låge er nummer " + today.Day + ". Kan du finde den?";
            return "Klik på en åben låge for at læse den igen.";
        }

        int HitTest(Point p)
        {
            for (int d = 1; d <= 24; d++) if (doors[d].Contains(p)) return d;
            return 0;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            Cursor = HitTest(e.Location) > 0 ? Cursors.Hand : Cursors.Default;
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            base.OnMouseClick(e);
            int d = HitTest(e.Location);
            if (d > 0) ClickDoor(d);
        }

        void ClickDoor(int d)
        {
            var today = JuleClock.Today;
            CalendarContent.SyncYear(c.Cfg, today);
            int upTo = CalendarContent.OpenableUpTo(today);
            if (d <= upTo)
            {
                if (!c.Cfg.OpenedDoors.Contains(d))
                {
                    c.Cfg.OpenedDoors.Add(d);
                    c.Cfg.Save();
                    openAnim[d] = 0.01f;
                }
                selected = d;
                message = "Låge " + d + ":  " + CalendarContent.Texts[d - 1];
                c.TriggerEffect(CalendarContent.Effects[d - 1]);
            }
            else
            {
                selected = 0;
                if (today.Month == 12)
                {
                    int n = d - today.Day;
                    message = "Tålmodighed! Låge " + d + " kan åbnes om " + n + (n == 1 ? " dag." : " dage.");
                }
                else message = "Låge " + d + " åbner den " + d + ". december.";
            }
            Invalidate();
        }

        // ------------------------------------------------------------------ tegning
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            var cr = ClientRectangle;
            var clip = e.ClipRectangle;

            // The static background (gradient, snow dots, title) is rendered once and then just copied.
            if (background == null || background.Size != cr.Size)
            {
                if (background != null) background.Dispose();
                background = new Bitmap(cr.Width, cr.Height, PixelFormat.Format32bppPArgb);
                using (var bgG = Graphics.FromImage(background)) RenderBackground(bgG, cr);
            }
            g.DrawImage(background, clip, clip, GraphicsUnit.Pixel);

            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

            // Only doors inside the repainted area are drawn (the animation repaints single doors).
            var today = JuleClock.Today;
            int upTo = CalendarContent.OpenableUpTo(today);
            for (int d = 1; d <= 24; d++)
                if (Rectangle.Round(RectangleF.Inflate(doors[d], 8 * k, 8 * k)).IntersectsWith(clip)) DrawDoor(g, d, upTo);

            var mr = new RectangleF(40 * k, 605 * k, cr.Width - 80 * k, 95 * k);
            if (!Rectangle.Round(mr).IntersectsWith(clip)) return;
            using (var p = Rounded(mr, 12 * k))
            using (var b = new SolidBrush(Color.FromArgb(45, 255, 255, 255)))
                g.FillPath(b, p);
            using (var b = new SolidBrush(Color.White))
            using (var sf = new StringFormat { LineAlignment = StringAlignment.Center })
                g.DrawString(message, messageFont, b, RectangleF.Inflate(mr, -18 * k, -8 * k), sf);
        }

        Bitmap background;

        void RenderBackground(Graphics g, Rectangle cr)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            using (var bg = new LinearGradientBrush(cr, Color.FromArgb(24, 72, 46), Color.FromArgb(8, 28, 18), 90f)) g.FillRectangle(bg, cr);
            var r = new Random(7);
            using (var sb = new SolidBrush(Color.FromArgb(55, 255, 255, 255)))
                for (int i = 0; i < 90; i++)
                {
                    float rad = (1 + (float)r.NextDouble() * 2.5f) * k;
                    g.FillEllipse(sb, (float)r.NextDouble() * cr.Width, (float)r.NextDouble() * cr.Height, rad * 2, rad * 2);
                }
            using (var b = new SolidBrush(GoldC))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                g.DrawString(Text, titleFont, b, new RectangleF(0, 15 * k, cr.Width, 70 * k), sf);
        }

        void DrawDoor(Graphics g, int d, int upTo)
        {
            var rc = doors[d];
            bool opened = c.Cfg.OpenedDoors.Contains(d);
            Color fill = DoorFills[d % 3];
            Color numCol = d % 3 == 1 ? Color.FromArgb(165, 28, 38) : Color.White;
            float rad = 10 * k;

            if (opened)
            {
                using (var p = Rounded(rc, rad))
                using (var b = new LinearGradientBrush(rc, Color.FromArgb(70, 40, 28), Color.FromArgb(35, 20, 14), 90f))
                    g.FillPath(b, p);
                var inner = RectangleF.Inflate(rc, -rc.Width * 0.2f, -rc.Height * 0.2f);
                DrawIcon(g, d, inner);
                using (var b = new SolidBrush(Color.FromArgb(200, 180, 140)))
                    g.DrawString(d.ToString(), cornerFont, b, rc.X + 6 * k, rc.Y + 4 * k);

                float a = openAnim[d];
                if (a < 1)
                {
                    // lågen svinger op omkring venstre hængsel
                    var dr = new RectangleF(rc.X, rc.Y, rc.Width * (1 - a), rc.Height);
                    if (dr.Width > 2)
                        using (var p = Rounded(dr, Math.Min(rad, dr.Width / 2)))
                        using (var b = new SolidBrush(Shade(fill, 1 - a * 0.5f)))
                            g.FillPath(b, p);
                }
                else
                {
                    using (var hinge = new SolidBrush(Shade(fill, 0.6f)))
                        g.FillRectangle(hinge, rc.X - 4 * k, rc.Y + 6 * k, 5 * k, rc.Height - 12 * k);
                }
            }
            else
            {
                using (var p = Rounded(rc, rad))
                {
                    using (var b = new LinearGradientBrush(rc, Shade(fill, 1.1f), Shade(fill, 0.85f), 60f)) g.FillPath(b, p);
                    using (var pen = new Pen(Color.FromArgb(80, 255, 255, 255), 1.2f * k)) g.DrawPath(pen, p);
                }
                using (var inner = Rounded(RectangleF.Inflate(rc, -7 * k, -7 * k), rad * 0.6f))
                using (var pen = new Pen(Color.FromArgb(70, 0, 0, 0), 1f * k) { DashStyle = DashStyle.Dash })
                    g.DrawPath(pen, inner);
                using (var b = new SolidBrush(numCol))
                using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString(d.ToString(), numberFont, b, rc, sf);

                if (d <= upTo)
                {
                    int al = (int)(150 + 100 * Math.Sin(pulse * 3));
                    using (var p = Rounded(RectangleF.Inflate(rc, 2 * k, 2 * k), rad + 2 * k))
                    using (var pen = new Pen(Color.FromArgb(al, GoldC), 3.5f * k))
                        g.DrawPath(pen, p);
                }
            }
            if (selected == d)
                using (var p = Rounded(RectangleF.Inflate(rc, 3 * k, 3 * k), rad + 3 * k))
                using (var pen = new Pen(Color.White, 2.5f * k))
                    g.DrawPath(pen, p);
        }

        static Color Shade(Color c, float f)
        {
            return Color.FromArgb(c.A, Math.Min(255, (int)(c.R * f)), Math.Min(255, (int)(c.G * f)), Math.Min(255, (int)(c.B * f)));
        }

        static GraphicsPath Rounded(RectangleF r, float rad)
        {
            var p = new GraphicsPath();
            float d = Math.Max(0.1f, rad * 2);
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        static PointF[] Star(float cx, float cy, float R, float r)
        {
            var p = new PointF[10];
            for (int i = 0; i < 10; i++)
            {
                double a = -Math.PI / 2 + i * Math.PI / 5;
                float rr = i % 2 == 0 ? R : r;
                p[i] = new PointF(cx + (float)Math.Cos(a) * rr, cy + (float)Math.Sin(a) * rr);
            }
            return p;
        }

        // Lille tegning bag hver åbnet låge
        void DrawIcon(Graphics g, int d, RectangleF r)
        {
            float cx = r.X + r.Width / 2, cy = r.Y + r.Height / 2, w = r.Width, h = r.Height;
            using (var glow = new SolidBrush(Color.FromArgb(40, 255, 220, 140))) g.FillEllipse(glow, RectangleF.Inflate(r, w * 0.15f, h * 0.15f));
            using (var gold = new SolidBrush(GoldC))
            using (var red = new SolidBrush(Color.FromArgb(205, 35, 45)))
            using (var green = new SolidBrush(Color.FromArgb(40, 140, 70)))
            using (var white = new SolidBrush(Color.FromArgb(245, 240, 230)))
            {
                switch (d % 6)
                {
                    case 0: // stjerne
                        g.FillPolygon(gold, Star(cx, cy, w * 0.48f, w * 0.2f));
                        break;
                    case 1: // juletræ
                        for (int i = 0; i < 3; i++)
                        {
                            float ty = cy - h * 0.38f + i * h * 0.2f, tw = w * (0.38f + i * 0.14f);
                            g.FillPolygon(green, new[] { new PointF(cx, ty), new PointF(cx + tw / 2, ty + h * 0.3f), new PointF(cx - tw / 2, ty + h * 0.3f) });
                        }
                        using (var trunk = new SolidBrush(Color.FromArgb(110, 70, 35))) g.FillRectangle(trunk, cx - w * 0.06f, cy + h * 0.32f, w * 0.12f, h * 0.14f);
                        g.FillPolygon(gold, Star(cx, cy - h * 0.42f, w * 0.12f, w * 0.05f));
                        g.FillEllipse(red, cx - w * 0.15f, cy - h * 0.02f, w * 0.08f, w * 0.08f);
                        g.FillEllipse(gold, cx + w * 0.08f, cy + h * 0.15f, w * 0.08f, w * 0.08f);
                        break;
                    case 2: // gave
                        g.FillRectangle(red, cx - w * 0.38f, cy - h * 0.15f, w * 0.76f, h * 0.55f);
                        g.FillRectangle(Brushes.Firebrick, cx - w * 0.42f, cy - h * 0.27f, w * 0.84f, h * 0.14f);
                        g.FillRectangle(gold, cx - w * 0.06f, cy - h * 0.27f, w * 0.12f, h * 0.67f);
                        g.FillEllipse(gold, cx - w * 0.28f, cy - h * 0.45f, w * 0.26f, h * 0.2f);
                        g.FillEllipse(gold, cx + w * 0.02f, cy - h * 0.45f, w * 0.26f, h * 0.2f);
                        break;
                    case 3: // hjerte
                        using (var p = new GraphicsPath())
                        {
                            p.AddBezier(cx, cy + h * 0.38f, cx - w * 0.65f, cy - h * 0.05f, cx - w * 0.35f, cy - h * 0.5f, cx, cy - h * 0.18f);
                            p.AddBezier(cx, cy - h * 0.18f, cx + w * 0.35f, cy - h * 0.5f, cx + w * 0.65f, cy - h * 0.05f, cx, cy + h * 0.38f);
                            g.FillPath(red, p);
                        }
                        break;
                    case 4: // lys
                        using (var flameGlow = new SolidBrush(Color.FromArgb(70, 255, 200, 80)))
                            g.FillEllipse(flameGlow, cx - w * 0.22f, cy - h * 0.55f, w * 0.44f, h * 0.44f);
                        g.FillRectangle(white, cx - w * 0.13f, cy - h * 0.15f, w * 0.26f, h * 0.6f);
                        g.FillRectangle(red, cx - w * 0.13f, cy + h * 0.1f, w * 0.26f, h * 0.06f);
                        g.FillEllipse(gold, cx - w * 0.07f, cy - h * 0.42f, w * 0.14f, h * 0.24f);
                        break;
                    case 5: // klokke
                        using (var p = new GraphicsPath())
                        {
                            p.AddBezier(cx - w * 0.38f, cy + h * 0.25f, cx - w * 0.3f, cy - h * 0.05f, cx - w * 0.28f, cy - h * 0.4f, cx, cy - h * 0.4f);
                            p.AddBezier(cx, cy - h * 0.4f, cx + w * 0.28f, cy - h * 0.4f, cx + w * 0.3f, cy - h * 0.05f, cx + w * 0.38f, cy + h * 0.25f);
                            p.CloseFigure();
                            g.FillPath(gold, p);
                        }
                        g.FillEllipse(gold, cx - w * 0.08f, cy + h * 0.2f, w * 0.16f, w * 0.16f);
                        g.FillEllipse(red, cx - w * 0.2f, cy - h * 0.52f, w * 0.18f, h * 0.14f);
                        g.FillEllipse(red, cx + w * 0.02f, cy - h * 0.52f, w * 0.18f, h * 0.14f);
                        break;
                }
            }
        }
    }
}
