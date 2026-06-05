// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MikuExplains",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MikuExplains", targets: ["MikuExplains"])
    ],
    targets: [
        .executableTarget(
            name: "MikuExplains",
            path: "Sources/MikuExplains"
        )
    ]
)
