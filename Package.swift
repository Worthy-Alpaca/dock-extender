// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockExtender",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DockExtender",
            path: "Sources/DockExtender"
        )
    ]
)
