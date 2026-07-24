// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SecondScreenHost",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CGVirtualDisplayBridge",
            path: "mac-host/Sources/CGVirtualDisplayBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOSurface"),
            ]
        ),
        .executableTarget(
            name: "SecondScreenHost",
            dependencies: ["CGVirtualDisplayBridge"],
            path: "mac-host/Sources/SecondScreenHost",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
