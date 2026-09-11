// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Halo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Halo", targets: ["Halo"])
    ],
    targets: [
        .executableTarget(
            name: "Halo",
            path: "Sources/Halo",
            exclude: ["Resources/Info.plist"],
            resources: [
                .copy("Resources/Info.plist")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreLocation")
            ]
        ),
        .testTarget(
            name: "HaloTests",
            dependencies: ["Halo"],
            path: "Tests/HaloTests"
        )
    ]
)