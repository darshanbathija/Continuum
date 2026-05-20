import SwiftUI
import WebKit
import ClawdmeterShared
import OSLog

private let browserLogger = Logger(subsystem: "com.clawdmeter.mac", category: "InAppBrowser")

/// G13 in-app browser pane. WKWebView + minimal nav chrome. The killer
/// feature is `Cmd-Click` on any DOM element → modal dialog → injects a
/// structured `[BROWSER COMMENT @ <selector>] <text>` userMessage into
/// the session's primary tmux pane.
///
/// CSS selector resolution is done in JS: walks up the tag chain, picks
/// the most specific shortest selector (id > class.combo > nth-of-type),
/// hands it back via `WKScriptMessageHandler`.
struct InAppBrowser: View {
    let session: AgentSession
    @ObservedObject var model: SessionsModel

    @State private var urlText: String = "http://localhost:3000"
    @State private var loadedURL: URL? = URL(string: "http://localhost:3000")
    @State private var canGoBack: Bool = false
    @State private var canGoForward: Bool = false
    @State private var isLoading: Bool = false

    @State private var commentSelector: String = ""
    @State private var commentSnippet: String = ""
    @State private var commentText: String = ""
    @State private var showingCommentSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            chrome
            Divider()
            WebView(
                loadURL: loadedURL,
                onNavigationChange: { canGoBack = $0.canGoBack; canGoForward = $0.canGoForward; isLoading = $0.isLoading },
                onCommentRequested: { selector, snippet in
                    commentSelector = selector
                    commentSnippet = snippet
                    commentText = ""
                    showingCommentSheet = true
                }
            )
        }
        .sheet(isPresented: $showingCommentSheet) { commentSheet }
    }

    private var chrome: some View {
        HStack(spacing: 6) {
            Button(action: { WebViewBus.shared.goBack() }) {
                Image(systemName: "chevron.left").font(.system(size: 11))
            }
            .disabled(!canGoBack)
            .buttonStyle(.borderless)

            Button(action: { WebViewBus.shared.goForward() }) {
                Image(systemName: "chevron.right").font(.system(size: 11))
            }
            .disabled(!canGoForward)
            .buttonStyle(.borderless)

            Button(action: {
                if isLoading { WebViewBus.shared.stop() }
                else { WebViewBus.shared.reload() }
            }) {
                Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            TextField("URL", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit(loadCurrentURL)

            Button("Go", action: loadCurrentURL)
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func loadCurrentURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        loadedURL = url
    }

    private var commentSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment on element")
                .font(.system(size: 14, weight: .semibold))
            Text(commentSelector)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if !commentSnippet.isEmpty {
                Text(commentSnippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            TextField("Your note for the agent", text: $commentText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
            HStack {
                Spacer()
                Button("Cancel") { showingCommentSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Send to agent") {
                    sendComment()
                    showingCommentSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
                .disabled(commentText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }

    private func sendComment() {
        let safeSelector = Self.sanitizeForPaste(commentSelector, maxLength: 240)
        let safeText = Self.sanitizeForPaste(commentText, maxLength: 4_000)
        let prompt = "[BROWSER COMMENT @ \(safeSelector)] \(safeText)"
        guard let runtime = AppDelegate.runtime,
              let pane = session.tmuxPaneId ?? session.tmuxWindowId
        else { return }
        let bytes = Data((prompt + "\n").utf8)
        Task {
            try? await runtime.tmuxClient.pasteBytes(paneId: pane, bytes: bytes)
        }
    }

    /// Drop CR/LF and ASCII control bytes so DOM-injected text cannot
    /// terminate the prompt line and inject a fresh shell command into the
    /// pasted bytes. Bounded so a malicious page can't blow up the chat
    /// transcript with a multi-MB selector either.
    static func sanitizeForPaste(_ raw: String, maxLength: Int) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(min(raw.unicodeScalars.count, maxLength))
        for scalar in raw.unicodeScalars {
            if out.count >= maxLength { break }
            // Skip C0 controls (incl. NUL/CR/LF/TAB), DEL, and the C1 range.
            // Allow ordinary spaces — they're fine for tmux paste.
            if (scalar.value < 0x20) || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
                out.append(UnicodeScalar(0x20)!)
                continue
            }
            out.append(scalar)
        }
        return String(out)
    }
}

// MARK: - WKWebView wrapper

private struct WebViewState {
    let canGoBack: Bool
    let canGoForward: Bool
    let isLoading: Bool
}

private struct WebView: NSViewRepresentable {
    let loadURL: URL?
    let onNavigationChange: (WebViewState) -> Void
    let onCommentRequested: (String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNavigationChange: onNavigationChange,
                    onCommentRequested: onCommentRequested)
    }

    func makeNSView(context: Context) -> WKWebView {
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "clawdmeterComment")
        userContent.addUserScript(WKUserScript(
            source: Self.commentBridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        let config = WKWebViewConfiguration()
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        WebViewBus.shared.attach(webView)
        if let loadURL { webView.load(URLRequest(url: loadURL)) }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if let url = loadURL, nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        WebViewBus.shared.detach(nsView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let onNavigationChange: (WebViewState) -> Void
        let onCommentRequested: (String, String) -> Void
        weak var webView: WKWebView?

        init(
            onNavigationChange: @escaping (WebViewState) -> Void,
            onCommentRequested: @escaping (String, String) -> Void
        ) {
            self.onNavigationChange = onNavigationChange
            self.onCommentRequested = onCommentRequested
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            push(webView, loading: true)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            push(webView, loading: false)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            push(webView, loading: false)
        }
        private func push(_ webView: WKWebView, loading: Bool) {
            onNavigationChange(WebViewState(
                canGoBack: webView.canGoBack,
                canGoForward: webView.canGoForward,
                isLoading: loading
            ))
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            let selector = (body["selector"] as? String) ?? ""
            let snippet = (body["snippet"] as? String) ?? ""
            DispatchQueue.main.async {
                self.onCommentRequested(selector, snippet)
            }
        }
    }

    /// JS shim: Cmd-Click on any element → compute a CSS selector for it +
    /// short snippet, post back via `window.webkit.messageHandlers.clawdmeterComment.postMessage`.
    static let commentBridgeJS = """
    (function() {
      function cssPath(el) {
        if (!(el instanceof Element)) return '';
        if (el.id) return '#' + el.id;
        var path = [];
        while (el && el.nodeType === 1 && path.length < 6) {
          var sel = el.nodeName.toLowerCase();
          if (el.classList.length > 0) {
            sel += '.' + Array.from(el.classList).slice(0,2).join('.');
          } else {
            var siblings = el.parentNode ? Array.from(el.parentNode.children).filter(function(c){ return c.nodeName === el.nodeName; }) : [el];
            if (siblings.length > 1) {
              sel += ':nth-of-type(' + (siblings.indexOf(el) + 1) + ')';
            }
          }
          path.unshift(sel);
          el = el.parentElement;
        }
        return path.join(' > ');
      }
      document.addEventListener('click', function(e) {
        if (!(e.metaKey || e.ctrlKey)) return;
        e.preventDefault();
        e.stopPropagation();
        var sel = cssPath(e.target);
        var snippet = (e.target.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 140);
        window.webkit.messageHandlers.clawdmeterComment.postMessage({
          selector: sel,
          snippet: snippet
        });
      }, true);
    })();
    """
}

/// A tiny event bus so the chrome row's back/forward/reload buttons can
/// reach the WKWebView without lifting it into SwiftUI state.
@MainActor
final class WebViewBus {
    static let shared = WebViewBus()
    private weak var webView: WKWebView?
    func attach(_ view: WKWebView) { webView = view }
    func detach(_ view: WKWebView) { if webView === view { webView = nil } }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stop() { webView?.stopLoading() }
}
