import SwiftUI
import ClawdmeterShared

/// Single-screen iPhone UI. If the user has pasted a token, we show the
/// usage meters. Otherwise we route them into the Settings sheet to enter
/// one.
struct ContentView: View {
    @ObservedObject var model: UsageModel
    @State private var showingSettings: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Clawdmeter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .refreshable {
                model.forcePoll()
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.tokenProvider.hasToken {
            unauthenticatedCard
        } else if model.needsReauth {
            reauthCard
        } else if let usage = model.usage {
            UsageCard(title: "Current session", percent: usage.sessionPct, resetDate: Date(timeIntervalSince1970: TimeInterval(usage.sessionEpoch)), kind: .session)
                .padding(.top, 8)
            UsageCard(title: "Weekly limits", percent: usage.weeklyPct, resetDate: Date(timeIntervalSince1970: TimeInterval(usage.weeklyEpoch)), kind: .weekly)
            HStack {
                Text("Last updated ")
                    + Text(usage.updatedAt, style: .relative)
                    + Text(" ago")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        } else {
            loadingCard
        }
    }

    // MARK: - Empty states

    private var unauthenticatedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Waiting for your Mac")
                .font(.title2.bold())
            Text("Open Clawdmeter on your Mac while signed into the same Apple ID — your Claude token will sync over iCloud Keychain and this screen will fill in automatically.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button(action: { model.forcePoll() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.top, 4)
            Button("Paste token instead") { showingSettings = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 16)
    }

    private var reauthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reconnect")
                .font(.title2.bold())
            Text("Your Anthropic token expired. Open Settings to paste a fresh one.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Open Settings") { showingSettings = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 16)
    }

    private var loadingCard: some View {
        HStack {
            ProgressView()
            Text("Connecting…").foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 16)
    }
}

// MARK: - Usage card

private struct UsageCard: View {
    enum Kind { case session, weekly }

    let title: String
    let percent: Int
    let resetDate: Date
    let kind: Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())

            ProgressView(value: Double(min(max(percent, 0), 100)) / 100.0)
                .tint(barColor)

            HStack {
                Text("\(percent)% used")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                (Text("Resets ") + Text(resetDate, style: .relative))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var barColor: Color {
        switch kind {
        case .session: return Color(red: 0xd9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .weekly:  return .accentColor
        }
    }
}
