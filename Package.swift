// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "FileRecovery",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FileRecovery", targets: ["FileRecoveryApp"])
    ],
    targets: [
        .executableTarget(
            name: "FileRecoveryApp",
            path: "Sources/FileRecoveryApp"
        ),
        .testTarget(
            name: "FileRecoveryAppTests",
            dependencies: ["FileRecoveryApp"],
            path: "Tests/FileRecoveryAppTests"
        )
    ]
)
