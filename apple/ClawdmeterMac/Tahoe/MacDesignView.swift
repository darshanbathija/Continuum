// MacDesignView — the Design tab's body on macOS.
//
// Loads http://127.0.0.1:<openDesignDaemon.port>/ in a WKWebView when
// the daemon is ready, with Tahoe-styled loading / error states.
//
// The Mac WebView talks loopback directly (the daemon's
// isLoopbackPeerAddress check waives OD_API_TOKEN for loopback peers).
// iOS goes through DesignPortForwarder + OD_API_TOKEN; MacDesignView
// has the cleaner shortcut.
//
// Injects a WKUserScript that exposes window.clawdmeter.openInCode(...)
// + window.webkit.messageHandlers.clawdmeter for the bundled
// clawdmeter-bridge plugin to call. WKScriptMessageHandler routes
// {type: "open-in-code"} payloads back to onOpenInCode() so the parent
// MacRootView can flip tabs.
//
// Plan ref: v2.1 phases 3, 4, 7.

import SwiftUI
import WebKit
import OSLog
#if canImport(ClawdmeterShared)
import ClawdmeterShared
#endif

private let designLogger = Logger(subsystem: "com.clawdmeter.mac", category: "MacDesignView")

struct MacDesignView: View {
    @ObservedObject var daemon: OpenDesignDaemonManager
    /// Called when the bundled clawdmeter-bridge plugin's "Open in
    /// Code →" button is clicked inside the Design WebView. The
    /// MacRootView parent flips its Tab enum to `.code` and pre-selects
    /// the repo via SessionsModel.
    var onOpenInCode: (_ repoKey: String?) -> Void

    var body: some View {
        ZStack {
            switch daemon.lifecycle {
            case .idle, .starting, .loading, .restarting:
                ColdStartCard(status: daemon.lifecycleStatus)
            case .failed, .crashed:
                ErrorCard(
                    message: daemon.lastError ?? "Open Design daemon unavailable",
                    onRetry: { daemon.ensureRunning() }
                )
            case .ready:
                if let port = daemon.daemonPort {
                    DesignWebViewHost(
                        url: URL(string: "http://127.0.0.1:\(port)/")!,
                        onOpenInCode: onOpenInCode
                    )
                } else {
                    ColdStartCard(status: "Waiting for port…")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { daemon.ensureRunning() }
    }
}

// MARK: - Cold start card (D3)

private struct ColdStartCard: View {
    let status: String
    @State private var pulse: Double = 1.0

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Color(.sRGB, red: 0.86, green: 0.40, blue: 0.74)) // Tahoe bloom approximation
                .opacity(pulse)
                .onAppear {
                    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    guard !reduceMotion else { pulse = 1.0; return }
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        pulse = 0.55
                    }
                }
            Text("Waking up Design…")
                .font(.system(size: 15, weight: .semibold))
            Text(status)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .animation(.easeInOut(duration: 0.2), value: status)
                .frame(maxWidth: 320)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
    }
}

// MARK: - Error card

private struct ErrorCard: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Design unavailable")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
                .multilineTextAlignment(.center)
            Button("Restart daemon", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
    }
}

// MARK: - WebView host

private struct DesignWebViewHost: NSViewRepresentable {
    let url: URL
    let onOpenInCode: (_ repoKey: String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpenInCode: onOpenInCode) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "clawdmeter")
        // Bridge object exposed inside the WebView so the bundled plugin
        // can call window.clawdmeter.openInCode(repoKey) and read
        // window.clawdmeter.activeRepo. The plugin posts back via
        // window.webkit.messageHandlers.clawdmeter.
        let bridgeJS = """
        window.clawdmeter = window.clawdmeter || {};
        window.clawdmeter.openInCode = function(repoKey) {
          window.webkit.messageHandlers.clawdmeter.postMessage({type: 'open-in-code', repoKey: repoKey || null});
        };
        window.clawdmeter.activeRepo = null;
        """
        userContent.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onOpenInCode: (_ repoKey: String?) -> Void
        init(onOpenInCode: @escaping (_ repoKey: String?) -> Void) {
            self.onOpenInCode = onOpenInCode
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "clawdmeter",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "open-in-code":
                let repoKey = body["repoKey"] as? String
                Task { @MainActor in self.onOpenInCode(repoKey) }
            default:
                designLogger.warning("unknown clawdmeter bridge message: \(type, privacy: .public)")
            }
        }
    }
}
