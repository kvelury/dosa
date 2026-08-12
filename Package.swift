// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dosa",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dosa",
            path: "Sources/Dosa"
        )
    ]
)
