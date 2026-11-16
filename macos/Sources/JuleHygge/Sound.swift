import AVFoundation

/// Synthesized sound effects (the project has no sound files): Santa's sleigh bells with the
/// "Jingle Bells" chorus (James Lord Pierpont, 1857, public domain), and the snow plow's engine, scraping
/// and horn. One audio engine is shared and only runs while something is audible, so it costs nothing
/// the rest of the time.
final class AudioHub {
    private let engine = AVAudioEngine()
    private var voices: [Voice] = []
    private var running = false
    private var quietSince: CFTimeInterval = 0

    func voice(_ make: @escaping () -> AVAudioPCMBuffer?, loops: Bool) -> Voice {
        let v = Voice(hub: self, make: make, loops: loops)
        engine.attach(v.player)
        voices.append(v)
        return v
    }

    fileprivate func ensureRunning(for v: Voice) -> Bool {
        guard let buf = v.buffer else { return false }
        if !v.connected { engine.connect(v.player, to: engine.mainMixerNode, format: buf.format); v.connected = true }
        if !running {
            do { try engine.start() } catch { ErrorLog.write("sound: \(error)"); return false }
            running = true
        }
        return true
    }

    /// Called once per frame after the voices were updated: stops the engine when everything is quiet.
    func idleCheck() {
        guard running else { return }
        if voices.contains(where: { $0.playing }) { quietSince = 0; return }
        let now = CACurrentMediaTime()
        if quietSince == 0 { quietSince = now }
        if now - quietSince > 1 { stopAll() }
    }

    func stopAll() {
        for v in voices { v.halt() }
        if running { engine.stop(); running = false }
        quietSince = 0
    }
}

/// One sound: a looping buffer whose volume and pan follow something on screen, or a one-shot.
final class Voice {
    fileprivate let player = AVAudioPlayerNode()
    private unowned let hub: AudioHub
    private let make: () -> AVAudioPCMBuffer?
    private let loops: Bool
    fileprivate var buffer: AVAudioPCMBuffer?
    fileprivate var connected = false
    private(set) var playing = false
    private var gain: Float = 0

    fileprivate init(hub: AudioHub, make: @escaping () -> AVAudioPCMBuffer?, loops: Bool) {
        self.hub = hub; self.make = make; self.loops = loops
    }

    private func prepare() -> Bool {
        if buffer == nil { buffer = make() }
        return hub.ensureRunning(for: self)
    }

    /// Looping voice: fades smoothly (about half a second) toward `level` (0…1) and pans to `pan` (−1…1).
    func update(level: Float, pan: Float, dt: Float) {
        if level > 0 && !playing {
            guard prepare(), let buffer else { return }
            gain = 0
            player.volume = 0
            player.scheduleBuffer(buffer, at: nil, options: loops ? .loops : [])
            player.play()
            playing = true
        }
        guard playing else { return }
        gain += (level - gain) * min(1, dt * 4)
        player.volume = gain
        player.pan = max(-1, min(1, pan))
        if level == 0 && gain < 0.003 { halt() }
    }

    /// Plays the whole buffer once.
    func playOnce(level: Float, pan: Float) {
        guard prepare(), let buffer else { return }
        player.stop()
        player.volume = level
        player.pan = max(-1, min(1, pan))
        playing = true
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async { self?.playing = false }
        }
        player.play()
    }

    fileprivate func halt() {
        if playing { player.stop() }
        playing = false
        gain = 0
    }
}

enum Synth {
    static let sampleRate = 44_100.0

