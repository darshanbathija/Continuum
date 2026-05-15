// swift-tools-version: 5.10
//
// tmux-cc-probe — Phase 0 validation harness for the Sessions feature.
//
// Throwaway tool whose only job is to prove the tmux control-mode (`-CC`)
// parser handles the 6 cases the eng review flagged before any of Phase 1+
// in the main app depends on it. The `TmuxControlMode` library target here
// is reusable Swift code; Phase 2 lifts it into ClawdmeterMac as
// `TmuxControlClient.swift`.
//
// Not part of the Xcode project; build + run with `swift run` from this dir.

import PackageDescription

let package = Package(
    name: "tmux-cc-probe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TmuxControlMode", targets: ["TmuxControlMode"]),
        .executable(name: "tmux-cc-probe", targets: ["tmux-cc-probe"]),
    ],
    targets: [
        // Reusable control-mode parser. Phase 2 (TmuxControlClient.swift) lifts
        // this verbatim into the main app.
        .target(name: "TmuxControlMode"),

        // Probe runner: spawns tmux -CC -L probe and exercises the 6 criteria.
        .executableTarget(
            name: "tmux-cc-probe",
            dependencies: ["TmuxControlMode"]
        ),

        // Hermetic tests for the parser (no tmux dependency — feeds raw frame
        // bytes directly). Phase 0 pass gate.
        .testTarget(
            name: "TmuxControlModeTests",
            dependencies: ["TmuxControlMode"]
        ),
    ]
)
