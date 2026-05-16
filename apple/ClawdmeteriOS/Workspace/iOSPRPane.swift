import SwiftUI
import ClawdmeterShared

/// iOS PR pane — shows the open PR (if any), with Create / Merge / Open
/// in GitHub actions. Wires through `GET /sessions/:id/pr` +
/// `POST /sessions/:id/{create-pr,merge}`.
///
/// Sessions v2 Phase 4.
struct iOSPRPane: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient

    @State private var pr: PRStatus?
    @State private var isLoading: Bool = true
    @State private var isCreating: Bool = false
    @State private var showingMergeConfirm: Bool = false
    @State private var bannerMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading PR…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pr {
                prCard(pr)
            } else {
                emptyState
            }
        }
        .navigationTitle("Pull Request")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
        .overlay(alignment: .top) {
            if let bannerMessage {
                Text(bannerMessage)
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(SessionsV2Theme.accent.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 48))
                .foregroundStyle(SessionsV2Theme.textTertiary)
                .accessibilityHidden(true)
            Text("No PR yet")
                .font(.headline)
            Button {
                Task { await createPR() }
            } label: {
                if isCreating {
                    ProgressView()
                } else {
                    Label("Create PR", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(SessionsV2Theme.accent)
            .disabled(isCreating)
            .frame(minHeight: 44)
            .accessibilityLabel("Create pull request")
            .accessibilityHint("Runs gh pr create on the Mac and opens the PR.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func prCard(_ pr: PRStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    statePill(pr.state)
                    Spacer()
                    Text("#\(pr.number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(pr.title)
                    .font(.title3.weight(.semibold))

                HStack(spacing: 12) {
                    Label("+\(pr.additions)", systemImage: "plus")
                        .foregroundStyle(.green)
                    Label("-\(pr.deletions)", systemImage: "minus")
                        .foregroundStyle(.red)
                    Label("\(pr.changedFiles) files", systemImage: "doc.text")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())

                if let review = pr.reviewDecision, !review.isEmpty {
                    Label("Review: \(review)", systemImage: "checkmark.seal")
                        .foregroundStyle(SessionsV2Theme.codexBlue)
                }

                if let checks = pr.checksRollup, !checks.isEmpty {
                    // Partial-state per Pass 2 table: "checks pending" is
                    // a distinct render from success/failure so the user
                    // can tell at a glance whether to wait or react.
                    Label("CI: \(checks)", systemImage: checksGlyph(checks))
                        .foregroundStyle(checksColor(checks))
                }

                Divider()

                Text(pr.body)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                HStack {
                    Link(destination: URL(string: pr.url) ?? URL(string: "https://github.com")!) {
                        Label("Open in GitHub", systemImage: "safari")
                    }
                    .frame(minHeight: 44)
                    .accessibilityHint("Opens the pull request in Safari.")
                    Spacer()
                    Button(role: .destructive) {
                        showingMergeConfirm = true
                    } label: {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SessionsV2Theme.accent)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Merge pull request to main")
                    .accessibilityHint("Asks for confirmation before merging.")
                }
                .alert("Merge to main?", isPresented: $showingMergeConfirm) {
                    Button("Merge anyway", role: .destructive) { Task { await merge() } }
                    Button("Open PR instead") { showingMergeConfirm = false }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will commit to your local main branch.")
                }
            }
            .padding(16)
        }
    }

    private func statePill(_ state: PRStatus.State) -> some View {
        Text(state.rawValue.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(stateColor(state).opacity(0.18), in: Capsule())
            .foregroundStyle(stateColor(state))
    }

    private func stateColor(_ state: PRStatus.State) -> Color {
        switch state {
        case .open:   return .green
        case .merged: return .purple
        case .closed: return .red
        case .draft:  return .secondary
        }
    }

    private func checksGlyph(_ rollup: String) -> String {
        switch rollup.lowercased() {
        case "success", "passed":        return "checkmark.circle"
        case "failure", "failed", "error": return "xmark.circle"
        case "pending", "running", "in_progress", "queued":
            return "clock.arrow.circlepath"
        case "neutral", "skipped":       return "minus.circle"
        default:                          return "questionmark.circle"
        }
    }

    private func checksColor(_ rollup: String) -> Color {
        switch rollup.lowercased() {
        case "success", "passed":        return .green
        case "failure", "failed", "error": return .red
        case "pending", "running", "in_progress", "queued":
            return SessionsV2Theme.warn
        default:                          return .secondary
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        self.pr = await client.fetchPR(sessionId: session.id)
        isLoading = false
    }

    @MainActor
    private func createPR() async {
        isCreating = true
        bannerMessage = "Creating PR…"
        defer { isCreating = false }
        let result = await client.createPR(sessionId: session.id)
        bannerMessage = result == nil ? "Failed — see logs" : "PR created"
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        bannerMessage = nil
        await refresh()
    }

    @MainActor
    private func merge() async {
        bannerMessage = "Merging…"
        let ok = await client.merge(sessionId: session.id)
        bannerMessage = ok ? "Merged" : "Merge failed — open PR or resolve on Mac"
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        bannerMessage = nil
    }
}

extension AgentControlClient {
    @MainActor
    public func fetchPR(sessionId: UUID) async -> PRStatus? {
        guard let host, let token else { return nil }
        guard let url = URL(string: "http://\(host):\(httpPort)/sessions/\(sessionId.uuidString)/pr") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            // Daemon returns either {"pr": null} or a PRStatus directly. Handle both.
            if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               envelope["pr"] is NSNull {
                return nil
            }
            return try? JSONDecoder().decode(PRStatus.self, from: data)
        } catch {
            return nil
        }
    }

    @MainActor
    @discardableResult
    public func createPR(sessionId: UUID) async -> String? {
        let body = (try? JSONEncoder().encode(CreatePRRequest())) ?? Data()
        guard let host, let token,
              let url = URL(string: "http://\(host):\(httpPort)/sessions/\(sessionId.uuidString)/create-pr") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 60
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return obj?["url"] as? String
        } catch {
            return nil
        }
    }

    @MainActor
    @discardableResult
    public func merge(sessionId: UUID) async -> Bool {
        guard let host, let token,
              let url = URL(string: "http://\(host):\(httpPort)/sessions/\(sessionId.uuidString)/merge") else {
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 200 {
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                return (obj?["ok"] as? Bool) == true
            }
            return false
        } catch {
            return false
        }
    }
}