    static func makeBuffer(seconds: Double, _ fill: (UnsafeMutablePointer<Float>, Int) -> Void) -> AVAudioPCMBuffer? {
        let n = Int(seconds * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        for i in 0..<n { out[i] = 0 }
        fill(out, n)
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(out[i])) }
        if peak > 0.9 { let k = 0.9 / peak; for i in 0..<n { out[i] *= k } }
        return buf
    }

    /// Diesel idle-ish rumble. Every frequency is a whole number of cycles per loop, so the loop is seamless.
    static func plowEngine() -> AVAudioPCMBuffer? {
        let len = 2.0
        return makeBuffer(seconds: len) { out, n in
            var rng = SeededRandom(seed: 42)
            var lp = 0.0
            for i in 0..<n {
                let t = Double(i) / sampleRate
                // firing pulses at 24 Hz shape a 48 Hz fundamental with harmonics
                let firing = 0.6 + 0.4 * pow(max(0, sin(2 * .pi * 24 * t)), 3)
                var v = 0.0
                for (h, a) in [(48.0, 1.0), (96.0, 0.5), (144.0, 0.3), (192.0, 0.18), (240.0, 0.1)] { v += a * sin(2 * .pi * h * t + h) }
                // a little rattle: low-passed noise
                lp += (Double(rng.next()) * 2 - 1 - lp) * 0.05
                v = v * firing + lp * 0.6
                out[i] = Float(v * 0.2)
            }
        }
    }

    /// Scraping snow: band-limited noise with a slow grainy texture.
    static func plowScrape() -> AVAudioPCMBuffer? {
        return makeBuffer(seconds: 2.0) { out, n in
            var rng = SeededRandom(seed: 7)
            var lp = 0.0, hp = 0.0, prev = 0.0
            for i in 0..<n {
                let t = Double(i) / sampleRate
                let white = Double(rng.next()) * 2 - 1
                lp += (white - lp) * 0.35          // tame the hiss
                hp = 0.97 * (hp + lp - prev)       // remove the rumble
                prev = lp
                let grain = 0.7 + 0.3 * sin(2 * .pi * 7 * t) * sin(2 * .pi * 3 * t)
                out[i] = Float(hp * grain * 0.5)
            }
            let fade = Int(0.02 * sampleRate)
            for i in 0..<fade { let k = Float(i) / Float(fade); out[i] *= k; out[n - 1 - i] *= k }
        }
    }

    /// Two-tone truck horn: "baa-baaa".
    static func plowHorn() -> AVAudioPCMBuffer? {
        return makeBuffer(seconds: 1.0) { out, n in
            func honk(_ t0: Double, _ len: Double) {
                let start = Int(t0 * sampleRate), count = Int(len * sampleRate)
                for k in 0..<count where start + k < n {
                    let t = Double(k) / sampleRate
                    let env = min(1, t / 0.02) * min(1, (len - t) / 0.05)
                    var v = 0.0
                    for f in [311.0, 370.0] {        // a slightly sour third, like a real truck horn
                        for h in 1...5 { v += sin(2 * .pi * f * Double(h) * t) / Double(h) }
                    }
                    out[start + k] += Float(v * env * 0.12)
                }
            }
            honk(0, 0.22)
            honk(0.32, 0.5)
        }
    }

    // ------------------------------------------------------------------ synthesis

    /// Renders one loop: the chorus played on a music-box/celesta-like tone over shaken sleigh bells.
    static func jingle() -> AVAudioPCMBuffer? {
        let sampleRate = Synth.sampleRate
        let beat = 0.36                      // seconds per quarter note (~167 bpm)
        // (MIDI note, length in beats); 0 = rest
        let E5 = 76, F5 = 77, G5 = 79, C5 = 72, D5 = 74, A4 = 69, B4 = 71
        let melody: [(Int, Double)] = [
            (E5, 1), (E5, 1), (E5, 2),
            (E5, 1), (E5, 1), (E5, 2),
            (E5, 1), (G5, 1), (C5, 1.5), (D5, 0.5),
            (E5, 4),
            (F5, 1), (F5, 1), (F5, 1.5), (F5, 0.5),
            (F5, 1), (E5, 1), (E5, 1), (E5, 0.5), (E5, 0.5),
            (E5, 1), (D5, 1), (D5, 1), (E5, 1),
            (D5, 2), (G5, 2),
            (E5, 1), (E5, 1), (E5, 2),
            (E5, 1), (E5, 1), (E5, 2),
            (E5, 1), (G5, 1), (C5, 1.5), (D5, 0.5),
            (E5, 4),
            (F5, 1), (F5, 1), (F5, 1.5), (F5, 0.5),
            (F5, 1), (E5, 1), (E5, 1), (E5, 0.5), (E5, 0.5),
            (G5, 1), (G5, 1), (F5, 1), (D5, 1),
            (C5, 3), (0, 1),
        ]
        // simple bass on the beat: root notes, an octave and a half lower
        let bassPerBar: [Int] = [C5, C5, C5, C5, F5, C5, D5, G5, C5, C5, C5, C5, F5, C5, G5, C5].map { $0 - 24 }
        _ = (A4, B4)

        let totalBeats = melody.reduce(0) { $0 + $1.1 }
        let seconds = totalBeats * beat
        let n = Int(seconds * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        for i in 0..<n { out[i] = 0 }

        func freq(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

        /// Celesta-like note: a few slightly inharmonic partials with a bright attack and a ringing decay.
        func addBell(_ t0: Double, _ midi: Int, _ len: Double, _ amp: Double) {
            let f = freq(midi)
            let partials: [(Double, Double, Double)] = [(1, 1.0, 2.2), (2.0, 0.35, 4), (3.01, 0.12, 7), (4.17, 0.06, 10)]
            let dur = min(len + 0.6, 2.5)
            let start = Int(t0 * sampleRate), count = Int(dur * sampleRate)
            for k in 0..<count {
                let idx = start + k
                if idx >= n { break }
                let t = Double(k) / sampleRate
                let attack = min(1, t / 0.004)
                var v = 0.0
                for (mul, a, decay) in partials { v += a * exp(-t * decay) * sin(2 * .pi * f * mul * t) }
                out[idx] += Float(v * amp * attack)
            }
        }

        /// Soft round bass note.
        func addBass(_ t0: Double, _ midi: Int, _ len: Double) {
            let f = freq(midi)
            let start = Int(t0 * sampleRate), count = Int(len * sampleRate)
            for k in 0..<count {
                let idx = start + k
                if idx >= n { break }
                let t = Double(k) / sampleRate
                let env = min(1, t / 0.01) * exp(-t * 3)
                out[idx] += Float(0.16 * env * (sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t)))
            }
        }

        /// One sleigh bell: a short, bright cluster of inharmonic partials plus a little noise.
        var rng = SeededRandom(seed: 1857)
        func addJingle(_ t0: Double, _ amp: Double) {
            let base = 2300 + Double(rng.next()) * 500
            let partials: [Double] = [1, 1.47, 2.09, 2.56, 3.18]
            let start = Int(t0 * sampleRate), count = Int(0.09 * sampleRate)
            for k in 0..<count {
                let idx = start + k
                if idx >= n || idx < 0 { break }
                let t = Double(k) / sampleRate
                let env = exp(-t * 55)
                var v = 0.0
                for (j, p) in partials.enumerated() { v += sin(2 * .pi * base * p * t + Double(j)) / Double(j + 2) }
                v += (Double(rng.next()) * 2 - 1) * 0.35 * exp(-t * 120)
                out[idx] += Float(v * env * amp)
            }
        }

        // melody
        var t = 0.0
        for (note, len) in melody {
            if note > 0 { addBell(t, note, len * beat, 0.22) }
            t += len * beat
        }
        // bass: one note per bar (4 beats), on beats 1 and 3
        let bars = Int(totalBeats / 4)
        for b in 0..<bars {
            let root = bassPerBar[b % bassPerBar.count]
            addBass(Double(b * 4) * beat, root, beat * 1.8)
            addBass(Double(b * 4 + 2) * beat, root + 7, beat * 1.8)
        }
        // sleigh bells: a shake on every eighth note, accented on the beat, each shake a few bells
        var e = 0
        while Double(e) * 0.5 < totalBeats {
            let tb = Double(e) * 0.5 * beat
            let accent = e % 2 == 0 ? 1.0 : 0.6
            for j in 0..<4 { addJingle(tb + Double(j) * 0.012 + Double(rng.next()) * 0.006, 0.05 * accent) }
            e += 1
        }

        // gentle limiter so overlapping notes never clip
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(out[i])) }
        if peak > 0.9 { let k = 0.9 / peak; for i in 0..<n { out[i] *= k } }
        // tiny fades at the loop seam
        let fade = Int(0.01 * sampleRate)
        for i in 0..<fade { let k = Float(i) / Float(fade); out[i] *= k; out[n - 1 - i] *= k }
        return buf
    }
}
