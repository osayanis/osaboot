// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OsaBoot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OsaBoot",
            path: "Sources/OsaBoot",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
