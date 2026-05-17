// Clawdmeter Linux headless daemon entry point.
//
// Phase 0 stub: prints version + exits 0 so Phase 0 acceptance gate
// (`swift build && swift run clawdmeterd --version`) is satisfied.
//
// Phase 3 replaces this with the Hummingbird HTTP+WS server bound to
// ports 21731/21732, peer-filter middleware, bearer-auth middleware,
// and the shared daemon route handlers.

import Foundation

@main
struct ClawdmeterDaemon {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--version") {
            print("clawdmeterd 0.4.0-dev (Phase 0 skeleton)")
            return
        }
        if args.contains("--help") || args.contains("-h") {
            print("""
            clawdmeterd — Clawdmeter Linux daemon

            Usage: clawdmeterd [options]

            Options:
              --version       Print version and exit
              --headless      Run without tray (default in server installs)
              --with-tray     Run with system tray (default in desktop AppImage)
              -h, --help      Show this help

            Phase 0 skeleton — Hummingbird transport not yet wired.
            """)
            return
        }
        print("clawdmeterd: Phase 0 skeleton — daemon not yet implemented.")
        print("Run with --version or --help.")
    }
}
