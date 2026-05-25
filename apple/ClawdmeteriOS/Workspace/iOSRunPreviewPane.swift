import SwiftUI
import WebKit
import ClawdmeterShared
#if canImport(UIKit)
import UIKit
#endif

struct iOSRunPreviewPane: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var client: AgentControlClient
    @ObservedObject var outbox: MobileCommandOutbox
    let session: AgentSession
    var onOpenTerminal: (() -> Void)? = nil

    @State private var profile: CodeRunProfileSnapshot?
    @State private var runCommand: String = ""
    @State private var urlText: String = ""
    @State private var loadedURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var showingOutput = false
    @State private var showingContextSheet = false
    @State private var showingInspector = false
    @State private var contextNote = ""
    @State private var selectedSelector = ""
    @State private var selectedSnippet = ""
    @State private var pickingElement = false
    @State private var browserCommand: IOSBrowserCommand?
    @State private var consoleLines: [String] = []
    @State private var jsDraft: String = "document.title"
    @State private var jsResult: String = ""
    @State private var pageSnapshot: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            browserChrome
            runControls
            Divider().overlay(t.hairline)
            if let loadedURL {
                IOSBrowserWebView(
                    url: loadedURL,
                    proxyConfiguration: previewProxyConfiguration,
                    command: $browserCommand,
                    isPickingElement: $pickingElement,
                    onNavigationChange: { state in
                        canGoBack = state.canGoBack
                        canGoForward = state.canGoForward
                        isLoading = state.isLoading
                    },
                    onConsole: { line in
                        consoleLines.append(line)
                        if consoleLines.count > 200 {
                            consoleLines.removeFirst(consoleLines.count - 200)
                        }
                    },
                    onEvaluationResult: { result in
                        jsResult = result
                        if result.hasPrefix("{") || result.hasPrefix("[") {
                            pageSnapshot = result
                        }
                    },
                    onElementPicked: { selector, snippet in
                        selectedSelector = selector
                        selectedSnippet = snippet
                        pickingElement = false
                        showingContextSheet = true
                    }
                )
            } else {
                emptyPreview
            }
        }
        .sheet(isPresented: $showingContextSheet) {
            NavigationStack {
                contextSheet
                    .navigationTitle("Send browser context")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingInspector) {
            NavigationStack {
                inspectorSheet
                    .navigationTitle("Browser inspector")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Run preview", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: session.id) {
            await refreshProfile()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await refreshProfile()
            }
        }
    }

    private var browserChrome: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                iconButton("chevron.left", disabled: !canGoBack) {
                    browserCommand = .back(UUID())
                }
                iconButton("chevron.right", disabled: !canGoForward) {
                    browserCommand = .forward(UUID())
                }
                iconButton(isLoading ? "xmark" : "arrow.clockwise", disabled: loadedURL == nil) {
                    browserCommand = isLoading ? .stop(UUID()) : .reload(UUID())
                }
                TextField("URL", text: $urlText)
                    .font(TahoeFont.mono(11.5))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.go)
                    .onSubmit(loadURLText)
                iconButton("arrow.right.circle.fill", disabled: false, action: loadURLText)
            }
            HStack(spacing: 8) {
                Button {
                    openDetectedURL()
                } label: {
                    Label("Detected", systemImage: profile?.detectedURL == nil ? "circle.dashed" : healthIcon)
                        .lineLimit(1)
                }
                .disabled(profile?.detectedURL == nil)

                Button {
                    pickingElement.toggle()
                } label: {
                    Label(pickingElement ? "Tap target" : "Pick", systemImage: "scope")
                }
                .disabled(loadedURL == nil)

                Button {
                    selectedSelector = ""
                    selectedSnippet = ""
                    showingContextSheet = true
                } label: {
                    Label("Send", systemImage: "paperplane")
                }
                .disabled(loadedURL == nil && profile?.detectedURL == nil)

                Button {
                    showingInspector = true
                } label: {
                    Label("Inspect", systemImage: "curlybraces")
                }
                .disabled(loadedURL == nil)

                Spacer(minLength: 0)
            }
            .font(TahoeFont.body(11.5, weight: .semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var runControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 12))
                    .foregroundStyle(t.fg3)
                TextField("Run command on Mac", text: $runCommand)
                    .font(TahoeFont.mono(11.5))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.go)
                    .onSubmit { Task { await startRun() } }
                iconButton("play.fill", disabled: !canStartRun) {
                    Task { await startRun() }
                }
                iconButton("stop.fill", disabled: !isRunning) {
                    Task { await stopRun() }
                }
                iconButton(showingOutput ? "list.bullet.rectangle.fill" : "list.bullet.rectangle", disabled: false) {
                    showingOutput.toggle()
                }
                iconButton("terminal", disabled: !hasTerminalTunnel) {
                    onOpenTerminal?()
                }
            }
            statusRow
            if showingOutput {
                outputPreview
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusLabel)
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(t.fg3)
            if let detected = profile?.detectedURL {
                Text(displayURL(detected))
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg4)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let exit = profile?.lastExitCode {
                Text("exit \(exit)")
                    .font(TahoeFont.mono(10.5, weight: .bold))
                    .foregroundStyle(exit == 0 ? .green : .red)
            }
        }
    }

    private var outputPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                let stdout = profile?.stdoutLines.suffix(18) ?? []
                let stderr = profile?.stderrLines.suffix(10) ?? []
                if stdout.isEmpty && stderr.isEmpty {
                    Text("Waiting for output...")
                        .foregroundStyle(t.fg4)
                } else {
                    ForEach(Array(stdout.enumerated()), id: \.offset) { _, line in
                        Text(line).foregroundStyle(t.fg2)
                    }
                    ForEach(Array(stderr.enumerated()), id: \.offset) { _, line in
                        Text(line).foregroundStyle(.orange)
                    }
                }
            }
            .font(TahoeFont.mono(10.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(maxHeight: 150)
        .background(t.glassTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        }
    }

    private var emptyPreview: some View {
        VStack(spacing: 12) {
            TahoeIcon(profile?.detectedURL == nil ? "globe" : "safari", size: 28)
                .foregroundStyle(t.fg4)
            if let detected = profile?.detectedURL {
                Text(displayURL(detected))
                    .font(TahoeFont.mono(12))
                    .foregroundStyle(t.fg2)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Button("Open detected preview") {
                    openDetectedURL()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("No run preview yet")
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg2)
                Text("Start a Mac run command or paste a URL above.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            }
            if let error = profile?.lastError {
                Text(error)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var contextSheet: some View {
        Form {
            Section("Page") {
                Text(loadedURL?.absoluteString ?? profile?.detectedURL ?? "No URL")
                    .font(TahoeFont.mono(11))
                    .textSelection(.enabled)
                if !selectedSelector.isEmpty {
                    Text(selectedSelector)
                        .font(TahoeFont.mono(11))
                        .textSelection(.enabled)
                }
                if !selectedSnippet.isEmpty {
                    Text(selectedSnippet)
                        .font(TahoeFont.body(12))
                        .foregroundStyle(.secondary)
                }
            }
            Section("Instruction") {
                TextField("Tell the agent what to inspect or change", text: $contextNote, axis: .vertical)
                    .lineLimit(3...8)
            }
            Section {
                Button {
                    sendBrowserContext()
                    showingContextSheet = false
                } label: {
                    Label("Send to agent", systemImage: "paperplane.fill")
                }
                .disabled(contextNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var inspectorSheet: some View {
        Form {
            Section("Page") {
                Button {
                    browserCommand = .evaluate(UUID(), Self.pageSnapshotScript)
                } label: {
                    Label("Capture DOM snapshot", systemImage: "doc.text.magnifyingglass")
                }
                if !pageSnapshot.isEmpty {
                    Text(pageSnapshot)
                        .font(TahoeFont.mono(10.5))
                        .textSelection(.enabled)
                        .lineLimit(10)
                }
            }
            Section("Console") {
                if consoleLines.isEmpty {
                    Text("No console output captured yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(consoleLines.suffix(40).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(TahoeFont.mono(10.5))
                            .textSelection(.enabled)
                    }
                }
            }
            Section("Evaluate JavaScript") {
                TextField("JavaScript", text: $jsDraft, axis: .vertical)
                    .font(TahoeFont.mono(11))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...6)
                Button {
                    browserCommand = .evaluate(UUID(), jsDraft)
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                if !jsResult.isEmpty {
                    Text(jsResult)
                        .font(TahoeFont.mono(10.5))
                        .textSelection(.enabled)
                }
            }
            Section {
                Button {
                    let prompt = Self.browserInspectorPrompt(
                        url: browserContextURLString(),
                        snapshot: pageSnapshot,
                        console: consoleLines.suffix(80).joined(separator: "\n"),
                        evaluation: jsResult
                    )
                    outbox.enqueueSend(sessionId: session.id, text: prompt, asFollowUp: true)
                    showingInspector = false
                } label: {
                    Label("Send inspector context to agent", systemImage: "paperplane.fill")
                }
            }
        }
    }

    private var canStartRun: Bool {
        !runCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning
    }

    private var isRunning: Bool {
        profile?.status == .running || profile?.status == .starting
    }

    private var hasTerminalTunnel: Bool {
        if !(session.tmuxPaneId?.isEmpty ?? true) { return true }
        if !(session.tmuxWindowId?.isEmpty ?? true) { return true }
        return !session.terminalPanes.isEmpty
    }

    private var statusLabel: String {
        switch profile?.status ?? .idle {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .running: return "Running"
        case .exited: return "Exited"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch profile?.status ?? .idle {
        case .idle: return t.fg4
        case .starting, .running: return .green
        case .exited: return t.accent
        case .failed: return .red
        }
    }

    private var healthIcon: String {
        switch profile?.health.state ?? .unknown {
        case .healthy: return "checkmark.circle.fill"
        case .unhealthy: return "exclamationmark.triangle.fill"
        case .unknown: return "circle.dashed"
        }
    }

    private func iconButton(_ systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    @MainActor
    private func refreshProfile() async {
        guard client.supportsCodeWorkbenchRemote else { return }
        if let fetched = await client.fetchRunProfile(sessionId: session.id) {
            profile = fetched
            if runCommand.isEmpty, let command = fetched.command {
                runCommand = command
            }
            if urlText.isEmpty, let detected = fetched.detectedURL {
                urlText = detected
            }
        }
    }

    @MainActor
    private func startRun() async {
        guard client.supportsCodeWorkbenchRemote else {
            errorMessage = "Update Clawdmeter on Mac for remote Run/Preview."
            return
        }
        if let fetched = await client.startRunProfile(sessionId: session.id, command: runCommand) {
            profile = fetched
            if let detected = fetched.detectedURL {
                urlText = detected
            }
        } else {
            errorMessage = client.lastError ?? "Could not start run on the Mac."
        }
    }

    @MainActor
    private func stopRun() async {
        if let fetched = await client.stopRunProfile(sessionId: session.id) {
            profile = fetched
        } else {
            errorMessage = client.lastError ?? "Could not stop the run."
        }
    }

    private func loadURLText() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = "Enter an http or https URL."
            return
        }
        loadedURL = reachablePreviewURL(url)
        urlText = loadedURL?.absoluteString ?? candidate
    }

    private func openDetectedURL() {
        guard let detected = profile?.detectedURL,
              let url = URL(string: detected) else { return }
        loadedURL = reachablePreviewURL(url)
        urlText = loadedURL?.absoluteString ?? detected
    }

    private func reachablePreviewURLString(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return raw }
        return reachablePreviewURL(url)?.absoluteString ?? raw
    }

    private func reachablePreviewURL(_ url: URL) -> URL? {
        guard isLoopbackURL(url) else {
            return url
        }
        if let previewProxyConfiguration,
           let proxied = previewProxyConfiguration.browserURL(for: url) {
            return proxied
        }
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host),
              let pairedHost = client.host else { return url }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.host = pairedHost
        return comps?.url ?? url
    }

    private func displayURL(_ raw: String) -> String {
        raw
    }

    private var previewProxyConfiguration: IOSPreviewProxyConfiguration? {
        guard let host = client.host,
              let token = client.token else {
            return nil
        }
        return IOSPreviewProxyConfiguration(
            sessionId: session.id,
            daemonHost: host,
            daemonPort: client.httpPort,
            token: token
        )
    }

    private func isLoopbackURL(_ url: URL) -> Bool {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased() else {
            return false
        }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    private func browserContextURLString() -> String? {
        guard let loadedURL else { return profile?.detectedURL }
        if loadedURL.scheme == IOSPreviewProxyConfiguration.scheme,
           let detected = profile?.detectedURL,
           var detectedComps = URLComponents(string: detected),
           let loadedComps = URLComponents(url: loadedURL, resolvingAgainstBaseURL: false) {
            if !loadedComps.percentEncodedPath.isEmpty {
                detectedComps.percentEncodedPath = loadedComps.percentEncodedPath
            }
            detectedComps.percentEncodedQuery = loadedComps.percentEncodedQuery
            return detectedComps.url?.absoluteString ?? detected
        }
        return loadedURL.absoluteString
    }

    private func sendBrowserContext() {
        let prompt = Self.browserContextPrompt(
            url: browserContextURLString(),
            selector: selectedSelector,
            snippet: selectedSnippet,
            comment: contextNote
        )
        outbox.enqueueSend(sessionId: session.id, text: prompt, asFollowUp: true)
        contextNote = ""
        selectedSelector = ""
        selectedSnippet = ""
    }

    static func browserContextPrompt(
        url: String?,
        selector: String,
        snippet: String,
        comment: String
    ) -> String {
        """
        [BROWSER CONTEXT]
        URL: \(sanitize(url ?? "(unknown URL)", maxLength: 500))
        Selector: \(sanitize(selector, maxLength: 240))
        Snippet: \(sanitize(snippet, maxLength: 1_000))

        User comment:
        \(sanitize(comment, maxLength: 4_000))
        """
        + "\n"
    }

    static func browserInspectorPrompt(
        url: String?,
        snapshot: String,
        console: String,
        evaluation: String
    ) -> String {
        """
        [BROWSER INSPECTOR]
        URL: \(sanitize(url ?? "(unknown URL)", maxLength: 500))

        DOM snapshot:
        \(sanitize(snapshot, maxLength: 6_000))

        Console:
        \(sanitize(console, maxLength: 6_000))

        Last JS result:
        \(sanitize(evaluation, maxLength: 2_000))
        """
        + "\n"
    }

    private static func sanitize(_ raw: String, maxLength: Int) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(min(raw.unicodeScalars.count, maxLength))
        for scalar in raw.unicodeScalars {
            if out.count >= maxLength { break }
            if (scalar.value < 0x20) || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
                out.append(UnicodeScalar(0x20)!)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    private static let pageSnapshotScript = """
    JSON.stringify({
      title: document.title,
      url: location.href,
      activeElement: document.activeElement ? document.activeElement.tagName.toLowerCase() : null,
      headings: Array.from(document.querySelectorAll('h1,h2,h3')).slice(0, 20).map(function(el) {
        return { tag: el.tagName.toLowerCase(), text: (el.innerText || '').trim().slice(0, 180) };
      }),
      buttons: Array.from(document.querySelectorAll('button,[role="button"],a')).slice(0, 40).map(function(el) {
        return {
          tag: el.tagName.toLowerCase(),
          text: (el.innerText || el.getAttribute('aria-label') || el.href || '').trim().slice(0, 180),
          disabled: !!el.disabled
        };
      }),
      text: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').trim().slice(0, 3000)
    }, null, 2)
    """
}

private enum IOSBrowserCommand: Equatable {
    case back(UUID)
    case forward(UUID)
    case reload(UUID)
    case stop(UUID)
    case evaluate(UUID, String)
}

private struct IOSBrowserState {
    var canGoBack: Bool
    var canGoForward: Bool
    var isLoading: Bool
}

private struct IOSPreviewProxyConfiguration: Equatable {
    static let scheme = "clawdmeter-preview"

    let sessionId: UUID
    let daemonHost: String
    let daemonPort: Int
    let token: String

    func browserURL(for localURL: URL) -> URL? {
        guard let local = URLComponents(url: localURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var browser = URLComponents()
        browser.scheme = Self.scheme
        browser.host = sessionId.uuidString.lowercased()
        browser.percentEncodedPath = local.percentEncodedPath.isEmpty ? "/" : local.percentEncodedPath
        browser.percentEncodedQuery = local.percentEncodedQuery
        return browser.url
    }

    func daemonURL(for browserURL: URL) -> URL? {
        guard let browser = URLComponents(url: browserURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var daemon = URLComponents()
        daemon.scheme = "http"
        daemon.host = daemonHost
        daemon.port = daemonPort
        let path = browser.percentEncodedPath.isEmpty ? "/" : browser.percentEncodedPath
        daemon.percentEncodedPath = "/sessions/\(sessionId.uuidString)/run-profile/proxy\(path)"
        daemon.percentEncodedQuery = browser.percentEncodedQuery
        return daemon.url
    }
}

private final class IOSPreviewProxySchemeHandler: NSObject, WKURLSchemeHandler {
    private let configuration: IOSPreviewProxyConfiguration
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(configuration: IOSPreviewProxyConfiguration) {
        self.configuration = configuration
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let sourceURL = urlSchemeTask.request.url,
              let daemonURL = configuration.daemonURL(for: sourceURL) else {
            urlSchemeTask.didFailWithError(NSError(
                domain: "ClawdmeterPreviewProxy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid preview proxy URL."]
            ))
            return
        }
        var request = URLRequest(url: daemonURL)
        request.httpMethod = urlSchemeTask.request.httpMethod
        request.httpBody = urlSchemeTask.request.httpBody
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        if let accept = urlSchemeTask.request.value(forHTTPHeaderField: "Accept") {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        if let contentType = urlSchemeTask.request.value(forHTTPHeaderField: "Content-Type") {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let userAgent = urlSchemeTask.request.value(forHTTPHeaderField: "User-Agent") {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let taskId = ObjectIdentifier(urlSchemeTask)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.lock.lock()
            let isActive = self.tasks.removeValue(forKey: taskId) != nil
            self.lock.unlock()
            guard isActive else { return }
            if let error {
                urlSchemeTask.didFailWithError(error)
                return
            }
            if let response = self.browserResponse(for: sourceURL, response: response, data: data) {
                urlSchemeTask.didReceive(response)
            }
            if let data {
                urlSchemeTask.didReceive(data)
            }
            urlSchemeTask.didFinish()
        }
        lock.lock()
        tasks[taskId] = task
        lock.unlock()
        task.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskId = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        let task = tasks.removeValue(forKey: taskId)
        lock.unlock()
        task?.cancel()
    }

    private func browserResponse(for sourceURL: URL, response: URLResponse?, data: Data?) -> URLResponse? {
        if let http = response as? HTTPURLResponse {
            let headerFields = http.allHeaderFields.reduce(into: [String: String]()) { partial, entry in
                guard let key = entry.key as? String else { return }
                partial[key] = "\(entry.value)"
            }
            return HTTPURLResponse(
                url: sourceURL,
                statusCode: http.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headerFields
            )
        }
        if let response {
            let expectedLength = data?.count
                ?? (response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : -1)
            return URLResponse(
                url: sourceURL,
                mimeType: response.mimeType,
                expectedContentLength: expectedLength,
                textEncodingName: response.textEncodingName
            )
        }
        return URLResponse(url: sourceURL, mimeType: nil, expectedContentLength: data?.count ?? 0, textEncodingName: nil)
    }
}

private struct IOSBrowserWebView: UIViewRepresentable {
    let url: URL
    let proxyConfiguration: IOSPreviewProxyConfiguration?
    @Binding var command: IOSBrowserCommand?
    @Binding var isPickingElement: Bool
    let onNavigationChange: (IOSBrowserState) -> Void
    let onConsole: (String) -> Void
    let onEvaluationResult: (String) -> Void
    let onElementPicked: (String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNavigationChange: onNavigationChange,
            onConsole: onConsole,
            onEvaluationResult: onEvaluationResult,
            onElementPicked: onElementPicked
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "clawdmeterPick")
        userContent.add(context.coordinator, name: "clawdmeterConsole")
        userContent.addUserScript(WKUserScript(
            source: Self.pickScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        userContent.addUserScript(WKUserScript(
            source: Self.consoleScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        if let proxyConfiguration {
            config.setURLSchemeHandler(
                IOSPreviewProxySchemeHandler(configuration: proxyConfiguration),
                forURLScheme: IOSPreviewProxyConfiguration.scheme
            )
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
        uiView.evaluateJavaScript("window.__clawdmeterPickMode = \(isPickingElement ? "true" : "false");")
        if let command {
            switch command {
            case .back:
                if uiView.canGoBack { uiView.goBack() }
            case .forward:
                if uiView.canGoForward { uiView.goForward() }
            case .reload:
                uiView.reload()
            case .stop:
                uiView.stopLoading()
            case .evaluate(_, let script):
                uiView.evaluateJavaScript(script) { value, error in
                    let output: String
                    if let error {
                        output = "Error: \(error.localizedDescription)"
                    } else if let value {
                        output = "\(value)"
                    } else {
                        output = "undefined"
                    }
                    DispatchQueue.main.async {
                        context.coordinator.onEvaluationResult(output)
                    }
                }
            }
            DispatchQueue.main.async {
                self.command = nil
            }
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "clawdmeterPick")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "clawdmeterConsole")
        uiView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onNavigationChange: (IOSBrowserState) -> Void
        let onConsole: (String) -> Void
        let onEvaluationResult: (String) -> Void
        let onElementPicked: (String, String) -> Void
        weak var webView: WKWebView?

        init(
            onNavigationChange: @escaping (IOSBrowserState) -> Void,
            onConsole: @escaping (String) -> Void,
            onEvaluationResult: @escaping (String) -> Void,
            onElementPicked: @escaping (String, String) -> Void
        ) {
            self.onNavigationChange = onNavigationChange
            self.onConsole = onConsole
            self.onEvaluationResult = onEvaluationResult
            self.onElementPicked = onElementPicked
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

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "clawdmeterConsole" {
                if let dict = message.body as? [String: Any] {
                    let level = dict["level"] as? String ?? "log"
                    let values = dict["values"] as? [String] ?? []
                    onConsole("[\(level)] " + values.joined(separator: " "))
                }
                return
            }
            guard let dict = message.body as? [String: Any] else { return }
            let selector = dict["selector"] as? String ?? ""
            let snippet = dict["snippet"] as? String ?? ""
            onElementPicked(selector, snippet)
        }

        private func push(_ webView: WKWebView, loading: Bool) {
            onNavigationChange(IOSBrowserState(
                canGoBack: webView.canGoBack,
                canGoForward: webView.canGoForward,
                isLoading: loading
            ))
        }
    }

    private static let pickScript = """
    (function() {
      if (window.__clawdmeterPickInstalled) return;
      window.__clawdmeterPickInstalled = true;
      window.__clawdmeterPickMode = false;
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
            if (siblings.length > 1) sel += ':nth-of-type(' + (siblings.indexOf(el) + 1) + ')';
          }
          path.unshift(sel);
          el = el.parentElement;
        }
        return path.join(' > ');
      }
      document.addEventListener('click', function(e) {
        if (!window.__clawdmeterPickMode) return;
        e.preventDefault();
        e.stopPropagation();
        var snippet = (e.target.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 180);
        window.webkit.messageHandlers.clawdmeterPick.postMessage({
          selector: cssPath(e.target),
          snippet: snippet
        });
      }, true);
    })();
    """

    private static let consoleScript = """
    (function() {
      if (window.__clawdmeterConsoleInstalled) return;
      window.__clawdmeterConsoleInstalled = true;
      ['log','info','warn','error'].forEach(function(level) {
        var original = console[level];
        console[level] = function() {
          try {
            window.webkit.messageHandlers.clawdmeterConsole.postMessage({
              level: level,
              values: Array.from(arguments).map(function(value) {
                try {
                  if (typeof value === 'string') return value;
                  return JSON.stringify(value);
                } catch (e) {
                  return String(value);
                }
              }).slice(0, 8)
            });
          } catch (e) {}
          return original.apply(console, arguments);
        };
      });
      window.addEventListener('error', function(event) {
        try {
          window.webkit.messageHandlers.clawdmeterConsole.postMessage({
            level: 'error',
            values: [event.message + ' @ ' + event.filename + ':' + event.lineno]
          });
        } catch (e) {}
      });
      window.addEventListener('unhandledrejection', function(event) {
        try {
          window.webkit.messageHandlers.clawdmeterConsole.postMessage({
            level: 'error',
            values: ['Unhandled promise rejection: ' + String(event.reason)]
          });
        } catch (e) {}
      });
    })();
    """
}
