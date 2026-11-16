import CoreGraphics
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os

let extLog = Logger(subsystem: "dk.julehygge.JuleHygge.Camera", category: "extension")

let cameraWidth: Int32 = 1280, cameraHeight: Int32 = 720, cameraFps: Int32 = 30
/// Must match VirtualCamera.deviceUID in the app.
let cameraDeviceUID = "dk.julehygge.JuleHygge.Camera.device"
/// Custom property the app polls: "1" while some app reads the camera. Format: 4cc_<selector>_<scope>_<element>.
let sourceRunningProperty = CMIOExtensionProperty(rawValue: "4cc_jhsr_glob_0000")

// MARK: - Provider

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: "JuleHygge Kamera")
        do { try provider.addDevice(deviceSource.device) } catch { fatalError("addDevice: \(error)") }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "JuleHygge" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: StreamSource!
    private var sinkStream: SinkSource!
    private(set) var videoFormat: CMFormatDescription!
    private var sourceRunning = false, sinkRunning = false
    private var sinkClient: CMIOExtensionClient?
    private let queue = DispatchQueue(label: "dk.julehygge.camera.extension")
    private var placeholderTimer: DispatchSourceTimer?
    private var lastSinkFrame: UInt64 = 0
    private var placeholder: CVPixelBuffer?
    private var consumed = 0

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: UUID(uuidString: "6A3F2C1E-7B4D-4E8A-9C21-5D0B7E3A9F10")!,
                                     legacyDeviceID: cameraDeviceUID, source: self)
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: cameraWidth, height: cameraHeight, extensions: nil, formatDescriptionOut: &videoFormat)
        let format = CMIOExtensionStreamFormat(formatDescription: videoFormat, maxFrameDuration: CMTime(value: 1, timescale: cameraFps),
                                               minFrameDuration: CMTime(value: 1, timescale: cameraFps), validFrameDurations: nil)
        sourceStream = StreamSource(localizedName: "JuleHygge Kamera", direction: .source, format: format, device: self)
        sinkStream = SinkSource(localizedName: "JuleHygge Kamera (indgang)", format: format, device: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch { fatalError("addStream: \(error)") }
        placeholder = Self.makePlaceholder()
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel, sourceRunningProperty] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = "JuleHygge Kamera" }
        if properties.contains(sourceRunningProperty) {
            p.setPropertyState(CMIOExtensionPropertyState<AnyObject>(value: (sourceRunning ? "1" : "0") as NSString), forProperty: sourceRunningProperty)
        }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: source (what Teams reads)

    func startSourceStreaming() {
        queue.async { [self] in
            sourceRunning = true
            extLog.info("source started")
            notifySourceRunning()
            // When the app is not sending (not running, or still starting the real camera), show a calm placeholder.
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / cameraFps)))
            t.setEventHandler { [weak self] in self?.sendPlaceholderIfIdle() }
            t.resume()
            placeholderTimer = t
        }
    }

    func stopSourceStreaming() {
        queue.async { [self] in
            sourceRunning = false
            placeholderTimer?.cancel()
            placeholderTimer = nil
            notifySourceRunning()
        }
    }

    private func notifySourceRunning() {
        device.notifyPropertiesChanged([sourceRunningProperty: CMIOExtensionPropertyState<AnyObject>(value: (sourceRunning ? "1" : "0") as NSString)])
    }

    private func sendPlaceholderIfIdle() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard sourceRunning, now - lastSinkFrame > 500_000_000, let pb = placeholder else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: cameraFps),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: videoFormat,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb { sourceStream.stream.send(sb, discontinuity: [], hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * 1e9)) }
    }

    // MARK: sink (what the JuleHygge app sends)

    func authorizeSink(_ client: CMIOExtensionClient) { sinkClient = client; extLog.info("sink authorized for client pid \(client.pid)") }

    func startSinkStreaming() {
        queue.async { [self] in
            sinkRunning = true
            extLog.info("sink started, client=\(self.sinkClient != nil)")
            if let c = sinkClient { consume(from: c) }
        }
    }

    func stopSinkStreaming() { queue.async { [self] in sinkRunning = false } }

    private func consume(from client: CMIOExtensionClient) {
        guard sinkRunning else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, seq, _, hasMore, err in
            guard let self else { return }
            self.consumed += 1
            if self.consumed % 120 == 1 { extLog.info("consume #\(self.consumed): buffer=\(sbuf != nil) err=\(String(describing: err), privacy: .public) source=\(self.sourceRunning)") }
            self.queue.async {
                if let sbuf {
                    self.lastSinkFrame = DispatchTime.now().uptimeNanoseconds
                    if self.sourceRunning {
                        self.sourceStream.stream.send(sbuf, discontinuity: [],
                                                      hostTimeInNanoseconds: UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1e9))
                    }
                    let out = CMIOExtensionScheduledOutput(sequenceNumber: seq,
                                                           hostTimeInNanoseconds: UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1e9))
                    self.sinkStream.stream.notifyScheduledOutputChanged(out)
                    self.consume(from: client)
                } else {
                    // nothing queued yet: ask again shortly
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(hasMore ? 0 : 5)) { self.consume(from: client) }
                }
            }
        }
    }

    /// Dark winter blue with a soft snowflake, shown until the app's pictures arrive.
    private static func makePlaceholder() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(cameraWidth), Int(cameraHeight), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(cameraWidth), height: Int(cameraHeight),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return pb }
        let w = CGFloat(cameraWidth), h = CGFloat(cameraHeight)
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [CGColor(red: 0.06, green: 0.1, blue: 0.19, alpha: 1), CGColor(red: 0.2, green: 0.3, blue: 0.47, alpha: 1)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.setLineWidth(10)
        ctx.setLineCap(.round)
        let cx = w / 2, cy = h / 2, r: CGFloat = 70
        for i in 0..<3 {
            let a = CGFloat(i) * .pi / 3 + .pi / 2
            ctx.move(to: CGPoint(x: cx - cos(a) * r, y: cy - sin(a) * r))
            ctx.addLine(to: CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
        }
        ctx.strokePath()
        return pb
    }
}

// MARK: - Streams

final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: DeviceSource

    init(localizedName: String, direction: CMIOExtensionStream.Direction, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: UUID(uuidString: "1C7E9A42-3F6B-4D18-B0A5-8E2C4F6D1A33")!,
                                     direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: cameraFps) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { device.startSourceStreaming() }
    func stopStream() throws { device.stopSourceStreaming() }
}

final class SinkSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: DeviceSource

    init(localizedName: String, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: UUID(uuidString: "9B4D6E21-A8C3-4F57-8D19-2E7A5C3B6F48")!,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
         .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: cameraFps) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 2 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        device.authorizeSink(client)
        return true
    }

    func startStream() throws { device.startSinkStreaming() }
    func stopStream() throws { device.stopSinkStreaming() }
}
