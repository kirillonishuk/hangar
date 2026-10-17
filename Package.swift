// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hangar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HangarApp", targets: ["HangarApp"])],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework"),
        .target(name: "Workspace"),
        .target(name: "Exec", dependencies: ["Workspace"]),
        .target(
            name: "GhosttyBridge",
            dependencies: ["GhosttyKit", "Exec"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .target(name: "HangarUI", dependencies: ["Workspace", "Exec", "GhosttyBridge"]),
        .executableTarget(name: "HangarApp", dependencies: ["HangarUI"]),
        .testTarget(name: "WorkspaceTests", dependencies: ["Workspace"]),
        .testTarget(name: "ExecTests", dependencies: ["Exec", "Workspace"]),
        .testTarget(name: "HangarUITests", dependencies: ["HangarUI"]),
    ]
)
