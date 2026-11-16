import AVFoundation
import CoreImage
import CoreMediaIO
import Vision
import os

let camLog = Logger(subsystem: "dk.julehygge.JuleHygge", category: "camera")

/// "JuleHygge Kamera": the user in front of a live Christmas scene, as a camera Teams (or any app) can pick.
///
/// The camera extension (CameraExtension/) is only a pipe: it exposes the camera device and forwards whatever
/// this app sends to its sink stream. All the work happens here, and only while some app is actually
/// reading the camera:
///   1. read the real camera,
///   2. cut out the person with Vision,
///   3. draw the Christmas scene on a virtual "third screen" (an offscreen ScreenOverlay),
///   4. put the person on top and send the frame to the extension.
final class VirtualCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let width = 1280, height = 720
    /// Shared with the extension (legacy device ID → CMIO device UID).
    static let deviceUID = "dk.julehygge.JuleHygge.Camera.device"
    /// Custom device property the extension sets to "1" while an app reads the camera.
    static let sourceRunningSelector = fourCC("jhsr")

    private unowned let c: Controller
    private let sink = CMIOSink()
    private var session: AVCaptureSession?
    private let videoQueue = DispatchQueue(label: "dk.julehygge.camera")
    private var ciContext: CIContext { GPU.ciContext }
    private var pixelPool: CVPixelBufferPool?
    private var formatDescription: CMFormatDescription?
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private let lock = NSLock()
    private var background: CIImage?       // latest rendered Christmas scene (written on main, read on videoQueue)
    private(set) var active = false
    private var pollTimer: F = 0
    private var frameCount = 0
    // timing (videoQueue except statBg*, which is main; good enough for a log line)
    private var statSince = CACurrentMediaTime(), statFrame = 0.0, statFrameN = 0, statSeg = 0.0, statSegN = 0, statBg = 0.0, statBgN = 0

    init(controller: Controller) {
        c = controller
        super.init()
    }

    // ------------------------------------------------------------------ driven by the Controller

    /// Called every frame on the main thread. Checks once a second whether an app reads the camera, and
    /// while active renders the virtual screen as the background.
    func tick(_ dt: F, scene: ScreenOverlay?) {
        pollTimer -= dt
        if pollTimer <= 0 {
            pollTimer = 1
            let connected = sink.connect()
            let inUse = connected && sink.sourceRunning()
            if inUse != active { camLog.info("poll: connected=\(connected) inUse=\(inUse) active=\(self.active)") }
            if inUse && !active { start() } else if !inUse && active { stop() }
        }
        guard active, let scene else { return }
        let t0 = CACurrentMediaTime()
        let img = scene.renderSceneImage()
        statBg += CACurrentMediaTime() - t0; statBgN += 1
        lock.lock(); background = img.map { CIImage(cgImage: $0) }; lock.unlock()
    }

    var wantsScene: Bool { active }

    private func start() {
        guard sink.startSink() else { camLog.error("startSink failed"); return }
        camLog.info("virtual camera started")
        active = true
        c.virtualSceneChanged()
        startCapture()
        ErrorLog.debug("virtual camera: started")
    }

    func stop() {
        guard active else { return }
        active = false
        session?.stopRunning()
        session = nil
        sink.stopSink()
        lock.lock(); background = nil; lock.unlock()
        c.virtualSceneChanged()
        ErrorLog.debug("virtual camera: stopped")
    }

    // ------------------------------------------------------------------ real camera

    private func startCapture() {
        // the real camera, never our own virtual one (that would feed itself)
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                       mediaType: .video, position: .unspecified).devices
            .filter { $0.uniqueID != Self.deviceUID && !$0.localizedName.contains("JuleHygge") }
        guard let device = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
            ErrorLog.write("virtual camera: no real camera found"); return
        }
        camLog.info("real camera: \(device.localizedName, privacy: .public)")
        AVCaptureDevice.requestAccess(for: .video) { ok in
            camLog.info("camera access: \(ok)")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                guard ok else { ErrorLog.write("virtual camera: camera access denied"); return }
                self.configureSession(device)
            }
        }
    }

    private func configureSession(_ device: AVCaptureDevice) {
        let s = AVCaptureSession()
        if s.canSetSessionPreset(.hd1280x720) { s.sessionPreset = .hd1280x720 }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { camLog.error("camera input: \(error.localizedDescription, privacy: .public)"); return }
        guard s.canAddInput(input) else { camLog.error("cannot add camera input"); return }
        s.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: videoQueue)
        guard s.canAddOutput(out) else { camLog.error("cannot add video output"); return }
        s.addOutput(out)
        session = s
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: s, queue: nil) { n in
            camLog.error("capture runtime error: \(String(describing: n.userInfo?[AVCaptureSessionErrorKey]), privacy: .public)")
        }
        videoQueue.async {
            s.startRunning()
            camLog.info("capture session running=\(s.isRunning)")
        }
    }

    // ------------------------------------------------------------------ compositing (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let camera = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); let bg = background; lock.unlock()
        frameCount += 1
        guard let bg else { if frameCount % 60 == 1 { camLog.info("frame without background") }; return }
        let t0 = CACurrentMediaTime()
        defer {
            statFrame += CACurrentMediaTime() - t0; statFrameN += 1
            let now = CACurrentMediaTime()
            if now - statSince >= 2 {
                let n = Double(max(1, statFrameN)), nb = Double(max(1, statBgN)), ns = Double(max(1, statSegN))
                camLog.info("perf: \(String(format: "%.1f", Double(self.statFrameN) / (now - self.statSince)), privacy: .public) fps ud | billede \(String(format: "%.1f", self.statFrame / n * 1000), privacy: .public) ms (heraf udskæring \(String(format: "%.1f", self.statSeg / ns * 1000), privacy: .public) ms) | julescene \(String(format: "%.1f", self.statBg / nb * 1000), privacy: .public) ms × \(self.statBgN)")
                statSince = now; statFrame = 0; statFrameN = 0; statSeg = 0; statSegN = 0; statBg = 0; statBgN = 0
            }
        }
        guard let out = composite(camera: camera, background: bg), let sb = makeSampleBuffer(out) else { if frameCount % 60 == 1 { camLog.error("composite failed") }; return }
        let ok = sink.enqueue(sb)
        if frameCount % 60 == 1 { camLog.info("frame \(self.frameCount) enqueued=\(ok)") }
    }

    private func composite(camera: CVPixelBuffer, background: CIImage) -> CVPixelBuffer? {
        let W = CGFloat(Self.width), H = CGFloat(Self.height)
        // A fresh person mask for every frame: reusing the previous one made the edge trail behind when moving.
        let handler = VNImageRequestHandler(cvPixelBuffer: camera, options: [:])
        let ts = CACurrentMediaTime()
        try? handler.perform([segmentation])
        statSeg += CACurrentMediaTime() - ts; statSegN += 1
        guard let maskBuffer = segmentation.results?.first?.pixelBuffer else { return nil }

        // The mask covers the whole camera image but at a lower resolution, often with another aspect ratio
        // (e.g. 4:3 vs 16:9). Stretch it to exactly the camera image first, then move both with the SAME
        // transform — scaling them separately made the mask a different size and offset from the person.
        let camImage = CIImage(cvPixelBuffer: camera)
        let maskRaw = CIImage(cvPixelBuffer: maskBuffer)
        let maskOnCamera = maskRaw.transformed(by: CGAffineTransform(scaleX: camImage.extent.width / maskRaw.extent.width,
                                                                     y: camImage.extent.height / maskRaw.extent.height))
        let fill = aspectFillTransform(camImage.extent, W, H)
        if frameCount == 1 || frameCount % 600 == 0 { camLog.info("camera \(Int(camImage.extent.width))×\(Int(camImage.extent.height)), mask \(Int(maskRaw.extent.width))×\(Int(maskRaw.extent.height))") }
        let cam = camImage.transformed(by: fill)
        let mask = maskOnCamera.transformed(by: fill)
        let bg = aspectFill(background, W, H)
        guard let blend = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: cam, kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: mask]),
              let result = blend.outputImage else { return nil }

        if pixelPool == nil {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: Self.width, kCVPixelBufferHeightKey as String: Self.height,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelPool)
        }
        var pb: CVPixelBuffer?
        guard let pool = pixelPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return nil }
        ciContext.render(result.cropped(to: CGRect(x: 0, y: 0, width: W, height: H)), to: pb)
        return pb
    }

    /// Scales an image of extent `e` to fill W×H (cropping the overflow evenly), as one transform.
    private func aspectFillTransform(_ e: CGRect, _ W: CGFloat, _ H: CGFloat) -> CGAffineTransform {
        let k = max(W / e.width, H / e.height)
        return CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: (W - e.width * k) / 2, y: (H - e.height * k) / 2))
    }

    private func aspectFill(_ img: CIImage, _ W: CGFloat, _ H: CGFloat) -> CIImage {
        img.transformed(by: aspectFillTransform(img.extent, W, H))
    }

    private func makeSampleBuffer(_ pb: CVPixelBuffer) -> CMSampleBuffer? {
        if formatDescription == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &formatDescription) }
        guard let fd = formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }
}

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

