// Posts the screen saver's start/stop notifications, to test that Santa and the plow stop:
//   swift tools/pauseskaerm-signal.swift start|stop
import Foundation
let what = CommandLine.arguments.dropFirst().first ?? "start"
DistributedNotificationCenter.default().postNotificationName(.init("com.apple.screensaver.did" + what), object: nil, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
print("sendt com.apple.screensaver.did" + what)
