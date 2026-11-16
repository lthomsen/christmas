import AppKit
import CoreImage
import Vision
import simd

/// A virtual nisse hat in the JuleHygge Kamera picture.
///
/// Vision finds each face and the head's direction in 3D (yaw = turn, pitch = nod, roll = tilt). From that the
/// head is modelled as a sphere behind the face, and the hat is a real 3D shape in the head's own coordinates:
/// a fur brim around the head, a cone that bends over and hangs down, and a pompom at the tip. Every frame it
/// is turned with the head, lit from a fixed light (so light and shade move when the head turns), and the parts
/// behind the head are left out. Drawn with Core Graphics into a small image, then laid on the camera picture.
final class NisseHat {
    /// Face rectangles with roll/yaw/pitch (pitch only from revision 3).
    let request: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        if VNDetectFaceRectanglesRequest.supportedRevisions.contains(VNDetectFaceRectanglesRequestRevision3) {
            r.revision = VNDetectFaceRectanglesRequestRevision3
        }
        return r
    }()

    /// Vision's angle conventions mapped to ours (x right, y up, z toward the viewer; positive yaw turns the
    /// face toward the picture's right, positive pitch nods down). Flip here if a live test shows a mirror.
    static let rollSign: CGFloat = 1, yawSign: CGFloat = 1, pitchSign: CGFloat = 1

    /// A head: centre of the sphere in output coordinates (y up), radius, and its direction.
    struct Head { var x: CGFloat, y: CGFloat, r: CGFloat, roll: CGFloat, yaw: CGFloat, pitch: CGFloat }

    /// One hat following one head; smoothed so it does not shake, and kept a moment when the face is lost.
    private final class Track {
        var h: Head
        var lost: CGFloat = 0
        var fresh = true
        var profile: Profile?
        init(_ h: Head) { self.h = h }
    }

    /// The person's head measured against the face box (both in face-box heights): the head's width at the
    /// forehead and how far above the face box's centre the top of the head (with hair) is. Measured on a still
    /// frame every 10 s in the background (see `calibrate`), so each frame only needs the face box.
    struct Profile { var width: CGFloat, top: CGFloat }
    /// Without a measurement yet: an average head.
    private static let defaultProfile = Profile(width: 1.3, top: 0.8)
    private var tracks: [Track] = []
    private static let keepLost: CGFloat = 0.4, fadeOut: CGFloat = 0.3

    // ------------------------------------------------------------------ tracking

    /// Feeds this frame's Vision results. `extent` is the camera image, `transform` the same aspect-fill
    /// transform the camera picture gets, so the hat lands exactly on the head.
    func update(_ observations: [VNFaceObservation], mask: CVPixelBuffer? = nil, extent: CGRect, transform: CGAffineTransform, dt: CGFloat) {
        let k = hypot(transform.a, transform.b)   // the aspect fill scales evenly
        lastExtent = extent; lastTransform = transform
        typealias FaceInfo = (c: CGPoint, fh: CGFloat, roll: CGFloat, yaw: CGFloat, pitch: CGFloat,
                              outline: (top: CGFloat, left: CGFloat, right: CGFloat)?)
        let faces: [FaceInfo] = observations.prefix(3).map { o in
            let b = o.boundingBox   // normalized, origin bottom-left (like Core Image)
            let c = CGPoint(x: extent.minX + b.midX * extent.width, y: extent.minY + b.midY * extent.height).applying(transform)
            // the head's outline in this frame's person mask, in output pixels (distances scale by k)
            var outline: (top: CGFloat, left: CGFloat, right: CGFloat)?
            if let mask, let s = Self.silhouette(o, mask: mask, size: extent.size) {
                let top = s.top / s.fh, width = (s.left + s.right) / s.fh
                // a raised hand or a cut-off head gives an implausible outline: then the face box is used alone
                if (0.45...1.8).contains(top) && (0.7...2.8).contains(width) { outline = (s.top * k, s.left * k, s.right * k) }
            }
            return (c, b.height * extent.height * k,
                    Self.rollSign * CGFloat(o.roll?.doubleValue ?? 0), Self.yawSign * CGFloat(o.yaw?.doubleValue ?? 0),
                    Self.pitchSign * CGFloat(o.pitch?.doubleValue ?? 0), outline)
        }
        /// The head from the face box and the person's measured profile: the size comes from the box's height,
        /// which hardly changes when the head turns (its width shrinks), and the head's top from the profile.
        func head(_ f: FaceInfo, _ p: Profile) -> Head {
            // the brim's outer edge is (brimR + fur) ≈ 1.1 r from the middle: make that just outside the measured
            // half width of the head (0.52 of the width), so the fur hugs the head instead of standing out
            let r = p.width * f.fh * 0.52 / (Self.brimR + 0.2)
            let R = Self.rotation(roll: f.roll, yaw: f.yaw, pitch: f.pitch)
            let up = R * SIMD3(0, 1, 0), fwd = R * SIMD3(0, 0, 1)
            let imgUp = CGPoint(x: -sin(f.roll), y: cos(f.roll)), imgRight = CGPoint(x: cos(f.roll), y: sin(f.roll))
            if let o = f.outline {
                // From the outline: the middle of the head at forehead height and the top of the head.
                // That middle is the middle of the whole (oval) head, which lies behind the sphere's centre
                // by `brimBack` along the face's direction; the sphere's top is one radius above its centre.
                let fore = CGPoint(x: f.c.x + imgUp.x * f.fh * 0.45, y: f.c.y + imgUp.y * f.fh * 0.45)
                let along = (o.right - o.left) / 2
                let mid = CGPoint(x: fore.x + imgRight.x * along, y: fore.y + imgRight.y * along)
                let top = CGPoint(x: f.c.x + imgUp.x * o.top, y: f.c.y + imgUp.y * o.top)
                let rise = (top.x - mid.x) * imgUp.x + (top.y - mid.y) * imgUp.y - r   // from the middle up to the centre
                let back = -Self.brimBack * r
                return Head(x: mid.x + imgUp.x * rise + CGFloat(fwd.x) * back, y: mid.y + imgUp.y * rise + CGFloat(fwd.y) * back,
                            r: r, roll: f.roll, yaw: f.yaw, pitch: f.pitch)
            }
            // top of the head in the picture: up from the face centre (tilted with the head), and moved back
            // against the face's direction, since a turned face sits in front of the head's middle
            let top = CGPoint(x: f.c.x - sin(f.roll) * p.top * f.fh - CGFloat(fwd.x) * r * 0.7,
                              y: f.c.y + cos(f.roll) * p.top * f.fh - CGFloat(fwd.y) * r * 0.7)
            // the sphere's centre is one radius below the top, along the head's own up
            return Head(x: top.x - CGFloat(up.x) * r, y: top.y - CGFloat(up.y) * r, r: r, roll: f.roll, yaw: f.yaw, pitch: f.pitch)
        }
        for t in tracks { t.fresh = false }
        for f in faces {
            let near = tracks.filter { !$0.fresh }.min { hypot($0.h.x - f.c.x, $0.h.y - f.c.y) < hypot($1.h.x - f.c.x, $1.h.y - f.c.y) }
            let h = head(f, near?.profile ?? Self.defaultProfile)
            if let t = near, hypot(t.h.x - h.x, t.h.y - h.y) < max(t.h.r, h.r) * 1.5 {
                let kp: CGFloat = 0.45, ka: CGFloat = 0.3   // position follows quicker than the angles
                t.h.x += (h.x - t.h.x) * kp; t.h.y += (h.y - t.h.y) * kp
                // the head keeps its size: learned while looking straight ahead, only drifting slowly while turned
                // (so leaning toward or away from the camera still changes it)
                let frontal = abs(h.yaw) < 0.35 && abs(h.pitch) < 0.35
                t.h.r += (h.r - t.h.r) * (frontal ? kp : 0.03)
                t.h.roll += (h.roll - t.h.roll) * ka; t.h.yaw += (h.yaw - t.h.yaw) * ka; t.h.pitch += (h.pitch - t.h.pitch) * ka
                t.lost = 0; t.fresh = true
            } else {
                tracks.append(Track(h))
            }
        }
        for t in tracks where !t.fresh { t.lost += dt }
        tracks.removeAll { $0.lost > Self.keepLost + Self.fadeOut }
    }

    // ------------------------------------------------------------------ head calibration (background)

    private var lastExtent = CGRect.zero, lastTransform = CGAffineTransform.identity
    private var calibrating = false
    private var nextCalibration: CFTimeInterval = 0
    private let calibrationQueue = DispatchQueue(label: "dk.julehygge.hat.calibration", qos: .utility)

    /// Every 10 s (and as soon as a new head has no profile) a still camera frame is analysed in the background:
    /// an accurate person cutout, measured around each face that looks roughly straight ahead. Results are
    /// handed back on `queue` and blended into each person's profile. Call on the video queue.
    func calibrate(camera: CVPixelBuffer, faces: [VNFaceObservation], queue: DispatchQueue) {
        let now = CACurrentMediaTime()
        let needsFirst = tracks.contains { $0.profile == nil }
        guard !calibrating, now >= nextCalibration || (needsFirst && now >= nextCalibration - 9) else { return }
        let frontal = faces.prefix(3).filter { abs(CGFloat($0.yaw?.doubleValue ?? 0)) < 0.3 && abs(CGFloat($0.pitch?.doubleValue ?? 0)) < 0.3 }
        guard !frontal.isEmpty else { return }
        calibrating = true
        nextCalibration = now + 10
        let extent = lastExtent, transform = lastTransform
        calibrationQueue.async { [weak self] in
            let seg = VNGeneratePersonSegmentationRequest()
            seg.qualityLevel = .accurate
            seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try? VNImageRequestHandler(cvPixelBuffer: camera, options: [:]).perform([seg])
            var results: [(CGPoint, Profile)] = []
            if let mask = seg.results?.first?.pixelBuffer {
                for f in frontal {
                    guard let p = Self.measure(f, mask: mask, size: extent.size) else { continue }
                    let c = CGPoint(x: extent.minX + f.boundingBox.midX * extent.width, y: extent.minY + f.boundingBox.midY * extent.height).applying(transform)
                    results.append((c, p))
                }
            }
            queue.async { self?.applyCalibration(results) }
        }
    }

    private func applyCalibration(_ results: [(CGPoint, Profile)]) {
        calibrating = false
        for (c, p) in results {
            guard let t = tracks.min(by: { hypot($0.h.x - c.x, $0.h.y - c.y) < hypot($1.h.x - c.x, $1.h.y - c.y) }),
                  hypot(t.h.x - c.x, t.h.y - c.y) < t.h.r * 2.5 else { continue }
            if let old = t.profile {
                t.profile = Profile(width: (old.width + p.width) / 2, top: (old.top + p.top) / 2)
            } else { t.profile = p }
        }
        if ProcessInfo.processInfo.environment["JULE_DEBUG"] == "1" {
            ErrorLog.debug("nissehue: hovedmåling " + results.map { String(format: "bredde %.2f top %.2f", $0.1.width, $0.1.top) }.joined(separator: ", "))
        }
    }

    /// Measures one head in the person mask. Works in camera pixels (y up); the mask covers the whole camera
    /// image at a lower resolution. Returns nil when the result is implausible (a raised hand, a cut-off head).
    static func measure(_ f: VNFaceObservation, mask: CVPixelBuffer, size: CGSize) -> Profile? {
        guard let s = silhouette(f, mask: mask, size: size) else { return nil }
        let p = Profile(width: (s.left + s.right) / s.fh, top: s.top / s.fh)
        guard (0.45...1.7).contains(p.top), (0.8...2.2).contains(p.width) else { return nil }
        return p
    }

    /// The head's outline in the person mask, around one face, in camera pixels (y up): how far up from the face
    /// centre the top of the head (with hair) is, and how far left and right of the forehead the outline is,
    /// measured along the head's tilt. `fh` is the face box height in camera pixels.
    static func silhouette(_ f: VNFaceObservation, mask: CVPixelBuffer, size: CGSize) -> (top: CGFloat, left: CGFloat, right: CGFloat, fh: CGFloat)? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask), stride = CVPixelBufferGetBytesPerRow(mask)
        func inside(_ p: CGPoint) -> Bool {
            let x = Int(p.x / size.width * CGFloat(mw)), y = Int((1 - p.y / size.height) * CGFloat(mh))
            guard x >= 0, x < mw, y >= 0, y < mh else { return false }
            return base[y * stride + x] > 127
        }
        let b = f.boundingBox
        let c = CGPoint(x: b.midX * size.width, y: b.midY * size.height)
        let fh = b.height * size.height
        let roll = rollSign * CGFloat(f.roll?.doubleValue ?? 0)
        let up = CGPoint(x: -sin(roll), y: cos(roll)), right = CGPoint(x: cos(roll), y: sin(roll))
        let step = max(1, size.height / CGFloat(mh))
        /// Walks from `p` along `d` while inside the person (small gaps in the hair are allowed); returns the distance.
        func reach(_ p: CGPoint, _ d: CGPoint, limit: CGFloat) -> CGFloat {
            var dist: CGFloat = 0, last: CGFloat = 0, gap = 0
            while dist < limit {
                dist += step
                if inside(CGPoint(x: p.x + d.x * dist, y: p.y + d.y * dist)) { last = dist; gap = 0 } else { gap += 1; if gap > 3 { break } }
            }
            return last
        }
        let top = reach(c, up, limit: fh * 2.2)
        let forehead = CGPoint(x: c.x + up.x * fh * 0.45, y: c.y + up.y * fh * 0.45)
        let r = reach(forehead, right, limit: fh * 1.6), l = reach(forehead, CGPoint(x: -right.x, y: -right.y), limit: fh * 1.6)
        guard top > 0, r > 0, l > 0 else { return nil }
        return (top, l, r, fh)
    }

    /// Puts a hat on every tracked head, on top of `image`.
    func apply(to image: CIImage) -> CIImage {
        var out = image
        for t in tracks {
            let alpha = t.lost <= Self.keepLost ? 1 : max(0, 1 - (t.lost - Self.keepLost) / Self.fadeOut)
            if alpha <= 0 { continue }
            if let hat = Self.render(t.h, alpha: alpha) { out = hat.composited(over: out) }
        }
        return out
    }

    // ------------------------------------------------------------------ 3D

    typealias V = SIMD3<Double>

    /// Head-to-camera rotation: tilt (z) · turn (y) · nod (x).
    static func rotation(roll: CGFloat, yaw: CGFloat, pitch: CGFloat) -> simd_double3x3 {
        let (cr, sr) = (cos(Double(roll)), sin(Double(roll)))
        let (cy, sy) = (cos(Double(yaw)), sin(Double(yaw)))
        let (cp, sp) = (cos(Double(pitch)), sin(Double(pitch)))
        let rz = simd_double3x3(rows: [V(cr, -sr, 0), V(sr, cr, 0), V(0, 0, 1)])
        let ry = simd_double3x3(rows: [V(cy, 0, sy), V(0, 1, 0), V(-sy, 0, cy)])
        let rx = simd_double3x3(rows: [V(1, 0, 0), V(0, cp, -sp), V(0, sp, cp)])
        return rz * ry * rx
    }

    // The hat in head units (head radius = 1), head centre at the origin, x right, y up, z toward the face's front.
    // A head is longer from forehead to neck than it is wide, so the brim is an oval: deeper (`brimDepth`)
    // and centred a little behind the sphere's centre (`brimBack`), so from the side the hat covers the whole head.
    // Like a real hat it sits high on the forehead and low at the nape (`brimTilt` < 0: the back is lower).
    // Front of the brim at y ≈ 0.6 (above the brows), back at ≈ 0.2; from forehead (z ≈ 1) to the back of the skull (z ≈ −1.7).
    private static let brimY = 0.4, brimR = 0.9, brimTilt = -0.2
    // Depth 1.25 × the width: a turned head looks about 10 % wider at 45°, and so does the brim (1.5 made it 28 %).
    private static let brimDepth = 1.25, brimBack = -0.25
    private static func brimPoint(_ a: Double, radius: Double = brimR, lift: Double = 0) -> V {
        let x = cos(a) * radius, z = brimBack + sin(a) * radius * brimDepth
        return V(x, brimY - brimTilt * sin(a) + lift, z)
    }
    /// The cap's centre line: up from the brim, over, and hanging down to the side and back.
    private static let spine: [V] = [V(0, brimY, brimBack), V(0, brimY + 1.0, brimBack - 0.15), V(0.15, brimY + 1.75, brimBack - 0.45), V(0.85, brimY + 1.1, brimBack - 0.85)]
    private static func bezier(_ t: Double) -> (V, V) {
        let p = spine, u = 1 - t
        let w0: Double = u * u * u, w1: Double = 3 * u * u * t, w2: Double = 3 * u * t * t, w3: Double = t * t * t
        var pos: V = w0 * p[0]
        pos += w1 * p[1]; pos += w2 * p[2]; pos += w3 * p[3]
        let d0: V = p[1] - p[0], d1: V = p[2] - p[1], d2: V = p[3] - p[2]
        var tan: V = (3 * u * u) * d0
        tan += (6 * u * t) * d1; tan += (3 * t * t) * d2
        return (pos, simd_normalize(tan))
    }

    private static let light = simd_normalize(V(-0.45, 0.6, 0.7))
    private static let halfway = simd_normalize(light + V(0, 0, 1))

    /// One thing to draw, sorted back to front by depth.
    private enum Item { case quad([CGPoint], CGColor), ball(CGPoint, CGFloat, Double) }

    /// Draws the hat for one head; returns it positioned in output coordinates.
    static func render(_ h: Head, alpha: CGFloat) -> CIImage? {
        let r = Double(h.r)
        guard r > 8 else { return nil }
        let R = rotation(roll: h.roll, yaw: h.yaw, pitch: h.pitch)
        // canvas around the head: 2.6 r to each side, 1.6 r below the centre and 3 r above
        let left = 2.6 * r, below = 1.6 * r
        let cw = Int(5.2 * r), ch = Int(4.6 * r)
        guard let g = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        g.setAlpha(alpha)
        func cam(_ p: V) -> V { R * p }
        func screen(_ c: V) -> CGPoint { CGPoint(x: left + c.x * r, y: below + c.y * r) }
        /// Hidden behind the head: behind the sphere's middle and inside its outline.
        func behindHead(_ c: V, margin: Double = 0.97) -> Bool { c.z < 0 && hypot(c.x, c.y) < margin }

        // shadow of the brim on the forehead, only on the head itself
        do {
            let ring = (0..<36).map { i in screen(cam(brimPoint(Double(i) / 36 * 2 * .pi, radius: brimR + 0.08, lift: -0.14))) }
            g.saveGState()
            let centre = screen(V(0, 0, 0))
            g.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)); g.clip()
            let far: CGFloat = 20_000
            g.setShadow(offset: CGSize(width: -far, height: 0), blur: CGFloat(r * 0.22), color: C(30, 5, 5, 140))
            g.translateBy(x: far, y: 0)
            g.addLines(between: ring); g.closePath(); g.fillPath()
            g.restoreGState()
        }

        var items: [(Double, Item)] = []

        // the cap: rings along the bent centre line, joined by small quads, each lit by its own normal
        let rings = 34, segs = 40
        var ringPts: [[V]] = []
        for k in 0...rings {
            let t = Double(k) / Double(rings)
            let (c, tan) = bezier(t)
            let b1 = simd_normalize(simd_cross(tan, V(0, 0, 1)))
            let b2 = simd_cross(b1, tan)
            let rad = (brimR - 0.1) * pow(1 - t, 1.05) + 0.03   // starts inside the fur, so its edge never shows
            let depth = 1 + (brimDepth - 1) * pow(1 - t, 1.5)   // oval like the brim at the bottom, round toward the tip
            ringPts.append((0..<segs).map { j in
                let a = Double(j) / Double(segs) * 2 * .pi
                var off = rad * (cos(a) * b1 + sin(a) * b2)
                off.z *= depth
                return c + off
            })
        }
        for k in 0..<rings {
            let (c0, _) = bezier(Double(k) / Double(rings)), (c1, _) = bezier(Double(k + 1) / Double(rings))
            for j in 0..<segs {
                let j1 = (j + 1) % segs
                let p = [ringPts[k][j], ringPts[k][j1], ringPts[k + 1][j1], ringPts[k + 1][j]].map(cam)
                let mid = (p[0] + p[1] + p[2] + p[3]) / 4
                let n = simd_normalize(cam((ringPts[k][j] + ringPts[k][j1]) / 2 - c0) + cam((ringPts[k + 1][j] + ringPts[k + 1][j1]) / 2 - c1))
                if n.z < -0.05 || behindHead(mid) { continue }
                let diffuse = max(0, simd_dot(n, light)), spec = pow(max(0, simd_dot(n, halfway)), 16) * 0.22
                let shade = 0.32 + 0.68 * diffuse
                let col = CGColor(srgbRed: min(1, 0.80 * shade + spec), green: min(1, 0.07 * shade + spec * 0.9),
                                  blue: min(1, 0.12 * shade + spec * 0.9), alpha: 1)
                items.append((mid.z, .quad(p.map(screen), col)))
            }
        }

        // fur brim: two rows of fluffy balls around the head
        for (row, (lift, radius, size)) in [(-0.02, brimR + 0.03, 0.17), (0.1, brimR - 0.02, 0.15)].enumerated() {
            let n = 46
            for i in 0..<n {
                let a = (Double(i) + (row == 1 ? 0.5 : 0)) / Double(n) * 2 * .pi
                let c = cam(brimPoint(a, radius: radius, lift: lift))
                if behindHead(c, margin: 0.9) { continue }
                let normal = simd_normalize(cam(V(cos(a), 0.35, sin(a))))
                if normal.z < -0.35 { continue }
                let shade = 0.45 + 0.55 * max(0, simd_dot(normal, light))
                items.append((c.z + 0.02, .ball(screen(c), CGFloat(size * r), shade)))
            }
        }
        // pompom at the tip
        let tip = spine[3] + V(0.04, -0.08, 0)
        for i in 0..<10 {
            let a = Double(i) / 10 * 2 * .pi, b = Double(i % 3) * 0.6 - 0.6
            let off = V(cos(a) * cos(b), sin(b), sin(a) * cos(b)) * 0.12
            let c = cam(tip + off)
            let normal = simd_normalize(cam(off))
            if behindHead(c) { continue }
            let shade = 0.5 + 0.5 * max(0, simd_dot(normal, light))
            items.append((c.z, .ball(screen(c), CGFloat(0.17 * r), shade)))
        }
        let tc = cam(tip)
        if !behindHead(tc) { items.append((tc.z + 0.1, .ball(screen(tc), CGFloat(0.24 * r), 0.9))) }

        // back to front
        items.sort { $0.0 < $1.0 }
        g.setLineWidth(1)
        g.setLineJoin(.round)
        for (_, item) in items {
            switch item {
            case let .quad(pts, col):
                // filled and stroked in the same colour, so no seams show between neighbouring quads
                g.setFillColor(col); g.setStrokeColor(col)
                g.addLines(between: pts); g.closePath(); g.drawPath(using: .fillStroke)
            case let .ball(p, size, shade):
                let rect = CGRect(x: p.x - size, y: p.y - size, width: 2 * size, height: 2 * size)
                g.draw(fluffLight, in: rect)
                g.setAlpha(alpha * CGFloat(max(0, min(1, (1 - shade) * 1.3))))
                g.draw(fluffDark, in: rect)
                g.setAlpha(alpha)
            }
        }
        guard let img = g.makeImage() else { return nil }
        return CIImage(cgImage: img).transformed(by: CGAffineTransform(translationX: h.x - CGFloat(left), y: h.y - CGFloat(below)))
    }

    /// A soft fuzzy fur ball (lit), and the same shape in shadow colour to fade over it.
    private static let fluffLight = fluff(C(255, 255, 255), C(232, 238, 246))
    private static let fluffDark = fluff(C(120, 132, 160), C(105, 116, 145))
    private static func fluff(_ inner: CGColor, _ outer: CGColor) -> CGImage {
        let s = 96
        let g = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = SeededRandom(seed: 7)
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [inner, outer, outer.copy(alpha: 0)!] as CFArray, locations: [0, 0.6, 1])!
        for _ in 0..<14 {
            let a = Double(rng.next()) * 2 * .pi, d = Double(rng.next()) * 14
            let c = CGPoint(x: 48 + cos(a) * d, y: 48 + sin(a) * d)
            g.drawRadialGradient(grad, startCenter: CGPoint(x: c.x - 6, y: c.y + 6), startRadius: 0, endCenter: c, endRadius: 34, options: [])
        }
        return g.makeImage()!
    }

    // ------------------------------------------------------------------ test

    /// Test aid (--nissehue-test=DIR[,IMAGE]): draws the hat on a drawn head in several poses (hoveder.png),
    /// and if an image with a face is given, puts the hat on it as it would look in the camera (med-hue.png).
    static func test(dir: String, image: String?) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func write(_ img: CIImage, _ name: String) {
            guard let cg = GPU.ciContext.createCGImage(img, from: img.extent) else { return }
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            print("skrev", name)
        }
        if let image, let src = CIImage(contentsOf: URL(fileURLWithPath: image)) {
            let hat = NisseHat()
            let handler = VNImageRequestHandler(ciImage: src, options: [:])
            let t0 = CACurrentMediaTime()
            try? handler.perform([hat.request])
            let faces = hat.request.results ?? []
            print(String(format: "%d ansigt(er) på %.1f ms", faces.count, (CACurrentMediaTime() - t0) * 1000))
            for f in faces { print("  ramme \(f.boundingBox) roll \(f.roll ?? 0) yaw \(f.yaw ?? 0) pitch \(f.pitch ?? 0)") }
            // the head measurement, as the camera's calibration would do it
            let seg = VNGeneratePersonSegmentationRequest()
            seg.qualityLevel = .accurate
            seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try? handler.perform([seg])
            if let mask = seg.results?.first?.pixelBuffer, let f = faces.first {
                let p = measure(f, mask: mask, size: src.extent.size)
                print("  hovedmåling:", p.map { String(format: "bredde %.2f top %.2f", $0.width, $0.top) } ?? "afvist")
                hat.update(faces, extent: src.extent, transform: .identity, dt: 0)
                if let p { hat.tracks.first?.profile = p }
            }
            for _ in 0..<12 { hat.update(faces, extent: src.extent, transform: .identity, dt: 0) }
            write(hat.apply(to: src).cropped(to: src.extent), "med-hue.png")
            return
        }
        // a sheet of drawn heads (sphere + eyes, nose and mouth placed by the same rotation) in different poses
        let poses: [(String, CGFloat, CGFloat, CGFloat)] = [("lige frem", 0, 0, 0), ("drejet højre", 0, 0.6, 0), ("drejet 45°", 0, -0.78, 0),
                                                           ("nikker ned", 0, 0, 0.35), ("profil", 0, 1.35, 0), ("hælder", 0.35, 0.3, 0.1)]
        let cell = 420, W = cell * 3, H = cell * 2
        guard let g = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        g.setFillColor(C(40, 55, 80)); g.fill(CGRect(x: 0, y: 0, width: W, height: H))
        var heads: [Head] = []
        for (i, p) in poses.enumerated() {
            let cx = CGFloat(i % 3 * cell + cell / 2), cy = CGFloat((1 - i / 3) * cell + cell / 2 - 50)
            let r: CGFloat = 90
            let R = rotation(roll: p.1, yaw: p.2, pitch: p.3)
            // hair (a little volume on top), neck and shoulders, then the face
            g.setFillColor(C(95, 62, 40)); g.fillEllipse(in: CGRect(x: cx - r * 1.08, y: cy - r * 0.2, width: 2.16 * r, height: 1.38 * r))
            g.setFillColor(C(210, 165, 135)); g.fill(CGRect(x: cx - r * 0.45, y: cy - r * 1.9, width: r * 0.9, height: r))
            g.setFillColor(C(60, 90, 140)); g.fillEllipse(in: CGRect(x: cx - r * 1.9, y: cy - r * 2.9, width: 3.8 * r, height: 1.6 * r))
            g.setFillColor(C(225, 180, 150)); g.fillEllipse(in: CGRect(x: cx - r, y: cy - r * 1.05, width: 2 * r, height: 2.1 * r))
            func dot(_ v: V, _ s: CGFloat, _ col: CGColor) {
                let c = R * v
                if c.z < 0 { return }
                g.setFillColor(col); g.fillEllipse(in: CGRect(x: cx + CGFloat(c.x) * r - s, y: cy + CGFloat(c.y) * r - s, width: 2 * s, height: 2 * s))
            }
            dot(V(-0.33, 0.12, 0.93), 8, C(30, 30, 30)); dot(V(0.33, 0.12, 0.93), 8, C(30, 30, 30))
            dot(V(0, -0.15, 1), 9, C(205, 150, 125)); dot(V(0, -0.5, 0.86), 12, C(160, 60, 60))
            heads.append(Head(x: cx, y: cy, r: r, roll: p.1, yaw: p.2, pitch: p.3))
        }
        guard let base = g.makeImage() else { return }
        var img = CIImage(cgImage: base)
        // a person mask from the drawing (everything that is not background), at the camera mask's lower resolution
        let mw = W / 3, mh = H / 3
        var maskPB: CVPixelBuffer?
        CVPixelBufferCreate(nil, mw, mh, kCVPixelFormatType_OneComponent8, nil, &maskPB)
        guard let mask = maskPB, let data = g.data else { return }
        CVPixelBufferLockBaseAddress(mask, [])
        let mbase = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self), mstride = CVPixelBufferGetBytesPerRow(mask)
        let src = data.assumingMemoryBound(to: UInt8.self), srow = g.bytesPerRow
        for y in 0..<mh { for x in 0..<mw {
            let px = src + (y * 3) * srow + (x * 3) * 4   // CGContext memory is top row first, like the mask
            mbase[y * mstride + x] = px[0] == 40 && px[1] == 55 && px[2] == 80 ? 0 : 255
        } }
        CVPixelBufferUnlockBaseAddress(mask, [])
        let t0 = CACurrentMediaTime()
        var frontProfile: Profile?
        for (i, h) in heads.enumerated() {
            // the face box Vision would report: about brows to chin around the projected face, as tall as wide
            let R = rotation(roll: h.roll, yaw: h.yaw, pitch: h.pitch)
            let fc = R * V(0, -0.25, 0.95)
            let fcx = h.x + CGFloat(fc.x) * h.r, fcy = h.y + CGFloat(fc.y) * h.r, side = h.r * 1.3
            let box = CGRect(x: (fcx - side / 2) / CGFloat(W), y: (fcy - side / 2) / CGFloat(H), width: side / CGFloat(W), height: side / CGFloat(H))
            let obs = VNFaceObservation(requestRevision: VNDetectFaceRectanglesRequestRevision3, boundingBox: box,
                                        roll: NSNumber(value: Double(h.roll) / Double(rollSign)), yaw: NSNumber(value: Double(h.yaw) / Double(yawSign)),
                                        pitch: NSNumber(value: Double(h.pitch) / Double(pitchSign)))
            let hat = NisseHat()
            let ext = CGRect(x: 0, y: 0, width: W, height: H)
            hat.update([obs], mask: mask, extent: ext, transform: .identity, dt: 0)
            // like the camera: the head is measured while looking straight ahead, and that profile is used for every pose
            if i == 0 { frontProfile = measure(obs, mask: mask, size: ext.size) }
            let prof = frontProfile
            if i == 0 { print(prof.map { String(format: "målt forfra: bredde %.2f top %.2f", $0.width, $0.top) } ?? "ingen måling") }
            // as in the camera: the profile is used from then on (a few frames to settle the smoothing)
            if let prof { hat.tracks.first?.profile = prof }
            for _ in 0..<12 { hat.update([obs], mask: mask, extent: ext, transform: .identity, dt: 0) }
            img = hat.apply(to: img)
        }
        print(String(format: "6 huer målt og tegnet på %.1f ms", (CACurrentMediaTime() - t0) * 1000))
        write(img.cropped(to: CGRect(x: 0, y: 0, width: W, height: H)), "hoveder.png")
    }
}
