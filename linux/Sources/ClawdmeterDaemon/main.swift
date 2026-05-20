// Clawdmeter Linux headless daemon entry point.
//
// P1-Linux-4: previously this main just printed "Phase 0 skeleton" and
// exited 0, so the installed systemd service started, immediately
// exited successfully, and stayed in "active (exited)" state forever —
// no HTTP listener, no pairing, no /health. Wire the HummingbirdTransport
// entrypoint here so when the Phase 3 implementation lands, the daemon
// genuinely runs. Today the transport itself is still a Phase 3 stub
// (its start() body sleeps then returns); pairing it with the daemon
// loop means flipping a single TODO inside HummingbirdTransport will
// make the whole binary functional with no extra changes here.

import Foundation

@main
struct ClawdmeterDaemon {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--version") {
            print("clawdmeterd 0.7.0 (Phase 0 skeleton)")
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

        // P1-Linux-4 + Codex follow-up: the Phase 0 daemon doesn't
        // actually run a server — HummingbirdTransport lives in the
        // ClawdmeterLinux library and its body is a Phase 3 TODO that
        // returns immediately. Importing ClawdmeterLinux here would
        // make the daemon depend on an executable target with its own
        // @main entry point (which the Linux package rejects), and
        // wiring a no-op transport would still exit 0.
        //
        // Fail loud instead so systemd's `Restart=on-failure` actually
        // triggers and the operator sees the unimplemented state.
        // CLAWDMETER_DAEMON_ALLOW_STUB=1 preserves the legacy exit-0
        // behaviour for local development. Phase 3 will introduce a
        // proper `ClawdmeterDaemonCore` library that both this binary
        // and the desktop app can link against.
        if ProcessInfo.processInfo.environment["CLAWDMETER_DAEMON_ALLOW_STUB"] == "1" {
            print("clawdmeterd: Phase 0 skeleton — daemon not yet implemented.")
            print("Run with --version or --help.")
            return
        }
        FileHandle.standardError.write(Data("clawdmeterd: Phase 0 skeleton — Hummingbird transport not yet wired. Exiting non-zero so systemd restarts. Set CLAWDMETER_DAEMON_ALLOW_STUB=1 to keep the legacy exit-0 behaviour.\n".utf8))
        exit(2)
    }
}
