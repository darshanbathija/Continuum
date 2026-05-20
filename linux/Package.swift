// swift-tools-version: 6.0
// Clawdmeter Linux desktop port — daemon + dashboard + sessions IDE.
//
// Targets Ubuntu 24.04+ / ZorinOS 17+. Linux-only platform; this package
// does not build on macOS (use apple/Clawdmeter.xcodeproj there).
//
// Phase 0 state: skeleton with hello-world executables. The real
// HummingbirdTransport / SwiftCrossUI dependencies land in Phase 3 / 3.5.

import PackageDescription

let package = Package(
    name: "clawdmeter-linux",
    platforms: [
        // Linux has no version qualifier in SPM; macOS guard keeps `swift build`
        // from being tried accidentally on a Mac dev machine.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "clawdmeterd", targets: ["ClawdmeterDaemon"]),
        .executable(name: "clawdmeter", targets: ["ClawdmeterLinux"])
    ],
    dependencies: [
        // Shared analytics + daemon route handlers live in the sibling apple/ package.
        // The path is intentional: same git tree, one shared module.
        .package(path: "../apple/ClawdmeterShared")
    ],
    targets: [
        .executableTarget(
            name: "ClawdmeterDaemon",
            dependencies: [
                .product(name: "ClawdmeterShared", package: "ClawdmeterShared")
            ],
            path: "Sources/ClawdmeterDaemon"
        ),
        .executableTarget(
            name: "ClawdmeterLinux",
            dependencies: [
                .product(name: "ClawdmeterShared", package: "ClawdmeterShared")
            ],
            path: "Sources/ClawdmeterLinux"
        ),
        .testTarget(
            name: "ClawdmeterLinuxTests",
            dependencies: ["ClawdmeterLinux"],
            path: "Tests/ClawdmeterLinuxTests"
        )
    ]
)
