import CoreMediaIO
import Foundation

// "JuleHygge Kamera": a CoreMediaIO camera extension. It is only a pipe — the JuleHygge app composes the
// picture (the user in front of the Christmas scene) and sends it to this extension's sink stream, which is
// forwarded to the source stream that Teams and other apps read.
let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
