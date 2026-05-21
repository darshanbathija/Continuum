// IOSDesignView — the Design tab on iOS.
//
// Loads the paired Mac's Open Design daemon via DesignPortForwarder over
// Tailscale. The initial WKWebView request carries `?token=<designToken>`
// for the bootstrap handshake; the forwarder strips the query before
// proxying to the daemon and injects a Set-Cookie response so subsequent
// subresource fetches (and WebSocket upgrades) preserve auth via
// WKHTTPCookieStore.
//
// Empty-state when the device hasn't paired or pairing didn't include a
// designToken (Mac on an older version) — shows a Tahoe pairing CTA
// matching the existing IOSCodeView empty-state.
//
// Plan ref: v2.1 phases 6, 8.

import SwiftUI
import WebKit
import ClawdmeterShared

struct IOSDesignView: View {
    @ObservedObject var agentClient: AgentControlClient
    /// /review I2: optional handoff callback for Design→Code. IOSRootView
    /// passes a closure that flips its `@State tab` to `.code`. Nil keeps
    /// the view backward-compatible if a caller doesn't wire it.
    var onOpenInCode: ((_ repoKey: String?) -> Void)?

    var body: some View {
        if let host = agentClient.host, let token = agentClient.designToken {
            DesignWebView(host: host, port: agentClient.designPort, token: token, onOpenInCode: { repoKey in
                onOpenInCode?(repoKey)
            })
            .ignoresSafeArea()
        } else {
            UnpairedEmptyState()
        }
    }
}

// MARK: - WKWebView wrapper

private struct DesignWebView: UIViewRepresentable {
    let host: String
    let port: Int
    let token: String
    let onOpenInCode: (_ repoKey: String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpenInCode: onOpenInCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "clawdmeter")
        // Same bridge object as MacDesignView so the bundled
        // clawdmeter-bridge plugin renders identically across platforms.
        let bridgeJS = """
        window.clawdmeter = window.clawdmeter || {};
        window.clawdmeter.openInCode = function(repoKey) {
          window.webkit.messageHandlers.clawdmeter.postMessage({type: 'open-in-code', repoKey: repoKey || null});
        };
        window.clawdmeter.activeRepo = null;
        """
        userContent.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = userContent
        // Persistent data store so WKHTTPCookieStore survives toggles.
        let webView = WKWebView(frame: .zero, configuration: config)
        let url = URL(string: "http://\(hostLiteral(host)):\(port)/?token=\(token)")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Persistent WebView — only reload if the host/port/token combo
        // actually changes (i.e., re-pair).
        let expected = URL(string: "http://\(hostLiteral(host)):\(port)/?token=\(token)")
        if let current = uiView.url, let expected, !current.absoluteString.hasPrefix("http://\(hostLiteral(host)):\(port)/") {
            uiView.load(URLRequest(url: expected))
        }
    }

    private func hostLiteral(_ h: String) -> String {
        // Tailscale IPv6 hostnames in the pairing QR may arrive bare —
        // wrap them in brackets so the URL parser accepts them.
        if h.contains(":") && !h.hasPrefix("[") {
            return "[\(h)]"
        }
        return h
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onOpenInCode: (_ repoKey: String?) -> Void
        init(onOpenInCode: @escaping (_ repoKey: String?) -> Void) {
            self.onOpenInCode = onOpenInCode
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "clawdmeter",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String, type == "open-in-code" else { return }
            let repoKey = body["repoKey"] as? String
            Task { @MainActor in self.onOpenInCode(repoKey) }
        }
    }
}

// MARK: - Empty state

private struct UnpairedEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pencil.and.ruler")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Pair with your Mac to use Design")
                .font(.system(size: 16, weight: .semibold))
            Text("Design runs on your Mac. Pair this iPhone in Settings to mirror the canvas here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