/// The app's end of the extension's sink stream, via the CoreMediaIO C API.
final class CMIOSink {
    private var device: CMIODeviceID = 0
    private var sinkStream: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var running = false
    private var lastLookup: CFTimeInterval = 0
    private var failures = 0

    private static func address(_ selector: UInt32, _ scope: UInt32 = UInt32(kCMIOObjectPropertyScopeGlobal)) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector), mScope: CMIOObjectPropertyScope(scope),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func ids(_ object: CMIOObjectID, _ selector: UInt32) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == 0, size > 0 else { return [] }
        var list = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &list) == 0 else { return [] }
        return list
    }

    private static func string(_ object: CMIOObjectID, _ selector: UInt32) -> String? {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == 0, size > 0 else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value) == 0 else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// Finds the JuleHygge camera device and its sink stream (re-checked at most every 5 s while missing).
    func connect() -> Bool {
        if device != 0 { return true }
        let now = CACurrentMediaTime()
        if now - lastLookup < 5 { return false }
        lastLookup = now
        // Asking AVFoundation first makes CoreMediaIO load camera extensions into this process.
        _ = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
        let all = Self.ids(CMIOObjectID(kCMIOObjectSystemObject), UInt32(kCMIOHardwarePropertyDevices))
        camLog.info("CMIO devices: \(all.map { Self.string($0, UInt32(kCMIODevicePropertyDeviceUID)) ?? "?" }.joined(separator: ", "), privacy: .public)")
        for d in all where Self.string(d, UInt32(kCMIODevicePropertyDeviceUID)) == VirtualCamera.deviceUID {
            // Direction is seen from the device, as in CoreAudio: the camera picture apps read is "input" (1),
            // and the extension's sink — data going out of the Mac into the device — is "output" (0).
            for s in Self.ids(d, UInt32(kCMIODevicePropertyStreams)) {
                var addr = Self.address(UInt32(kCMIOStreamPropertyDirection))
                var dir: UInt32 = 99, used: UInt32 = 0
                if CMIOObjectGetPropertyData(s, &addr, 0, nil, 4, &used, &dir) == 0, dir == 0 { device = d; sinkStream = s }
            }
            camLog.info("sink stream \(self.sinkStream) on device \(d)")
        }
        return device != 0
    }

    /// True while some app reads the camera (the extension publishes this as a custom property).
    func sourceRunning() -> Bool {
        guard device != 0 else { return false }
        let v = Self.string(device, VirtualCamera.sourceRunningSelector)
        if v == nil { device = 0 }   // extension went away (e.g. updated); look it up again
        return v == "1"
    }

    func startSink() -> Bool {
        guard device != 0, !running else { return running }
        var q: Unmanaged<CMSimpleQueue>?
        let e1 = CMIOStreamCopyBufferQueue(sinkStream, { _, _, _ in }, nil, &q)
        guard e1 == 0, let q else { camLog.error("CopyBufferQueue \(e1)"); return false }
        queue = q.takeRetainedValue()
        let e2 = CMIODeviceStartStream(device, sinkStream)
        guard e2 == 0 else { camLog.error("StartStream \(e2)"); queue = nil; return false }
        running = true
        return true
    }

    func stopSink() {
        guard running else { return }
        CMIODeviceStopStream(device, sinkStream)
        queue = nil
        running = false
    }

    @discardableResult
    func enqueue(_ sb: CMSampleBuffer) -> Bool {
        guard running, let queue else { return false }
        let count = CMSimpleQueueGetCount(queue), cap = CMSimpleQueueGetCapacity(queue)
        guard count < cap else {
            failures += 1
            if failures % 60 == 1 { camLog.error("sink queue full: count=\(count) capacity=\(cap)") }
            return false
        }
        let err = CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sb).toOpaque())
        if err != 0 { failures += 1; if failures % 60 == 1 { camLog.error("enqueue error \(err)") } }
        return err == 0
    }
}
