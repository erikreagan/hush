// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "HushAudio", path: "Packages/HushAudio"),
        .executableTarget(name: "Hush", dependencies: ["HushAudio"], path: "App", exclude: ["Info.plist"]),
        .testTarget(name: "HushAudioTests", dependencies: ["HushAudio"], path: "Tests"),
    ]
)
