// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dosa",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Fork of nodes-app/swift-markdown-engine, branched off its 0.9.0 tag and
        // carrying two embedder seams the editor needs (`decorate` for the AI-diff
        // tint, drag interception for audio/video imports); both are up for
        // upstreaming. Pinned by revision because the engine is pre-1.0 and its
        // public API may move between minor versions.
        .package(
            url: "https://github.com/kvelury/swift-markdown-engine",
            revision: "fcf4d1d7157d01aeb94c8e1359bb06af5ae2bcd1"
        )
    ],
    targets: [
        .target(
            name: "DosaKit",
            dependencies: [
                .product(name: "MarkdownEngine", package: "swift-markdown-engine")
            ],
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
