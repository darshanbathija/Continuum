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
    @ObservedObject var workbenchState: WorkbenchState
    @StateObject private var runProfile: RunProfileManager

    @State private var urlText: String = ""
    @State private var loadedURL: URL?
    @State private var canGoBack: Bool = false
    @State private var canGoForward: Bool = false
    @State private var isLoading: Bool = false

    @State private var commentSelector: String = ""
    @State private var commentSnippet: String = ""
    @State private var commentText: String = ""
    @State private var showingCommentSheet: Bool = false
    @State private var lastSendError: String?
    @State private var showingRunOutput = false

    init(session: AgentSession, model: SessionsModel, workbenchState: WorkbenchState) {
        self.session = session
        self.model = model
        self.workbenchState = workbenchState
        _runProfile = StateObject(wrappedValue: RunProfileManager(
            sessionId: session.id,
            chatStore: model.chatStore(for: session),
            initialState: workbenchState.runProfile(for: session.id)
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            runControlBar
            Divider()
            if loadedURL == nil {
                previewEmptyState
            } else {
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
        }
        .sheet(isPresented: $showingCommentSheet) { commentSheet }
        .onAppear {
            if urlText.isEmpty, let snapshot = runProfile.snapshot {
                urlText = snapshot.url.absoluteString
            }
            runProfile.start()
            workbenchState.recordRunProfile(runProfile.stateSnapshot)
        }
        .onDisappear {
            runProfile.stop()
            workbenchState.recordRunProfile(runProfile.stateSnapshot)
        }
        .onChange(of: runProfile.snapshot?.url) { _, url in
            guard loadedURL == nil, let url else { return }
            loadedURL = url
            urlText = url.absoluteString
        }
        .onChange(of: runProfile.stateSnapshot) { _, state in
            workbenchState.recordRunProfile(state)
        }
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

            if let snapshot = runProfile.snapshot {
                Button(action: {
                    loadedURL = snapshot.url
                    urlText = snapshot.url.absoluteString
                }) {
                    Image(systemName: runHealthIcon(snapshot.health))
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Open detected run URL")
            }

            Button(action: loadCurrentURL) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Load URL")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var runControlBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Run command", text: $runProfile.runCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { startRun() }
                Button(action: startRun) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(!canStartRun)
                .help("Start run profile")
                Button(action: { runProfile.stopRun(); workbenchState.recordRunProfile(runProfile.stateSnapshot) }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(runProfile.status != .running && runProfile.status != .starting)
                .help("Stop run profile")
                Button(action: {
                    let result = resolveRunEnvironment()
                    guard result.ok else {
                        workbenchState.recordRunProfile(runProfile.stateSnapshot)
                        return
                    }
                    runProfile.restartRun(cwd: session.effectiveCwd, environment: result.environment)
                    workbenchState.recordRunProfile(runProfile.stateSnapshot)
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(runProfile.runCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Restart run profile")
                Button(action: { showingRunOutput.toggle() }) {
                    Image(systemName: showingRunOutput ? "terminal.fill" : "terminal")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Show run output")
            }
            runStatusRow
            if showingRunOutput {
                runOutputPreview
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var canStartRun: Bool {
        !runProfile.runCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && runProfile.status != .running
            && runProfile.status != .starting
    }

    private var runStatusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(runStatusColor)
                .frame(width: 6, height: 6)
            Text(runStatusLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            if let snapshot = runProfile.snapshot {
                Text(snapshot.url.absoluteString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(snapshot.source)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer()
            if let exitCode = runProfile.lastExitCode {
                Text("exit \(exitCode)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(exitCode == 0 ? .green : .red)
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

    private var runOutputPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            if runProfile.stdoutLines.isEmpty && runProfile.stderrLines.isEmpty {
                Text("Waiting for output…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(runProfile.stdoutLines.suffix(6).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ForEach(Array(runProfile.stderrLines.suffix(4).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var runStatusColor: Color {
        switch runProfile.status {
        case .idle: return .secondary
        case .starting, .running: return .green
        case .exited: return .blue
        case .failed: return .red
        }
    }

    private var runStatusLabel: String {
        switch runProfile.status {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .running: return "Running"
        case .exited: return "Exited"
        case .failed: return "Failed"
        }
    }

    private func startRun() {
        let result = resolveRunEnvironment()
        guard result.ok else {
            workbenchState.recordRunProfile(runProfile.stateSnapshot)
            return
        }
        runProfile.startRun(cwd: session.effectiveCwd, environment: result.environment)
        workbenchState.recordRunProfile(runProfile.stateSnapshot)
    }

    private func resolveRunEnvironment() -> (ok: Bool, environment: [String: String]?) {
        guard let resolver = AppDelegate.runtime?.repoEnvRuntimeResolver else {
            return (true, nil)
        }
        do {
            return (true, try resolver.resolveForLaunch(session: session)?.environment)
        } catch {
            runProfile.failRun(error.localizedDescription)
            return (false, nil)
        }
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

    private func runHealthIcon(_ health: RunProfileManager.Health) -> String {
        switch health {
        case .healthy:
            return "checkmark.circle.fill"
        case .unhealthy:
            return "exclamationmark.triangle.fill"
        case .unknown:
            return "circle.dashed"
        }
    }

    private var previewEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: runProfile.isChecking ? "network" : "safari")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            if let snapshot = runProfile.snapshot {
                Button(action: {
                    loadedURL = snapshot.url
                    urlText = snapshot.url.absoluteString
                }) {
                    Label(snapshot.url.absoluteString, systemImage: runHealthIcon(snapshot.health))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.bordered)
            } else {
                Text("No local run URL detected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Start a run profile or enter a URL above.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if let error = runProfile.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let lastSendError {
                Text(lastSendError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                .tint(SessionsV2Theme.accent)
                .disabled(commentText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }

    private func sendComment() {
        let prompt = Self.browserCommentPrompt(
            url: loadedURL ?? runProfile.snapshot?.url,
            selector: commentSelector,
            snippet: commentSnippet,
            comment: commentText
        )
        if session.status == .running {
            workbenchState.queueSend(QueuedWorkbenchSend(sessionId: session.id, text: prompt))
            lastSendError = nil
            return
        }
        guard let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else {
            lastSendError = "Daemon offline. Restart Clawdmeter to send browser context."
            return
        }
        let sender = MacComposerSender(port: Int(port), token: PairingTokenStore.shared.currentToken())
        let sessionId = session.id
        Task {
            do {
                try await sender.send(sessionId: sessionId, body: prompt, asFollowUp: true)
                lastSendError = nil
            } catch {
                lastSendError = error.localizedDescription
                browserLogger.error("browser comment send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func browserCommentPrompt(
        url: URL?,
        selector: String,
        snippet: String,
        comment: String
    ) -> String {
        let safeURL = sanitizeForPaste(url?.absoluteString ?? "(unknown URL)", maxLength: 500)
        let safeSelector = sanitizeForPaste(selector, maxLength: 240)
        let safeSnippet = sanitizeForPaste(snippet, maxLength: 1_000)
        let safeComment = sanitizeForPaste(comment, maxLength: 4_000)
        return """
        [BROWSER CONTEXT]
        URL: \(safeURL)
        Selector: \(safeSelector)
        Snippet: \(safeSnippet)

        User comment:
        \(safeComment)
        """
        + "\n"
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
            source: InAppBrowser.commentBridgeJS,
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
        // P1-Mac-13: remove the script message handler and clear delegates
        // before detaching, otherwise WKUserContentController retains the
        // coordinator and leaks a WKWebView on every tab change.
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "clawdmeterComment")
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
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
