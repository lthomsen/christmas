// Opens "JuleHygge Kamera" like Teams would and saves a frame after N seconds.
// Usage: swift tools/kamera-test.swift <out.png> [seconds]
import AVFoundation
import CoreImage
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "kamera.png"
let wait = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 8 : 8
guard let dev = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        .devices.first(where: { $0.localizedName == "JuleHygge Kamera" }) else { print("JuleHygge Kamera ikke fundet"); exit(1) }

final class Grab: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var last: CVPixelBuffer?
    var frames = 0
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        frames += 1
        last = CMSampleBufferGetImageBuffer(sb)
    }
}
let grab = Grab()
let s = AVCaptureSession()
s.addInput(try! AVCaptureDeviceInput(device: dev))
let o = AVCaptureVideoDataOutput()
o.setSampleBufferDelegate(grab, queue: DispatchQueue(label: "g"))
s.addOutput(o)
s.startRunning()
Thread.sleep(forTimeInterval: wait)
s.stopRunning()
print("billeder modtaget: \(grab.frames) (~\(Int(Double(grab.frames) / wait)) pr. sekund)")
if let pb = grab.last, let cg = CIContext().createCGImage(CIImage(cvPixelBuffer: pb), from: CIImage(cvPixelBuffer: pb).extent) {
    try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("gemt: \(out)")
}
