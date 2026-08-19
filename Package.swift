// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Spacewalker",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SpacewalkerApp", targets: ["SpacewalkerApp"]),
    ],
    targets: [
        // Isolation layer for private SkyLight/CGS symbols. Everything above depends only on its
        // public Swift API, never on the raw symbols — so an OS change touches one target.
        .target(name: "CGSPrivate"),

        // Pure domain logic: space identity, metadata, reconciliation, persistence.
        // Depends on CGSPrivate only for its pure value types (RawSpace/RawDisplay) — never touches
        // a private symbol, so it stays fully unit-testable without a WindowServer.
        .target(name: "SpaceModel", dependencies: ["CGSPrivate"]),

        // Space switching: pure step planner + System Events key synthesis (the only path macOS
        // honors — native CGEvent is filtered; see PLAN.md §1).
        .target(name: "SpaceSwitching", dependencies: ["SpaceModel"]),

        // Observes the live system, reconciles against the store, publishes current state.
        .target(name: "SpaceService", dependencies: ["CGSPrivate", "SpaceModel", "SpaceSwitching"]),

        // AppKit menu-bar app (LSUIElement). Thin — wiring + UI only.
        .executableTarget(
            name: "SpacewalkerApp",
            dependencies: ["CGSPrivate", "SpaceModel", "SpaceService", "SpaceSwitching"]
        ),

        .testTarget(name: "CGSPrivateTests", dependencies: ["CGSPrivate"]),
        .testTarget(name: "SpaceModelTests", dependencies: ["SpaceModel"]),
        .testTarget(name: "SpaceSwitchingTests", dependencies: ["SpaceSwitching"]),
        .testTarget(
            name: "SpaceServiceTests",
            dependencies: ["SpaceService", "SpaceModel", "SpaceSwitching", "CGSPrivate"]
        ),
        .testTarget(name: "SpacewalkerAppTests", dependencies: ["SpacewalkerApp"]),
    ]
)
