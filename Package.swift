// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hangar",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HangarApp", targets: ["HangarApp"])],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework"),
        .target(name: "Workspace"),
        .target(name: "AgentStatus"),
        .target(name: "ControlServer", dependencies: ["AgentStatus"]),
        .target(name: "Exec", dependencies: ["Workspace"]),
        .target(name: "Usage", dependencies: ["ControlServer", "Exec"]),
        .target(name: "Git", dependencies: ["Exec"]),
        .target(name: "Integration", dependencies: ["Exec"]),
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
        .target(name: "HangarUI", dependencies: ["Workspace", "Exec", "Git", "GhosttyBridge"], resources: [.process("Resources")]),
        .executableTarget(name: "hangar", dependencies: ["ControlServer"]),
        .executableTarget(name: "HangarApp", dependencies: ["HangarUI", "GhosttyBridge", "Workspace"]),
        .testTarget(name: "WorkspaceTests", dependencies: ["Workspace"]),
        .testTarget(name: "ExecTests", dependencies: ["Exec", "Workspace"]),
        .testTarget(name: "AgentStatusTests", dependencies: ["AgentStatus"]),
        .testTarget(name: "ControlServerTests", dependencies: ["ControlServer", "AgentStatus"]),
        .testTarget(name: "HangarCLITests", dependencies: ["hangar", "ControlServer", "AgentStatus"]),
        .testTarget(name: "UsageTests", dependencies: ["Usage", "ControlServer", "Exec"]),
        .testTarget(name: "GitTests", dependencies: ["Git", "Exec"]),
        .testTarget(name: "IntegrationTests", dependencies: ["Integration", "Exec"]),
        .testTarget(name: "HangarUITests", dependencies: ["HangarUI", "Git"]),
    ]
)
