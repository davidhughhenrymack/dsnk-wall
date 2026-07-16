// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DSNKWall",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "DSNKWall",
            path: "Sources/DSNKWall",
            resources: [
                .copy("Resources/Shaders.metal")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("QuartzCore")
            ]
        )
    ]
)
