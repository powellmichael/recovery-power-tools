// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "FileRecovery",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FileRecovery", targets: ["FileRecoveryApp"]),
        .executable(name: "LicenseTool", targets: ["LicenseTool"])
    ],
    targets: [
        // Licence format and verification, shared by the app (verify) and
        // the seller's tool (issue) so the two cannot drift apart.
        .target(name: "LicenseKit", path: "Sources/LicenseKit"),
        .executableTarget(
            name: "FileRecoveryApp",
            dependencies: ["LicenseKit"],
            path: "Sources/FileRecoveryApp"
        ),
        // Never shipped: generates the signing key and issues licence keys.
        .executableTarget(
            name: "LicenseTool",
            dependencies: ["LicenseKit"],
            path: "Sources/LicenseTool"
        ),
        .testTarget(
            name: "FileRecoveryAppTests",
            dependencies: ["FileRecoveryApp", "LicenseKit"],
            path: "Tests/FileRecoveryAppTests"
        )
    ]
)
