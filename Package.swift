// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ShengJi",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "ShengJi", targets: ["WhisperMetal"])
    ],
    targets: [
        .executableTarget(
            name: "WhisperMetal",
            path: "Sources/WhisperMetal"
        )
    ]
)
