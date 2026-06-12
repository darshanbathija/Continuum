import SwiftUI
import ClawdmeterShared

// MARK: - Logo

/// Logo tile for an upstream OpenCode provider. Loads the Models.dev PNG
/// and falls back to a monogram when the asset is missing offline.
struct OpencodeProviderLogoView: View {
    @Environment(\.tahoe) private var t

    let provider: OpencodeSupportedProvider
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: max(6, size * 0.24), style: .continuous)
            .fill(t.glassTintHi.opacity(0.55))
            .overlay {
                RoundedRectangle(cornerRadius: max(6, size * 0.24), style: .continuous)
                    .stroke(t.hairline, lineWidth: 0.5)
            }
            .overlay {
                if provider.isCustomEntry {
                    TahoeIcon("sparkles", size: size * 0.42, weight: .semibold)
                        .foregroundStyle(t.fg2)
                } else {
                    AsyncImage(url: provider.logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .padding(size * 0.16)
                        default:
                            monogram
                        }
                    }
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var monogram: some View {
        Text(provider.name.prefix(1).uppercased())
            .font(TahoeFont.body(size * 0.42, weight: .bold))
            .foregroundStyle(t.fg2)
    }
}

// MARK: - OpenCode row extras

/// Compact extras rendered under the connected OpenCode row — upstream
/// auth chips, a custom-provider shortcut, and the catalog picker entry.
struct OpencodeProviderExtrasSection: View {
    @Environment(\.tahoe) private var t

    var onCustomProviderConnect: () -> Void
    var onShowMoreProviders: () -> Void

