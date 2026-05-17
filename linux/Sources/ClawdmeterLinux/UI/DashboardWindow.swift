import Foundation
import ClawdmeterShared

/// Linux port of `apple/ClawdmeterMac/DashboardView.swift`.
///
/// Phase 5 scaffolding: window structure + LinuxUIWidget composition only.
/// Real data binding wires up to UsageHistoryStore (post D8 actor migration)
/// + CairoBarChart for the daily-spend chart.
public final class DashboardWindow {

    public let window: LinuxWindow

    public init() {
        let win = LinuxUI.window(title: "Clawdmeter")
        win.size = (width: 980, height: 1100)
        self.window = win
        win.content = buildContent()
    }

    public func present() {
        window.present()
    }

    private func buildContent() -> LinuxUIWidget {
        // Top-level VStack: header row + provider columns + analytics row.
        return LinuxUI.box(.vertical, spacing: 16, children: [
            buildHeader(),
            buildProviderColumns(),
            buildAnalyticsRow()
        ])
    }

    private func buildHeader() -> LinuxUIWidget {
        // [Clawdmeter title] [spacer] [Sync with iPhone (suggested button)]
        return LinuxUI.box(.horizontal, spacing: 12, children: [
            LinuxUI.text("Clawdmeter", style: .title),
            LinuxUI.button("Sync with iPhone", style: .suggested, onClick: {
                // TODO(Phase 5): present PairingWindow as popover. Will need
                // a weak handle to the parent window via a sendable wrapper
                // (window reference can't cross actor boundary directly).
            })
        ])
    }

    private func buildProviderColumns() -> LinuxUIWidget {
        // [Claude card] [Codex card]
        return LinuxUI.box(.horizontal, spacing: 12, children: [
            ProviderCard(provider: .claude).rootWidget(),
            ProviderCard(provider: .codex).rootWidget()
        ])
    }

    private func buildAnalyticsRow() -> LinuxUIWidget {
        // [Totals grid] [Daily-spend chart] [By-repo list]
        return LinuxUI.box(.horizontal, spacing: 12, children: [
            // TODO(Phase 5): real AnalyticsView port using LinuxUI primitives
            LinuxUI.text("Past 30d totals  $ — / — K tokens", style: .body),
            LinuxUI.drawingArea(draw: { _, _, _ in
                // TODO(Phase 5): CairoBarChart.render(...) here
            }),
            LinuxUI.list(itemCount: 0, rowBuilder: { _ in
                LinuxUI.text("(no repos yet)", style: .caption)
            })
        ])
    }
}

/// One provider's column (Claude or Codex). Live percent + weekly + auto-revive controls.
struct ProviderCard {
    let provider: CairoGaugeRenderer.Provider

    func rootWidget() -> LinuxUIWidget {
        let title = provider == .claude ? "Claude" : "Codex"
        return LinuxUI.box(.vertical, spacing: 8, children: [
            LinuxUI.text(title, style: .headline),
            LinuxUI.text("Session — %", style: .body),
            LinuxUI.text("Weekly — %", style: .body),
            LinuxUI.button("Force poll", style: .standard, onClick: {
                // TODO(Phase 5): dispatch shared UsagePoller force-poll
            })
        ])
    }
}
