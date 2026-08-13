// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IPBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "IPBar",
            path: "Sources/IPBar",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IPBarTests",
            dependencies: ["IPBar"],
            path: "Tests/IPBarTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
