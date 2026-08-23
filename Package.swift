// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sideband",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CIOAVService"),
        .executableTarget(
            name: "Sideband",
            dependencies: ["CIOAVService"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
    ]
)
