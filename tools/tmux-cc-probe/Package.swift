// swift-tools-version: 5.10
//
// tmux-cc-probe — Phase 0 validation harness for the Sessions feature.
//
// Probe tool whose job is to keep the tmux control-mode (`-CC`) parser behavior
// aligned with the app parser while exercising the cases the eng review flagged.
//
// Not part of the Xcode project; build + run with `swift run` from this dir.

import PackageDescription

let package = Package(
    name: "tmux-cc-probe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tmux-cc-probe", targets: ["tmux-cc-probe"]),
    ],
    dependencies: [
        .package(path: "../tmux-control-mode-core"),
    ],
    targets: [
        // Probe runner: spawns tmux -CC -L probe and exercises the 6 criteria.
        .executableTarget(
            name: "tmux-cc-probe",
            dependencies: [
                .product(name: "TmuxControlMode", package: "tmux-control-mode-core"),
            ]
        ),

        // Hermetic tests for the parser (no tmux dependency — feeds raw frame
        // bytes directly). Phase 0 pass gate.
        .testTarget(
            name: "TmuxControlModeTests",
            dependencies: [
                .product(name: "TmuxControlMode", package: "tmux-control-mode-core"),
            ]
        ),
    ]
)
