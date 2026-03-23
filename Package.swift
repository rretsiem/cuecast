// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "cuecast",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "cuecast",
            targets: ["cuecast"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "cuecast"
        ),
    ]
)
