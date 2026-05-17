// Clawdmeter Linux desktop app entry point.
//
// Phase 0 stub: prints version + exits 0. Phase 3.5 / 4 replace this
// with the SwiftCrossUI App + tray + dashboard windows.

import Foundation

@main
struct ClawdmeterLinux {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--version") {
            print("clawdmeter (Linux desktop) 0.4.0-dev (Phase 0 skeleton)")
            return
        }
        print("clawdmeter: Phase 0 skeleton — desktop app not yet implemented.")
        print("Run with --version.")
    }
}
