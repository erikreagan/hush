// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS(.v15)],
    targets: [
        // DeepFilterNet's C API. Run scripts/build-dfn.sh first: it produces build/dfn/libdf.a.
        .target(name: "CDeepFilter", path: "Packages/CDeepFilter",
                linkerSettings: [.unsafeFlags(["-Lbuild/dfn"]), .linkedLibrary("df")]),
        .target(name: "HushAudio", dependencies: ["CDeepFilter"], path: "Packages/HushAudio"),
        .executableTarget(name: "Hush", dependencies: ["HushAudio"], path: "App", exclude: ["Info.plist"]),
        .executableTarget(name: "hush-cli", dependencies: ["HushAudio"], path: "Tools/hush-cli"),
        .testTarget(name: "HushAudioTests", dependencies: ["HushAudio"], path: "Tests"),
    ]
)
