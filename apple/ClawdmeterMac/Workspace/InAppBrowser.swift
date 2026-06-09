import SwiftUI
import Combine
import WebKit
import ClawdmeterShared
import OSLog

private let browserLogger = Logger(subsystem: "com.clawdmeter.mac", category: "InAppBrowser")

@MainActor
final class BrowserWorkspaceControllerStore: ObservableObject {
    private var controllers: [String: BrowserWorkspaceController] = [:]

    static func identityKey(for session: AgentSession) -> String {
        "\(session.id.uuidString)#\(session.effectiveCwd)"
    }

    var countForTesting: Int { controllers.count }

    func controller(
        for session: AgentSession,
        model: SessionsModel,
        workbenchState: WorkbenchState
    ) -> BrowserWorkspaceController {
        let key = Self.identityKey(for: session)
        if let existing = controllers[key] { return existing }
        let created = BrowserWorkspaceController(
            session: session,
            chatStore: model.chatStore(for: session),
            initialState: workbenchState.runProfile(for: session.id)
        )
        controllers[key] = created
        return created
    }

    func prune(keeping sessions: [AgentSession]) {
        let liveKeys = Set(sessions.map(Self.identityKey(for:)))
        let staleKeys = controllers.keys.filter { !liveKeys.contains($0) }
        for key in staleKeys {
            controllers.removeValue(forKey: key)?.shutdown()
        }
    }
}

struct BrowserAnnotationDraft: Equatable {
    var annotationId: String?
    var eventType: String
    var selector: String
    var snippet: String
    var selectedText: String?
    var nearbyText: String?
    var accessibilityLabel: String?
    var sourceHint: String?
    var computedStyleSummary: [String: String]
    var areaSelection: String?
    var cssClasses: [String]
    var boundingBox: BrowserCommentContext.BoundingBox?
}

