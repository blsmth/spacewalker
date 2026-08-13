// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpaceSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SpaceSpike",
            path: "Sources/SpaceSpike"
        ),
        .executableTarget(
            name: "SpaceSwitch",
            path: "Sources/SpaceSwitch"
        ),
        .executableTarget(
            name: "KeySynthTest",
            path: "Sources/KeySynthTest"
        ),
        .executableTarget(
            name: "CurrentSpace",
            path: "Sources/CurrentSpace"
        )
    ]
)
