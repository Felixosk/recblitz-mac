// swift-tools-version:5.9
import PackageDescription

// RecBlitz plus its recording engine BlitzKit (screen capture, region picker,
// countdown, control bar, webcam bubble) as a second target in the same
// package, so a fresh clone builds without any sibling checkout.
let package = Package(
    name: "RecBlitz",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BlitzKit", path: "Sources/BlitzKit"),
        .executableTarget(
            name: "RecBlitz",
            dependencies: ["BlitzKit"],
            path: "Sources/RecBlitz"
        )
    ]
)
