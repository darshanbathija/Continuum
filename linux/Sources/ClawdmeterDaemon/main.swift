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
import ClawdmeterShared
import ClawdmeterLinux

@main
struct ClawdmeterDaemon {
    static func main() async {
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

            Daemon transport: HummingbirdTransport (HTTP 21731 / WS 21732,
            bearer-auth + peer-filter middleware). See
            linux/Sources/ClawdmeterLinux/Transport/HummingbirdTransport.swift.
            """)
            return
        }

        // Construct the bearer-token store + transport. Headless and
        // with-tray differ only in whether the tray poll loop runs alongside
        // the listener; both modes need the HTTP/WS server.
        let bearerStore = LinuxPairingTokenStore.shared
        let transport = HummingbirdTransport(
            configuration: HummingbirdTransport.Configuration(),
            bearerStore: bearerStore
        )

        do {
            try await transport.start()
        } catch {
            FileHandle.standardError.write(Data("clawdmeterd: transport start failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
