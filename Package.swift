// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UserInteractionGovernor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GovernorCore", targets: ["GovernorCore"]),
        .library(name: "GovonerStudioCore", targets: ["GovonerStudioCore"]),
        .executable(name: "uig", targets: ["UIGCLI"]),
        .executable(name: "uigd", targets: ["UIGService"]),
        .executable(name: "uig-renderer", targets: ["UIGRenderer"]),
        .executable(name: "ui-display", targets: ["UIDisplay"]),
        .executable(name: "ui-choice", targets: ["UIChoice"]),
        .executable(name: "ui-entry", targets: ["UIEntry"]),
        .executable(name: "ui-confirm", targets: ["UIConfirm"]),
        .executable(name: "ui-file", targets: ["UIFile"]),
        .executable(name: "ui-media", targets: ["UIMedia"]),
        .executable(name: "govoner-studio", targets: ["GovonerStudio"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(name: "GovernorCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "UIGCLI", dependencies: ["GovernorCore"]),
        .executableTarget(name: "UIGService", dependencies: ["GovernorCore"]),
        .executableTarget(
            name: "UIGRenderer",
            dependencies: ["GovernorCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
            ]
        ),
        .target(name: "UIWrapperSupport", dependencies: ["GovernorCore"]),
        .target(
            name: "GovonerStudioCore",
            dependencies: ["GovernorCore"],
            path: "GovonerStudio/Sources/GovonerStudioCore"
        ),
        .executableTarget(
            name: "GovonerStudio",
            dependencies: ["GovonerStudioCore", "GovernorCore"],
            path: "GovonerStudio/Sources/GovonerStudio",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(name: "UIDisplay", dependencies: ["UIWrapperSupport"]),
        .executableTarget(name: "UIChoice", dependencies: ["UIWrapperSupport"]),
        .executableTarget(name: "UIEntry", dependencies: ["UIWrapperSupport"]),
        .executableTarget(name: "UIConfirm", dependencies: ["UIWrapperSupport"]),
        .executableTarget(name: "UIFile", dependencies: ["UIWrapperSupport"]),
        .executableTarget(name: "UIMedia", dependencies: ["UIWrapperSupport"]),
        .testTarget(name: "GovernorCoreTests", dependencies: ["GovernorCore"]),
        .testTarget(
            name: "GovonerStudioCoreTests",
            dependencies: ["GovonerStudioCore", "GovernorCore"],
            path: "GovonerStudio/Tests/GovonerStudioCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
