// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dosa",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DosaKit",
            path: "Sources/Dosa"
        ),
        .executableTarget(
            name: "Dosa",
            dependencies: ["DosaKit"],
            path: "Sources/DosaApp"
        ),
        .executableTarget(
            name: "DosaCalendarChecks",
            dependencies: ["DosaKit"],
            path: "Sources/DosaCalendarChecks"
        )
    ]
)