@MainActor
final class BrowserWorkspaceController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let sessionId: UUID
    let cwd: String
    let runProfile: RunProfileManager
    private(set) var webView: WKWebView!

    @Published var urlText: String = ""
    @Published var loadedURL: URL?
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var pendingComment: BrowserAnnotationDraft?
    @Published var commentText: String = ""
    @Published var lastSendError: String?
    @Published var showingRunOutput = false

    private var runProfileCancellable: AnyCancellable?
    private var didShutdown = false
    private var didDetachWebViewHandlers = false

    var isShutdownForTesting: Bool { didShutdown }

    init(session: AgentSession, chatStore: SessionChatStore?, initialState: RunProfileStateSnapshot?) {
        self.sessionId = session.id
        self.cwd = session.effectiveCwd
        self.runProfile = RunProfileManager(
            sessionId: session.id,
            chatStore: chatStore,
            initialState: initialState
        )
        super.init()

        let userContent = WKUserContentController()
        userContent.add(self, name: "clawdmeterComment")
        userContent.addUserScript(WKUserScript(
            source: BrowserOverlayResources.scriptSource(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view

        if let url = runProfile.snapshot?.url {
            urlText = url.absoluteString
            loadedURL = url
        }
        runProfileCancellable = runProfile.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func start() {
        guard !didShutdown else { return }
        runProfile.start()
    }

    func stopObserving() {
        runProfile.stop()
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        runProfile.stop()
        runProfile.stopRun()
        runProfileCancellable?.cancel()
        runProfileCancellable = nil
        webView?.stopLoading()
        detachWebViewHandlers()
    }

    private func detachWebViewHandlers() {
        guard !didDetachWebViewHandlers else { return }
        didDetachWebViewHandlers = true
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "clawdmeterComment")
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    func loadCurrentURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        load(url)
    }

    func load(_ url: URL) {
        loadedURL = url
        urlText = url.absoluteString
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    func openRunSnapshot() {
        guard let url = runProfile.snapshot?.url else { return }
        load(url)
    }

    func launchPreview(session: AgentSession, workbenchState: WorkbenchState, forceRestart: Bool = false) async {
        start()
        if let url = await runProfile.launchPreview(session: session, forceRestart: forceRestart) {
            load(url)
        }
        workbenchState.recordRunProfile(runProfile.stateSnapshot)
    }

    func stagePendingComment(into store: ComposerStore) {
        guard let pendingComment else { return }
        let context = BrowserCommentContext(
            urlString: (loadedURL ?? webView.url ?? runProfile.snapshot?.url)?.absoluteString,
            selector: pendingComment.selector,
            snippet: pendingComment.snippet,
            comment: commentText,
            annotationId: pendingComment.annotationId,
            selectedText: pendingComment.selectedText,
            nearbyText: pendingComment.nearbyText,
            accessibilityLabel: pendingComment.accessibilityLabel,
            sourceHint: pendingComment.sourceHint,
            computedStyleSummary: pendingComment.computedStyleSummary,
            areaSelection: pendingComment.areaSelection,
            cssClasses: pendingComment.cssClasses,
            boundingBox: pendingComment.boundingBox
        )
        store.addBrowserComment(context)
        lastSendError = nil
        self.pendingComment = nil
        commentText = ""
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        push(webView, loading: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadedURL = webView.url
        if let url = webView.url { urlText = url.absoluteString }
        push(webView, loading: false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        push(webView, loading: false)
    }

    private func push(_ webView: WKWebView, loading: Bool) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = loading
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        receiveBridgePayload(body)
    }

    func receiveBridgePayloadForTesting(_ body: [String: Any]) {
        receiveBridgePayload(body)
    }

    private func receiveBridgePayload(_ body: [String: Any]) {
        let eventType = Self.bridgeString(body["eventType"], maxLength: 48) ?? "annotate"
        let annotationId = Self.bridgeString(body["annotationId"], maxLength: 120)
        if eventType == "markerDeleted" {
            if pendingComment?.annotationId == annotationId {
                pendingComment = nil
                commentText = ""
            }
            return
        }
        let rect = body["boundingBox"] as? [String: Any]
        pendingComment = BrowserAnnotationDraft(
            annotationId: annotationId,
            eventType: eventType,
            selector: Self.bridgeString(body["selector"], maxLength: 300) ?? "",
            snippet: Self.bridgeString(body["snippet"], maxLength: 1_000) ?? "",
            selectedText: Self.bridgeString(body["selectedText"], maxLength: 1_000),
            nearbyText: Self.bridgeString(body["nearbyText"], maxLength: 1_500),
            accessibilityLabel: Self.bridgeString(body["accessibilityLabel"], maxLength: 240),
            sourceHint: Self.bridgeString(body["sourceHint"], maxLength: 300),
            computedStyleSummary: Self.bridgeStringDictionary(body["computedStyleSummary"]),
            areaSelection: Self.bridgeString(body["areaSelection"], maxLength: 240),
            cssClasses: Self.bridgeStringArray(body["cssClasses"], maxCount: 12, maxLength: 80),
            boundingBox: rect.map {
                BrowserCommentContext.BoundingBox(
                    x: Self.bridgeNumber($0["x"]),
                    y: Self.bridgeNumber($0["y"]),
                    width: Self.bridgeNumber($0["width"]),
                    height: Self.bridgeNumber($0["height"])
                )
            }
        )
        commentText = ""
    }

    private static func bridgeNumber(_ value: Any?) -> Double {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let double = Double(string) { return double }
        return 0
    }

    private static func bridgeString(_ value: Any?, maxLength: Int) -> String? {
        let raw: String
        if let string = value as? String {
            raw = string
        } else if let value {
            raw = String(describing: value)
        } else {
            return nil
        }
        return String(raw.prefix(maxLength))
    }

    private static func bridgeStringArray(_ value: Any?, maxCount: Int, maxLength: Int) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array
            .prefix(maxCount)
            .compactMap { bridgeString($0, maxLength: maxLength) }
            .filter { !$0.isEmpty }
    }

    private static func bridgeStringDictionary(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary
            .sorted { $0.key < $1.key }
            .prefix(16)
            .reduce(into: [String: String]()) { acc, pair in
                guard let key = bridgeString(pair.key, maxLength: 48), !key.isEmpty,
                      let value = bridgeString(pair.value, maxLength: 160), !value.isEmpty
                else { return }
                acc[key] = value
            }
    }
}

private enum BrowserOverlayResources {
    static func scriptSource() -> String {
        if let url = Bundle.main.url(forResource: "browser-overlay", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }
        return fallbackScript
    }

    static let fallbackScript = """
    (function() {
      if (window.__clawdmeterBrowserOverlayInstalled) return;
      window.__clawdmeterBrowserOverlayInstalled = true;
      function text(el) { return ((el && el.textContent) || '').trim().replace(/\\s+/g, ' ').slice(0, 1000); }
      function esc(value) { return window.CSS && CSS.escape ? CSS.escape(value) : String(value).replace(/[^a-zA-Z0-9_-]/g, '\\\\$&'); }
      function cssPath(el) {
        if (!(el instanceof Element)) return '';
        if (el.id) return '#' + esc(el.id);
        var path = [];
        while (el && el.nodeType === 1 && path.length < 7) {
          var sel = el.nodeName.toLowerCase();
          var classes = Array.from(el.classList || []).filter(function(c){ return c.indexOf('clawdmeter-browser-') !== 0; }).slice(0, 3).map(esc);
          if (classes.length) sel += '.' + classes.join('.');
          else {
            var siblings = el.parentNode ? Array.from(el.parentNode.children).filter(function(c){ return c.nodeName === el.nodeName; }) : [el];
            if (siblings.length > 1) sel += ':nth-of-type(' + (siblings.indexOf(el) + 1) + ')';
          }
          path.unshift(sel);
          el = el.parentElement || (el.getRootNode && el.getRootNode().host);
        }
        return path.join(' > ');
      }
      function sourceHint(el) {
        var node = el, depth = 0;
        while (node && depth < 6) {
          var value = node.getAttribute && (node.getAttribute('data-source') || node.getAttribute('data-file') || node.getAttribute('data-component') || node.getAttribute('data-testid') || node.getAttribute('data-test'));
          if (value) return text({ textContent: value }).slice(0, 300);
          node = node.parentElement || (node.getRootNode && node.getRootNode().host);
          depth += 1;
        }
        return el && el.id ? '#' + el.id : '';
      }
      function styleSummary(el, rect) {
        if (!window.getComputedStyle || !(el instanceof Element)) return {};
        var s = getComputedStyle(el);
        return { display: s.display, position: s.position, overflow: s.overflow, color: s.color, backgroundColor: s.backgroundColor, fontSize: s.fontSize, fontWeight: s.fontWeight, zIndex: s.zIndex, opacity: s.opacity, size: Math.round(rect.width) + 'x' + Math.round(rect.height) };
      }
      document.addEventListener('click', function(e) {
        if (!(e.metaKey || e.ctrlKey)) return;
        e.preventDefault();
        e.stopPropagation();
        var target = e.target;
        var rect = target.getBoundingClientRect ? target.getBoundingClientRect() : {x:0,y:0,width:0,height:0};
        var selection = String(window.getSelection ? window.getSelection() : '').trim();
        window.webkit.messageHandlers.clawdmeterComment.postMessage({
          eventType: e.shiftKey ? 'multiSelect' : 'click',
          annotationId: 'fallback-' + Date.now().toString(36),
          selector: cssPath(target),
          snippet: text(target).slice(0, 240),
          selectedText: selection.slice(0, 1000),
          nearbyText: text(target.parentElement).slice(0, 1200),
          accessibilityLabel: target.getAttribute && (target.getAttribute('aria-label') || target.getAttribute('alt') || target.getAttribute('title') || ''),
          sourceHint: sourceHint(target),
          computedStyleSummary: styleSummary(target, rect),
          areaSelection: e.shiftKey ? '1 selected element' : '',
          cssClasses: target.classList ? Array.from(target.classList).filter(function(c){ return c.indexOf('clawdmeter-browser-') !== 0; }).slice(0, 12) : [],
          boundingBox: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
        });
      }, true);
    })();
    """
}

/// G13 in-app browser pane. WKWebView + minimal nav chrome. The core
/// feature is `Cmd-Click` on any DOM element -> modal dialog -> attach a
/// removable `Comment: <summary>` chip to the composer.
///
/// CSS selector resolution is done in JS: walks up the tag chain, picks
/// the most specific shortest selector (id > class.combo > nth-of-type),
/// hands it back via `WKScriptMessageHandler`.
struct InAppBrowser: View {
    let session: AgentSession
    @ObservedObject var model: SessionsModel
    @ObservedObject var workbenchState: WorkbenchState
    @ObservedObject var controller: BrowserWorkspaceController
    var isFullWorkspace: Bool
    var onCloseFullWorkspace: () -> Void

    init(
        session: AgentSession,
        model: SessionsModel,
        workbenchState: WorkbenchState,
        controller: BrowserWorkspaceController,
        isFullWorkspace: Bool = false,
        onCloseFullWorkspace: @escaping () -> Void = {}
    ) {
        self.session = session
        self.model = model
        self.workbenchState = workbenchState
        self.controller = controller
        self.isFullWorkspace = isFullWorkspace
        self.onCloseFullWorkspace = onCloseFullWorkspace
    }

    private var runProfile: RunProfileManager {
        controller.runProfile
    }

    private var runCommandBinding: Binding<String> {
        Binding(
            get: { controller.runProfile.runCommand },
            set: { controller.runProfile.runCommand = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            runControlBar
            Divider()
            if controller.loadedURL == nil {
                previewEmptyState
            } else {
                BrowserWebView(controller: controller)
            }
        }
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isFullWorkspace ? "Browser workspace" : "Browser pane")
                .accessibilityIdentifier(isFullWorkspace ? "code.browser.fullWorkspace" : "code.browser.pane")
        }
        .sheet(
            isPresented: Binding(
                get: { controller.pendingComment != nil },
                set: { if !$0 { controller.pendingComment = nil } }
            )
        ) { commentSheet }
        .onAppear {
            controller.start()
            workbenchState.recordRunProfile(controller.runProfile.stateSnapshot)
        }
        .onDisappear {
            controller.stopObserving()
            workbenchState.recordRunProfile(controller.runProfile.stateSnapshot)
        }
        .onChange(of: controller.runProfile.snapshot?.url) { _, url in
            guard controller.loadedURL == nil, let url else { return }
            controller.load(url)
        }
        .onChange(of: controller.runProfile.stateSnapshot) { _, state in
            workbenchState.recordRunProfile(state)
        }
    }

    private var chrome: some View {
        HStack(spacing: 6) {
            if isFullWorkspace {
                Button(action: onCloseFullWorkspace) {
                    Label("Back to Chat", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(PressableButtonStyle())
                .help("Return to chat")
                .accessibilityIdentifier("code.browser.backToChat")
            }

            Button(action: { controller.goBack() }) {
                Image(systemName: "chevron.left").font(.system(size: 11))
            }
            .disabled(!controller.canGoBack)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("code.browser.back")

            Button(action: { controller.goForward() }) {
                Image(systemName: "chevron.right").font(.system(size: 11))
            }
            .disabled(!controller.canGoForward)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("code.browser.forward")

            Button(action: {
                if controller.isLoading { controller.stopLoading() }
                else { controller.reload() }
            }) {
                Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(controller.isLoading ? "code.browser.stop-loading" : "code.browser.reload")

            TextField("URL", text: $controller.urlText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit(controller.loadCurrentURL)
                .accessibilityIdentifier("code.browser.url")

            if let snapshot = controller.runProfile.snapshot {
                Button(action: {
                    controller.load(snapshot.url)
                }) {
                    Image(systemName: runHealthIcon(snapshot.health))
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Open detected run URL")
                .accessibilityIdentifier("code.browser.detected-url")
            }

            Button(action: controller.loadCurrentURL) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Load URL")
            .accessibilityIdentifier("code.browser.load-url")
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
                TextField("Run command", text: runCommandBinding)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { startRun() }
                    .accessibilityIdentifier("code.browser.run-command")
                Button(action: startRun) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(!canStartRun)
                .help("Start run profile")
                .accessibilityIdentifier("code.browser.run-start")
                Button(action: { controller.runProfile.stopRun(); workbenchState.recordRunProfile(controller.runProfile.stateSnapshot) }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(controller.runProfile.status != .running && controller.runProfile.status != .starting)
                .help("Stop run profile")
                .accessibilityIdentifier("code.browser.run-stop")
                Button(action: {
                    let result = resolveRunEnvironment()
                    guard result.ok else {
                        workbenchState.recordRunProfile(controller.runProfile.stateSnapshot)
                        return
                    }
                    controller.runProfile.restartRun(cwd: session.effectiveCwd, environment: result.environment)
                    workbenchState.recordRunProfile(controller.runProfile.stateSnapshot)
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .buttonStyle(.borderless)
                .disabled(controller.runProfile.runCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Restart run profile")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Restart run profile")
                .accessibilityIdentifier("code.browser.restart")
                Button(action: { controller.showingRunOutput.toggle() }) {
                    Image(systemName: controller.showingRunOutput ? "terminal.fill" : "terminal")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Show run output")
                .accessibilityIdentifier("code.browser.run-output-toggle")
            }
            runStatusRow
            if controller.showingRunOutput {
                runOutputPreview
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var canStartRun: Bool {
        let runProfile = controller.runProfile
        return !runProfile.runCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                .accessibilityIdentifier("code.browser.runStatus")
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

    static var commentBridgeJS: String { BrowserOverlayResources.scriptSource() }

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
        switch runProfile.previewState {
        case .resolving: return "Resolving preview"
        case .settingUp: return "Running setup"
        case .reusing: return "Reusing preview"
        case .healthy: return "Healthy"
        case .unhealthy: return "Unhealthy"
        case .restarting: return "Restarting"
        case .failed: return "Failed"
        case .starting, .running, .idle:
            break
        }
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
            let repoEnv = try resolver.resolveForLaunch(session: session)?.environment ?? [:]
            let portBase = PreviewLaunchPolicy.portBase(for: session.id)
            guard let port = PreviewLaunchPolicy.firstAvailablePort(startingAt: portBase) else {
                let end = portBase + PreviewLaunchPolicy.portRangeSize - 1
                runProfile.failRun("No free preview port in assigned range \(portBase)-\(end).")
                return (false, nil)
            }
            let previewEnv = PreviewLaunchPolicy.environment(session: session, portBase: portBase, activePort: port)
            return (true, repoEnv.merging(previewEnv) { _, new in new })
        } catch {
            runProfile.failRun(error.localizedDescription)
            return (false, nil)
        }
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
                    controller.load(snapshot.url)
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
            Text(controller.pendingComment?.selector ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let snippet = controller.pendingComment?.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            TextField("Your note for the agent", text: $controller.commentText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .accessibilityIdentifier("code.browser.comment.text")
            if let lastSendError = controller.lastSendError {
                Text(lastSendError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { controller.pendingComment = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("code.browser.comment.cancel")
                Button("Add to chat") {
                    let store = model.composerStore(for: session, catalog: .bundled)
                    controller.stagePendingComment(into: store)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(SessionsV2Theme.accent)
                .disabled(controller.commentText.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("code.browser.comment.add")
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }
}

// MARK: - WKWebView wrapper

private struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var controller: BrowserWorkspaceController

    func makeNSView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if let url = controller.loadedURL, nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }
}
