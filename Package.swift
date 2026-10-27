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
        .target(name: "Exec", dependencies: ["Workspace", "AgentStatus"]),
        .target(name: "Usage", dependencies: ["ControlServer", "Exec"]),
        .target(name: "Git", dependencies: ["Exec"]),
        .target(name: "Integration", dependencies: ["Exec"]),
        .target(name: "History", dependencies: ["Exec", "AgentStatus"]),
        .target(name: "Power", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "Update"),
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
        .target(name: "HangarUI", dependencies: ["Workspace", "Exec", "Git", "GhosttyBridge", "AgentStatus", "ControlServer", "Usage", "Integration", "Power", "History", "Update"], resources: [.process("Resources"), .copy("FileIcons"), .copy("Monaco")]),
        .executableTarget(name: "hangar", dependencies: ["ControlServer"]),
        .executableTarget(name: "HangarApp", dependencies: ["HangarUI", "GhosttyBridge", "Workspace", "ControlServer", "Exec"]),
        // Shared test helpers (waits); not shipped.
        .target(name: "TestSupport", path: "Tests/Support"),
        .testTarget(name: "WorkspaceTests", dependencies: ["Workspace"]),
        .testTarget(name: "ExecTests", dependencies: ["TestSupport", "Exec", "Workspace", "AgentStatus"]),
        .testTarget(name: "AgentStatusTests", dependencies: ["AgentStatus"]),
        .testTarget(name: "ControlServerTests", dependencies: ["TestSupport", "ControlServer", "AgentStatus"]),
        .testTarget(name: "HangarCLITests", dependencies: ["TestSupport", "hangar", "ControlServer", "AgentStatus"]),
        .testTarget(name: "UsageTests", dependencies: ["TestSupport", "Usage", "ControlServer", "Exec"]),
        .testTarget(name: "GitTests", dependencies: ["Git", "Exec"]),
        .testTarget(name: "IntegrationTests", dependencies: ["Integration", "Exec"]),
        .testTarget(name: "PowerTests", dependencies: ["TestSupport", "Power"]),
        .testTarget(name: "HistoryTests", dependencies: ["History", "Exec"]),
        .testTarget(name: "UpdateTests", dependencies: ["Update"]),
        .testTarget(name: "HangarUITests", dependencies: ["TestSupport", "HangarUI", "Integration", "Git", "AgentStatus", "ControlServer", "Usage", "Power", "History"]),
    ]
)
