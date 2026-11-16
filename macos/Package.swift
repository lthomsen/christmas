// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "JuleHygge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "JuleHygge", path: "Sources/JuleHygge")
    ]
)
