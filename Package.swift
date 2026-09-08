// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Alcove",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Alcove", targets: ["Alcove"])
    ],
    targets: [
        .executableTarget(
            name: "Alcove",
            path: "Sources/Alcove",
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
            name: "AlcoveTests",
            dependencies: ["Alcove"],
            path: "Tests/AlcoveTests"
        )
    ]
)