// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "tmux-control-mode-core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TmuxControlMode", targets: ["TmuxControlMode"]),
    ],
    targets: [
        .target(name: "TmuxControlMode"),
    ]
)
