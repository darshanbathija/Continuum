import SwiftUI
import AppKit
import ClawdmeterShared

struct OpenCodeAuthSetupRequest: Identifiable, Equatable {
    let command: OpencodeSetupSheet.Command
    let providerID: String
    let providerName: String

    var id: String { "\(command.id)-\(providerID)" }
}

/// Native provider picker for OpenCode auth — replaces the interactive
/// terminal picker whose hover-reveal "+" vanishes when you move to click it.
struct OpenCodeProviderPickerSheet: View {
    @Environment(\.tahoe) private var t
    @Environment(\.dismiss) private var dismiss

    var onSelect: (OpenCodeAuthSetupRequest) -> Void

    @State private var search = ""
    @State private var providers: [OpenCodeProviderEntry] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var hoveredProviderID: String?
    @State private var closeHovered = false
    @State private var clearSearchHovered = false

    private var connectedProviderIDs: Set<String> {
        let keys = OpencodeProcessManager.shared.authStatus?.keys.map { $0 } ?? []
        return Set(keys.map { $0.lowercased() })
    }

    private var filteredProviders: [OpenCodeProviderEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return providers }
        return providers.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            providerList
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .background(t.surfaceSolid)
        .background(MacSheetChromeSuppressor())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar(.hidden, for: .windowToolbar)
        .task { await loadProviders() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Connect provider")
                .font(TahoeFont.body(16, weight: .bold))
                .foregroundStyle(t.fg)
            Spacer()
            Button {
                dismiss()
            } label: {
                TahoeIcon("x", size: 12, weight: .bold)
                    .foregroundStyle(closeHovered ? t.fg : t.fg3)
                    .frame(width: 30, height: 30)
                    .background(
                        closeHovered ? t.hair2 : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .onHover { closeHovered = $0 }
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(t.fg3)
            TextField("Search providers", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: {
                    TahoeIcon("x", size: 11, weight: .bold)
                        .foregroundStyle(clearSearchHovered ? t.fg2 : t.fg3)
                        .frame(width: 22, height: 22)
                        .background(
                            clearSearchHovered ? t.hair2 : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .onHover { clearSearchHovered = $0 }
                .help("Clear search")
            }
        }
        .font(TahoeFont.body(13))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(t.hair2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var providerList: some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading providers…")
                    .font(TahoeFont.body(12.5))
                    .foregroundStyle(t.fg3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(loadError)
                    .font(TahoeFont.body(12.5))
                    .foregroundStyle(t.fg3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button("Retry") {
                    Task { await loadProviders(force: true) }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredProviders.isEmpty {
            Text("No providers match \"\(search)\"")
                .font(TahoeFont.body(12.5))
                .foregroundStyle(t.fg3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredProviders) { provider in
                        providerRow(provider)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private func providerRow(_ provider: OpenCodeProviderEntry) -> some View {
        let isConnected = connectedProviderIDs.contains(provider.id.lowercased())
        let isHovered = hoveredProviderID == provider.id

        return HStack(spacing: 12) {
            Button {
                select(provider)
            } label: {
                HStack(spacing: 12) {
                    providerGlyph(for: provider)
                    Text(provider.name)
                        .font(TahoeFont.body(13.5, weight: .medium))
                        .foregroundStyle(t.fg)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isConnected {
                connectedBadge
            } else {
                connectButton(for: provider, isHovered: isHovered)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground(isHovered: isHovered), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            hoveredProviderID = hovering ? provider.id : nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("opencode.provider.\(provider.id)")
    }

    private var connectedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("Connected")
                .font(TahoeFont.body(11.5, weight: .semibold))
        }
        .foregroundStyle(.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 44, minHeight: 44)
    }

    private func connectButton(for provider: OpenCodeProviderEntry, isHovered: Bool) -> some View {
        Button {
            select(provider)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isHovered ? Color.white : t.fg)
                .frame(width: 44, height: 44)
                .background(
                    isHovered ? t.accent : t.hair2,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isHovered ? t.accent : t.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .help("Connect \(provider.name)")
        .accessibilityLabel("Connect \(provider.name)")
        .accessibilityIdentifier("opencode.provider.\(provider.id).connect")
    }

    private func providerGlyph(for provider: OpenCodeProviderEntry) -> some View {
        OpenCodeProviderLogoView(providerId: provider.id, fallbackLabel: provider.name, size: 28)
    }

    private func rowBackground(isHovered: Bool) -> Color {
        isHovered ? t.hair2 : Color.clear
    }

    private var footer: some View {
        HStack {
            Text("\(filteredProviders.count) provider\(filteredProviders.count == 1 ? "" : "s")")
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func select(_ provider: OpenCodeProviderEntry) {
        onSelect(
            OpenCodeAuthSetupRequest(
                command: .signIn,
                providerID: provider.id,
                providerName: provider.name
            )
        )
        dismiss()
    }

    @MainActor
    private func loadProviders(force: Bool = false) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        if force {
            UserDefaults.standard.removeObject(forKey: "clawdmeter.opencode.providerCatalog.v1")
            UserDefaults.standard.removeObject(forKey: "clawdmeter.opencode.providerCatalogDate.v1")
        }

        await OpencodeProcessManager.shared.refreshAuthStatus()
        let fetched = await OpenCodeProviderCatalog.fetchProviders()
        if fetched.isEmpty {
            loadError = "Couldn't load the provider list. Check your network connection and try again."
        } else {
            providers = fetched
            await OpenCodeProviderLogoLoader.shared.preload(providerIds: fetched.map(\.id))
        }
    }
}

/// Hides the macOS sheet chrome close circle so the in-content Tahoe X is
/// the only dismiss affordance.
private struct MacSheetChromeSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        func attach(to view: NSView) {
            DispatchQueue.main.async {
                guard let window = view.window else { return }
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
            }
        }
    }
}