    @State private var connectedProviders: [OpencodeSupportedProvider] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(connectedProviders) { provider in
                connectedRow(provider)
            }
            customProviderRow
            showMoreButton
        }
        .padding(.leading, 40)
        .task { await refreshConnected() }
        .onReceive(NotificationCenter.default.publisher(for: .opencodeAuthChanged)) { _ in
            Task { await refreshConnected() }
        }
        .accessibilityIdentifier("settings.provider.opencode.extras")
    }

    private func connectedRow(_ provider: OpencodeSupportedProvider) -> some View {
        HStack(spacing: 10) {
            OpencodeProviderLogoView(provider: provider, size: 22)
            Text(provider.name)
                .font(TahoeFont.body(12, weight: .semibold))
                .foregroundStyle(t.fg)
            Text("Connected")
                .font(TahoeFont.body(10, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12), in: Capsule())
            Spacer(minLength: 0)
        }
    }

    private var customProviderRow: some View {
        HStack(alignment: .center, spacing: 12) {
            OpencodeProviderLogoView(provider: .customEntry, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Custom provider")
                        .font(TahoeFont.body(13.5, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text("Custom")
                        .font(TahoeFont.body(10, weight: .semibold))
                        .foregroundStyle(t.fg3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(t.hair2, in: Capsule())
                }
                Text("Add an OpenAI-compatible provider by base URL.")
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg3)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button(action: ContinuumAnalytics.wrapButton("opencode_custom_provider_connect", onCustomProviderConnect)) {
                HStack(spacing: 4) {
                    TahoeIcon("plus", size: 10, weight: .bold)
                    Text("Connect")
                }
                .font(TahoeFont.body(12, weight: .semibold))
                .foregroundStyle(t.fg)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(t.hairline, lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.provider.opencode.custom.connect")
        }
    }

    private var showMoreButton: some View {
        Button(action: ContinuumAnalytics.wrapButton("opencode_show_more_providers", onShowMoreProviders)) {
            Text("Show more providers")
                .font(TahoeFont.body(12, weight: .semibold))
                .foregroundStyle(t.accent)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.provider.opencode.showMore")
    }

    private func refreshConnected() async {
        let ids = Set(await OpencodeAuthFile.shared.providerIds())
        let snapshot = await OpencodeSupportedProviderCatalogStore.shared.currentSnapshot()
        let byID = Dictionary(uniqueKeysWithValues: snapshot.all.map { ($0.id, $0) })
        connectedProviders = ids
            .sorted()
            .compactMap { id in
                if id == OpencodeSupportedProvider.customEntryID { return nil }
                return byID[id] ?? OpencodeSupportedProvider(id: id, name: OpencodeAuthFile.defaultDisplayName(for: id))
            }
    }
}

// MARK: - Connect provider overlay

struct OpencodeConnectProvidersOverlay: View {
    @Environment(\.tahoe) private var t
    @Environment(\.dismiss) private var dismiss

    var onSelectProvider: (OpencodeSupportedProvider) -> Void

    @State private var searchText = ""
    @State private var snapshot: OpencodeSupportedProviderCatalog.Snapshot?
    @State private var hoveredID: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if loading, snapshot == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading providers…")
                                .font(TahoeFont.body(12))
                                .foregroundStyle(t.fg3)
                        }
                        .padding(.horizontal, 16)
                    } else if let snapshot {
                        if !filteredFeatured(snapshot.featured).isEmpty {
                            section(title: "Popular", providers: filteredFeatured(snapshot.featured))
                        }
                        let other = filteredOther(snapshot.more)
                        if !other.isEmpty {
                            section(title: "Other", providers: other)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .frame(width: 420, height: 520)
        .background(t.surfaceSolid)
        .task { await loadCatalog() }
    }

    private var header: some View {
        HStack {
            Text("Connect provider")
                .font(TahoeFont.body(15, weight: .bold))
                .foregroundStyle(t.fg)
            Spacer()
            Button(action: ContinuumAnalytics.wrapButton("opencode_provider_catalog_close", { dismiss() })) {
                TahoeIcon("xmark", size: 11, weight: .bold)
                    .foregroundStyle(t.fg3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TahoeIcon("search", size: 12, weight: .medium)
                .foregroundStyle(t.fg3)
            TextField("Search providers", text: $searchText)
                .textFieldStyle(.plain)
                .font(TahoeFont.body(13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(t.hair2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func section(title: String, providers: [OpencodeSupportedProvider]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(TahoeFont.body(11, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(t.fg3)
                .padding(.horizontal, 16)
            ForEach(providers) { provider in
                providerRow(provider)
            }
        }
    }

    private func providerRow(_ provider: OpencodeSupportedProvider) -> some View {
        let hovered = hoveredID == provider.id
        return Button(action: ContinuumAnalytics.wrapButton("opencode_provider_select", {
            onSelectProvider(provider)
            dismiss()
        })) {
            HStack(spacing: 12) {
                OpencodeProviderLogoView(provider: provider, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(TahoeFont.body(13, weight: .semibold))
                            .foregroundStyle(t.fg)
                        if provider.isCustomEntry {
                            Text("Custom")
                                .font(TahoeFont.body(10, weight: .semibold))
                                .foregroundStyle(t.fg3)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(t.hair2, in: Capsule())
                        }
                    }
                    if let blurb = provider.tagline, !provider.isCustomEntry {
                        Text(blurb)
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if hovered {
                    TahoeIcon("plus", size: 12, weight: .bold)
                        .foregroundStyle(t.fg2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(hovered ? t.glassTintHi.opacity(0.45) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredID = isHovered ? provider.id : nil
        }
        .accessibilityIdentifier("settings.provider.opencode.overlay.\(provider.id)")
    }

    private func filteredFeatured(_ providers: [OpencodeSupportedProvider]) -> [OpencodeSupportedProvider] {
        filter(providers)
    }

    private func filteredOther(_ providers: [OpencodeSupportedProvider]) -> [OpencodeSupportedProvider] {
        var list = filter(providers)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty || OpencodeSupportedProvider.customEntry.name.localizedCaseInsensitiveContains(query) {
            list.insert(OpencodeSupportedProvider.customEntry, at: 0)
        }
        return list
    }

    private func filter(_ providers: [OpencodeSupportedProvider]) -> [OpencodeSupportedProvider] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return providers }
        return providers.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private func loadCatalog() async {
        loading = true
        defer { loading = false }
        snapshot = await OpencodeSupportedProviderCatalogStore.shared.currentSnapshot()
    }
}

// MARK: - API key sheet

struct OpencodeProviderAPIKeySheet: View {
    @Environment(\.tahoe) private var t
    @Environment(\.dismiss) private var dismiss

    let provider: OpencodeSupportedProvider
    var opencodeCLIAvailable: Bool = false
    var onTerminalLogin: (() -> Void)?
    var onSaved: () -> Void

    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Text("Paste an API key for \(provider.name). Keys are stored in ~/.local/share/opencode/auth.json, the same file OpenCode uses.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("API key")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.fg2)
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            if let message {
                Text(message)
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(messageIsError ? Color.red : t.fg3)
            }
            HStack {
                if opencodeCLIAvailable, let onTerminalLogin {
                    Button("Sign in via opencode", action: ContinuumAnalytics.wrapButton("opencode_sign_in_via_cli", {
                        dismiss()
                        onTerminalLogin()
                    }))
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("Cancel", action: ContinuumAnalytics.wrapButton("opencode_api_key_cancel", { dismiss() }))
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? "Saving…" : "Save", action: ContinuumAnalytics.wrapButton("opencode_api_key_save", {
                    Task { await save() }
                }))
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(t.surfaceSolid)
    }

    private var header: some View {
        HStack(spacing: 10) {
            OpencodeProviderLogoView(provider: provider, size: 28)
            Text(provider.name)
                .font(TahoeFont.body(18, weight: .bold))
                .foregroundStyle(t.fg)
            Spacer()
        }
    }

    private func save() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await OpencodeAuthFile.shared.setAPIKey(providerId: provider.id, key: key)
            NotificationCenter.default.post(name: .opencodeAuthChanged, object: nil)
            message = "Saved — \(provider.name) is connected."
            messageIsError = false
            onSaved()
            dismiss()
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }
}
