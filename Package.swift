// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kadran",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CIOAVService"),
        .executableTarget(
            name: "Kadran",
            dependencies: ["CIOAVService"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
    ]
)
