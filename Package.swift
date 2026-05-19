// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Denebula",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Denebula", targets: ["Denebula"])
    ],
    targets: [
        .executableTarget(
            name: "Denebula",
            path: "Sources/Denebula"
        )
    ]
)
