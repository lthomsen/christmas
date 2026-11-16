using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace JuleHygge
{
    // Synthesized sound effects (the project has no sound files): Santa's sleigh bells with the
    // "Jingle Bells" chorus (James Lord Pierpont, 1857, public domain), and the snow plow's engine,
    // scraping and horn. Ported from macos/Sources/JuleHygge/Sound.swift.
    //
    // Playback uses the waveOut API that ships with Windows. Mixing runs on a background thread that only
    // exists while something is audible, so sound costs nothing the rest of the time.
    sealed class AudioHub
    {
        public const int SampleRate = 44100;
        const int BufferFrames = 2048;   // ~46 ms per buffer
        const int BufferCount = 4;       // ~186 ms queued, so a busy UI thread never causes gaps

        internal readonly object Gate = new object();
        readonly List<Voice> voices = new List<Voice>();
        Thread thread;
        volatile bool stopRequested;
        bool running;
        double quietSince = -1;

        public Voice CreateVoice(Func<float[]> make, bool loops)
        {
            var v = new Voice(this, make, loops);
            lock (Gate) voices.Add(v);
            return v;
        }

        internal void EnsureRunning()
        {
            if (running) return;
            stopRequested = false;
            running = true;
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Name = "JuleHygge audio";
            thread.Priority = ThreadPriority.AboveNormal;
            thread.Start();
        }

        // Called once per frame on the UI thread: stops the audio thread after a second of silence.
        public void IdleCheck(double now)
        {
            if (!running) return;
            bool any = false;
            lock (Gate) foreach (var v in voices) if (v.Playing) { any = true; break; }
            if (any) { quietSince = -1; return; }
            if (quietSince < 0) quietSince = now;
            if (now - quietSince > 1) StopAll();
        }

        public void StopAll()
        {
            lock (Gate) foreach (var v in voices) v.Halt();
            if (running)
            {
                stopRequested = true;
                if (thread != null) thread.Join(1000);
                thread = null;
                running = false;
            }
            quietSince = -1;
        }

        // ------------------------------------------------------------------ waveOut playback thread
        [StructLayout(LayoutKind.Sequential)]
        struct WAVEFORMATEX { public ushort wFormatTag, nChannels; public uint nSamplesPerSec, nAvgBytesPerSec; public ushort nBlockAlign, wBitsPerSample, cbSize; }
        [StructLayout(LayoutKind.Sequential)]
        struct WAVEHDR { public IntPtr lpData; public uint dwBufferLength, dwBytesRecorded; public IntPtr dwUser; public uint dwFlags, dwLoops; public IntPtr lpNext, reserved; }

        [DllImport("winmm.dll")] static extern int waveOutOpen(out IntPtr hwo, uint deviceId, ref WAVEFORMATEX fmt, IntPtr callback, IntPtr instance, uint flags);
        [DllImport("winmm.dll")] static extern int waveOutPrepareHeader(IntPtr hwo, IntPtr hdr, int size);
        [DllImport("winmm.dll")] static extern int waveOutUnprepareHeader(IntPtr hwo, IntPtr hdr, int size);
        [DllImport("winmm.dll")] static extern int waveOutWrite(IntPtr hwo, IntPtr hdr, int size);
        [DllImport("winmm.dll")] static extern int waveOutReset(IntPtr hwo);
        [DllImport("winmm.dll")] static extern int waveOutClose(IntPtr hwo);
        const uint WAVE_MAPPER = 0xFFFFFFFF, CALLBACK_EVENT = 0x50000;
        const int WHDR_DONE = 1;

        void Run()
        {
            IntPtr hwo = IntPtr.Zero;
            var done = new AutoResetEvent(false);
            var hdrs = new IntPtr[BufferCount];
            var data = new IntPtr[BufferCount];
            int hdrSize = Marshal.SizeOf(typeof(WAVEHDR));
            int flagsOffset = (int)Marshal.OffsetOf(typeof(WAVEHDR), "dwFlags");
            var mix = new short[BufferFrames * 2];
            var acc = new float[BufferFrames * 2];
            try
            {
                var fmt = new WAVEFORMATEX();
                fmt.wFormatTag = 1; fmt.nChannels = 2; fmt.nSamplesPerSec = SampleRate; fmt.wBitsPerSample = 16;
                fmt.nBlockAlign = 4; fmt.nAvgBytesPerSec = SampleRate * 4;
                int r = waveOutOpen(out hwo, WAVE_MAPPER, ref fmt, done.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, CALLBACK_EVENT);
                if (r != 0) { hwo = IntPtr.Zero; ErrorLog.Write(new InvalidOperationException("waveOutOpen failed: " + r)); return; }
                ErrorLog.Debug("audio started");

                for (int i = 0; i < BufferCount; i++)
                {
                    data[i] = Marshal.AllocHGlobal(mix.Length * 2);
                    hdrs[i] = Marshal.AllocHGlobal(hdrSize);
                    var h = new WAVEHDR();
                    h.lpData = data[i];
                    h.dwBufferLength = (uint)(mix.Length * 2);
                    Marshal.StructureToPtr(h, hdrs[i], false);
                    waveOutPrepareHeader(hwo, hdrs[i], hdrSize);
                    Fill(acc, mix, data[i]);
                    waveOutWrite(hwo, hdrs[i], hdrSize);
                }
                while (!stopRequested)
                {
                    done.WaitOne(50);
                    for (int i = 0; i < BufferCount && !stopRequested; i++)
                    {
                        if ((Marshal.ReadInt32(hdrs[i], flagsOffset) & WHDR_DONE) == 0) continue;
                        Fill(acc, mix, data[i]);
                        waveOutWrite(hwo, hdrs[i], hdrSize);
                    }
                }
            }
            catch (Exception ex) { ErrorLog.Write(ex); }
            finally
            {
                if (hwo != IntPtr.Zero)
                {
                    waveOutReset(hwo);
                    for (int i = 0; i < BufferCount; i++) if (hdrs[i] != IntPtr.Zero) waveOutUnprepareHeader(hwo, hdrs[i], hdrSize);
                    waveOutClose(hwo);
                }
                for (int i = 0; i < BufferCount; i++)
                {
                    if (hdrs[i] != IntPtr.Zero) Marshal.FreeHGlobal(hdrs[i]);
                    if (data[i] != IntPtr.Zero) Marshal.FreeHGlobal(data[i]);
                }
                done.Dispose();
                ErrorLog.Debug("audio stopped");
            }
        }

        // Mixes all playing voices into one stereo 16-bit buffer.
        void Fill(float[] acc, short[] mix, IntPtr dest)
        {
            Array.Clear(acc, 0, acc.Length);
            lock (Gate) foreach (var v in voices) v.MixInto(acc, BufferFrames);
            for (int i = 0; i < acc.Length; i++)
            {
                float s = acc[i];
                if (s > 1) s = 1; else if (s < -1) s = -1;
                mix[i] = (short)(s * 32000);
            }
            Marshal.Copy(mix, 0, dest, mix.Length);
        }
    }

    // One sound: a looping buffer whose volume and pan follow something on screen, or a one-shot.
    sealed class Voice
    {
        readonly AudioHub hub;
        readonly Func<float[]> make;
        readonly bool loops;
        volatile float[] samples;
        int generating;
        int pos;
        float gain, pan, appliedGain, appliedPan;

        public bool Playing { get; private set; }

        internal Voice(AudioHub hub, Func<float[]> make, bool loops) { this.hub = hub; this.make = make; this.loops = loops; }

        // The sound is synthesized in the background the first time it is needed (it takes up to a second).
        public void Warm() { Prepare(); }

        bool Prepare()
        {
            if (samples != null) return true;
            if (Interlocked.Exchange(ref generating, 1) == 0)
                ThreadPool.QueueUserWorkItem(_ =>
                {
                    try { samples = make(); }
                    catch (Exception ex) { ErrorLog.Write(ex); }
                });
            return false;
        }

        // Looping voice: fades smoothly (about half a second) toward level (0..1) and pans to pan (-1..1).
        public void Update(float level, float newPan, float dt)
        {
            if (level > 0 && !Playing)
            {
                if (!Prepare()) return;
                lock (hub.Gate) { pos = 0; gain = 0; appliedGain = 0; pan = Clamp(newPan); appliedPan = pan; Playing = true; }
                hub.EnsureRunning();
            }
            if (!Playing) return;
            lock (hub.Gate)
            {
                gain += (level - gain) * Math.Min(1f, dt * 4);
                pan = Clamp(newPan);
            }
            if (level == 0 && gain < 0.003f) Halt();
        }

        // Plays the whole buffer once.
        public void PlayOnce(float level, float newPan)
        {
            if (!Prepare()) return;
            lock (hub.Gate) { pos = 0; gain = level; appliedGain = level; pan = Clamp(newPan); appliedPan = pan; Playing = true; }
            hub.EnsureRunning();
        }

        internal void Halt()
        {
            lock (hub.Gate) { Playing = false; gain = 0; appliedGain = 0; }
        }

        static float Clamp(float p) { return Math.Max(-1f, Math.Min(1f, p)); }

        // Audio thread, under hub.Gate: adds this voice to the stereo mix, ramping gain and pan across the
        // buffer so volume changes never click. Equal-power panning.
        internal void MixInto(float[] acc, int frames)
        {
            var s = samples;
            if (!Playing || s == null || s.Length == 0) return;
            float g0 = appliedGain, g1 = gain, p0 = appliedPan, p1 = pan;
            for (int i = 0; i < frames; i++)
            {
                float t = (float)i / frames;
                float g = g0 + (g1 - g0) * t;
                double a = ((p0 + (p1 - p0) * t) + 1) * Math.PI / 4;
                float v = s[pos] * g;
                acc[2 * i] += v * (float)Math.Cos(a);
                acc[2 * i + 1] += v * (float)Math.Sin(a);
                if (++pos >= s.Length)
                {
                    if (loops) pos = 0;
                    else { Playing = false; break; }
                }
            }
            appliedGain = g1;
            appliedPan = p1;
        }
    }

    static class Synth
    {
        const double Rate = AudioHub.SampleRate;

        static float[] MakeBuffer(double seconds, Action<float[], int> fill)
        {
            int n = (int)(seconds * Rate);
            var output = new float[n];
            fill(output, n);
            Normalize(output);
            return output;
        }

        static void Normalize(float[] output)
        {
            float peak = 0;
            foreach (var x in output) peak = Math.Max(peak, Math.Abs(x));
            if (peak > 0.9f) { float k = 0.9f / peak; for (int i = 0; i < output.Length; i++) output[i] *= k; }
        }

        static double Noise(Random rng) { return rng.NextDouble() * 2 - 1; }

        // Diesel idle-ish rumble. Every frequency is a whole number of cycles per loop, so the loop is seamless.
        public static float[] PlowEngine()
        {
            return MakeBuffer(2.0, (output, n) =>
            {
                var rng = new Random(42);
                double lp = 0;
                double[][] harmonics = { new[] { 48.0, 1.0 }, new[] { 96.0, 0.5 }, new[] { 144.0, 0.3 }, new[] { 192.0, 0.18 }, new[] { 240.0, 0.1 } };
                for (int i = 0; i < n; i++)
                {
                    double t = i / Rate;
                    // firing pulses at 24 Hz shape a 48 Hz fundamental with harmonics
                    double firing = 0.6 + 0.4 * Math.Pow(Math.Max(0, Math.Sin(2 * Math.PI * 24 * t)), 3);
                    double v = 0;
                    foreach (var h in harmonics) v += h[1] * Math.Sin(2 * Math.PI * h[0] * t + h[0]);
                    lp += (Noise(rng) - lp) * 0.05;   // a little rattle: low-passed noise
                    v = v * firing + lp * 0.6;
                    output[i] = (float)(v * 0.2);
                }
            });
        }

        // Scraping snow: band-limited noise with a slow grainy texture.
        public static float[] PlowScrape()
        {
            return MakeBuffer(2.0, (output, n) =>
            {
                var rng = new Random(7);
                double lp = 0, hp = 0, prev = 0;
                for (int i = 0; i < n; i++)
                {
                    double t = i / Rate;
                    lp += (Noise(rng) - lp) * 0.35;    // tame the hiss
                    hp = 0.97 * (hp + lp - prev);      // remove the rumble
                    prev = lp;
                    double grain = 0.7 + 0.3 * Math.Sin(2 * Math.PI * 7 * t) * Math.Sin(2 * Math.PI * 3 * t);
                    output[i] = (float)(hp * grain * 0.5);
                }
                int fade = (int)(0.02 * Rate);
                for (int i = 0; i < fade; i++) { float k = (float)i / fade; output[i] *= k; output[n - 1 - i] *= k; }
            });
        }

        // Two-tone truck horn: "baa-baaa".
        public static float[] PlowHorn()
        {
            return MakeBuffer(1.0, (output, n) =>
            {
                Action<double, double> honk = (t0, len) =>
                {
                    int start = (int)(t0 * Rate), count = (int)(len * Rate);
                    for (int k = 0; k < count && start + k < n; k++)
                    {
                        double t = k / Rate;
                        double env = Math.Min(1, t / 0.02) * Math.Min(1, (len - t) / 0.05);
                        double v = 0;
                        foreach (double f in new[] { 311.0, 370.0 })      // a slightly sour third, like a real truck horn
                            for (int h = 1; h <= 5; h++) v += Math.Sin(2 * Math.PI * f * h * t) / h;
                        output[start + k] += (float)(v * env * 0.12);
                    }
                };
                honk(0, 0.22);
                honk(0.32, 0.5);
            });
        }

        // One loop: the chorus played on a music-box/celesta-like tone over shaken sleigh bells.
        public static float[] Jingle()
        {
            const double beat = 0.36;   // seconds per quarter note (~167 bpm)
            const int E5 = 76, F5 = 77, G5 = 79, C5 = 72, D5 = 74;
            // (MIDI note, length in beats); 0 = rest
            double[,] melody = {
                {E5,1},{E5,1},{E5,2}, {E5,1},{E5,1},{E5,2}, {E5,1},{G5,1},{C5,1.5},{D5,0.5}, {E5,4},
                {F5,1},{F5,1},{F5,1.5},{F5,0.5}, {F5,1},{E5,1},{E5,1},{E5,0.5},{E5,0.5}, {E5,1},{D5,1},{D5,1},{E5,1}, {D5,2},{G5,2},
                {E5,1},{E5,1},{E5,2}, {E5,1},{E5,1},{E5,2}, {E5,1},{G5,1},{C5,1.5},{D5,0.5}, {E5,4},
                {F5,1},{F5,1},{F5,1.5},{F5,0.5}, {F5,1},{E5,1},{E5,1},{E5,0.5},{E5,0.5}, {G5,1},{G5,1},{F5,1},{D5,1}, {C5,3},{0,1} };
            // simple bass on the beat: root notes, two octaves lower
            int[] bassPerBar = { C5, C5, C5, C5, F5, C5, D5, G5, C5, C5, C5, C5, F5, C5, G5, C5 };

            double totalBeats = 0;
            for (int i = 0; i < melody.GetLength(0); i++) totalBeats += melody[i, 1];
            int n = (int)(totalBeats * beat * Rate);
            var output = new float[n];
            Func<int, double> freq = midi => 440 * Math.Pow(2, (midi - 69) / 12.0);

            // Celesta-like note: a few slightly inharmonic partials with a bright attack and a ringing decay.
            double[][] partials = { new[] { 1, 1.0, 2.2 }, new[] { 2.0, 0.35, 4 }, new[] { 3.01, 0.12, 7 }, new[] { 4.17, 0.06, 10 } };
            Action<double, int, double, double> addBell = (t0, midi, len, amp) =>
            {
                double f = freq(midi);
                double dur = Math.Min(len + 0.6, 2.5);
                int start = (int)(t0 * Rate), count = (int)(dur * Rate);
                for (int k = 0; k < count && start + k < n; k++)
                {
                    double t = k / Rate;
                    double v = 0;
                    foreach (var p in partials) v += p[1] * Math.Exp(-t * p[2]) * Math.Sin(2 * Math.PI * f * p[0] * t);
                    output[start + k] += (float)(v * amp * Math.Min(1, t / 0.004));
                }
            };
            // Soft round bass note.
            Action<double, int, double> addBass = (t0, midi, len) =>
            {
                double f = freq(midi);
                int start = (int)(t0 * Rate), count = (int)(len * Rate);
                for (int k = 0; k < count && start + k < n; k++)
                {
                    double t = k / Rate;
                    double env = Math.Min(1, t / 0.01) * Math.Exp(-t * 3);
                    output[start + k] += (float)(0.16 * env * (Math.Sin(2 * Math.PI * f * t) + 0.3 * Math.Sin(4 * Math.PI * f * t)));
                }
            };
            // One sleigh bell: a short, bright cluster of inharmonic partials plus a little noise.
            var rng = new Random(1857);
            double[] bellPartials = { 1, 1.47, 2.09, 2.56, 3.18 };
            Action<double, double> addJingle = (t0, amp) =>
            {
                double b = 2300 + rng.NextDouble() * 500;
                int start = (int)(t0 * Rate), count = (int)(0.09 * Rate);
                for (int k = 0; k < count; k++)
                {
                    int idx = start + k;
                    if (idx >= n || idx < 0) break;
                    double t = k / Rate;
                    double v = 0;
                    for (int j = 0; j < bellPartials.Length; j++) v += Math.Sin(2 * Math.PI * b * bellPartials[j] * t + j) / (j + 2);
                    v += Noise(rng) * 0.35 * Math.Exp(-t * 120);
                    output[idx] += (float)(v * Math.Exp(-t * 55) * amp);
                }
            };

            double time = 0;
            for (int i = 0; i < melody.GetLength(0); i++)
            {
                int note = (int)melody[i, 0];
                if (note > 0) addBell(time, note, melody[i, 1] * beat, 0.22);
                time += melody[i, 1] * beat;
            }
            int bars = (int)(totalBeats / 4);
            for (int b = 0; b < bars; b++)
            {
                int root = bassPerBar[b % bassPerBar.Length] - 24;
                addBass(b * 4 * beat, root, beat * 1.8);
                addBass((b * 4 + 2) * beat, root + 7, beat * 1.8);
            }
            // sleigh bells: a shake on every eighth note, accented on the beat, each shake a few bells
            for (int e = 0; e * 0.5 < totalBeats; e++)
            {
                double tb = e * 0.5 * beat;
                double accent = e % 2 == 0 ? 1.0 : 0.6;
                for (int j = 0; j < 4; j++) addJingle(tb + j * 0.012 + rng.NextDouble() * 0.006, 0.05 * accent);
            }

            Normalize(output);   // gentle limiter so overlapping notes never clip
            int fade = (int)(0.01 * Rate);
            for (int i = 0; i < fade; i++) { float k = (float)i / fade; output[i] *= k; output[n - 1 - i] *= k; }
            return output;
        }

        // --lyd-test=DIR: writes each sound as a 16-bit mono WAV file plus a summary, so they can be listened to.
        public static void WriteTestFiles(string dir)
        {
            Directory.CreateDirectory(dir);
            var summary = new List<string>();
            var sounds = new Dictionary<string, Func<float[]>> {
                { "julemand-jingle", Jingle }, { "sneplov-motor", PlowEngine }, { "sneplov-skraben", PlowScrape }, { "sneplov-horn", PlowHorn } };
            foreach (var kv in sounds)
            {
                var s = kv.Value();
                using (var w = new BinaryWriter(File.Create(Path.Combine(dir, kv.Key + ".wav"))))
                {
                    w.Write(new[] { 'R', 'I', 'F', 'F' }); w.Write(36 + s.Length * 2); w.Write(new[] { 'W', 'A', 'V', 'E' });
                    w.Write(new[] { 'f', 'm', 't', ' ' }); w.Write(16); w.Write((short)1); w.Write((short)1);
                    w.Write(AudioHub.SampleRate); w.Write(AudioHub.SampleRate * 2); w.Write((short)2); w.Write((short)16);
                    w.Write(new[] { 'd', 'a', 't', 'a' }); w.Write(s.Length * 2);
                    foreach (var x in s) w.Write((short)(Math.Max(-1f, Math.Min(1f, x)) * 32000));
                }
                double peak = 0, sum = 0;
                foreach (var x in s) { peak = Math.Max(peak, Math.Abs(x)); sum += x * x; }
                summary.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0}: {1:F1} s  peak {2:F2}  rms {3:F3}",
                    kv.Key, s.Length / Rate, peak, Math.Sqrt(sum / s.Length)));
            }
            File.WriteAllLines(Path.Combine(dir, "summary.txt"), summary);
        }
    }
}
