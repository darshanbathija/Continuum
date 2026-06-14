import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import ClawdmeterShared

/// Locks the Quiet Black Workbench palette + geometry from DESIGN.md. SwiftUI
/// `Color` is Equatable, so we can assert exact hex values by comparing against
/// `ContinuumTokens.hex(...)`. These guard against accidental drift back toward
/// the old terra-cotta/glass system.
#if canImport(SwiftUI)
final class ContinuumTokenTests: XCTestCase {

    func test_neutralPalette_matchesDesignSpec() {
        XCTAssertEqual(ContinuumTokens.bg,       ContinuumTokens.hex(0x050507))
        XCTAssertEqual(ContinuumTokens.surface1, ContinuumTokens.hex(0x0D0E11))
        XCTAssertEqual(ContinuumTokens.surface2, ContinuumTokens.hex(0x131418))
        XCTAssertEqual(ContinuumTokens.surface3, ContinuumTokens.hex(0x1A1B1F))
        XCTAssertEqual(ContinuumTokens.modal,    ContinuumTokens.hex(0x202126))
        XCTAssertEqual(ContinuumTokens.fg,  ContinuumTokens.white(0.94))
        XCTAssertEqual(ContinuumTokens.fg2, ContinuumTokens.white(0.62))
        XCTAssertEqual(ContinuumTokens.fg3, ContinuumTokens.white(0.40))
        XCTAssertEqual(ContinuumTokens.fg4, ContinuumTokens.white(0.26))
        XCTAssertEqual(ContinuumTokens.hairline,  ContinuumTokens.white(0.085))
        XCTAssertEqual(ContinuumTokens.hairline2, ContinuumTokens.white(0.05))
        XCTAssertEqual(ContinuumTokens.focus,     ContinuumTokens.white(0.20))
        XCTAssertEqual(ContinuumTokens.selection, ContinuumTokens.white(0.075))
    }

    func test_semanticState_matchesDesignSpec() {
        XCTAssertEqual(ContinuumTokens.live,   ContinuumTokens.hex(0x3CC07A))
        XCTAssertEqual(ContinuumTokens.warn,   ContinuumTokens.hex(0xD6A23B))
        XCTAssertEqual(ContinuumTokens.error,  ContinuumTokens.hex(0xE5534B))
        XCTAssertEqual(ContinuumTokens.paused, ContinuumTokens.hex(0x8A8A8A))
    }

    func test_primaryButton_isLightNotChromatic() {
        XCTAssertEqual(ContinuumTokens.primaryFill, ContinuumTokens.white(0.92))
        XCTAssertEqual(ContinuumTokens.primaryText, ContinuumTokens.hex(0x0A0A0C))
    }

    func test_providerDots_matchRationedPalette() {
        XCTAssertEqual(TahoeProvider.claude.dot,   ContinuumTokens.hex(0xD97757)) // terra-cotta, only here
        XCTAssertEqual(TahoeProvider.codex.dot,    ContinuumTokens.hex(0x8A9099)) // graphite
        XCTAssertEqual(TahoeProvider.gemini.dot,   ContinuumTokens.hex(0x5C9DFF)) // Antigravity blue
        XCTAssertEqual(TahoeProvider.opencode.dot, ContinuumTokens.hex(0x9B87D4)) // muted violet
        XCTAssertEqual(TahoeProvider.openrouter.dot, ContinuumTokens.hex(0x6B8AFF)) // periwinkle blue
        XCTAssertEqual(TahoeProvider.cursor.dot,   ContinuumTokens.hex(0x7FA8B5)) // cool steel
        // All providers must be mutually distinct so the picker reads.
        let dots = [TahoeProvider.claude, .codex, .gemini, .opencode, .openrouter, .cursor].map(\.dot)
        XCTAssertEqual(Set(dots).count, dots.count)
    }

    func test_liveSessionActivityIndicator_usesOrangeWorkingStream() {
        XCTAssertEqual(LiveSessionActivityIndicator.packetColor, ContinuumTokens.hex(0xD97757))
        XCTAssertNotEqual(LiveSessionActivityIndicator.packetColor, TahoeProvider.codex.dot)
    }

    func test_meterFill_T2Gradients_matchDesignSpec() {
        XCTAssertEqual(TahoeProvider.claude.meterFill, [ContinuumTokens.hex(0xE68A66), ContinuumTokens.hex(0xC9603F)])
        XCTAssertEqual(TahoeProvider.codex.meterFill,  [ContinuumTokens.hex(0x9AA3AD), ContinuumTokens.hex(0x6E7681)])
        XCTAssertEqual(TahoeProvider.gemini.meterFill, [ContinuumTokens.hex(0x79ADFF), ContinuumTokens.hex(0x4A86E8)])
    }

    func test_radiusScale_isTight() {
        XCTAssertEqual(ContinuumTokens.Radius.row, 4)
        XCTAssertEqual(ContinuumTokens.Radius.button, 5)
        XCTAssertEqual(ContinuumTokens.Radius.card, 6)
        XCTAssertEqual(ContinuumTokens.Radius.modal, 8)
        XCTAssertEqual(ContinuumTokens.Radius.rail, 3)
        XCTAssertEqual(ContinuumTokens.Radius.pill, 999)
        // The legacy TahoeRadius is repointed onto the tight scale.
        XCTAssertEqual(TahoeRadius.s, 5)
        XCTAssertEqual(TahoeRadius.m, 6)
        XCTAssertEqual(TahoeRadius.l, 8)
    }

    func test_railWarnTick_andMetricColorThresholds() {
        XCTAssertEqual(ContinuumTokens.warnTickFraction, 0.80, accuracy: 0.0001)
        // The big % adopts warn/error past the thresholds; provider fill before.
        XCTAssertEqual(ContinuumTokens.metricColor(percent: 50),  ContinuumTokens.fg)
        XCTAssertEqual(ContinuumTokens.metricColor(percent: 79),  ContinuumTokens.fg)
        XCTAssertEqual(ContinuumTokens.metricColor(percent: 80),  ContinuumTokens.warn)
        XCTAssertEqual(ContinuumTokens.metricColor(percent: 100), ContinuumTokens.warn)
        XCTAssertEqual(ContinuumTokens.metricColor(percent: 101), ContinuumTokens.error)
    }

    func test_heartbeat_isNilUnderReduceMotion() {
        XCTAssertNil(ContinuumMotion.heartbeat(reduceMotion: true))
        XCTAssertNotNil(ContinuumMotion.heartbeat(reduceMotion: false))
    }

    func test_lightPalette_invertsNeutralStack() {
        let light = ContinuumTokens.lightPalette
        XCTAssertEqual(light.bg, ContinuumTokens.hex(0xF4F6FA))
        XCTAssertEqual(light.surface1, ContinuumTokens.hex(0xFFFFFF))
        XCTAssertEqual(light.surface2, ContinuumTokens.hex(0xF3F4F7))
        XCTAssertEqual(light.fg, ContinuumTokens.ink(0.95))
        XCTAssertEqual(light.fg2, ContinuumTokens.ink(0.66))
        XCTAssertEqual(light.hairline, ContinuumTokens.ink(0.10))
        XCTAssertEqual(light.primaryFill, ContinuumTokens.hex(0x0A0A0C))
        XCTAssertEqual(light.primaryText, ContinuumTokens.white(0.98))
        // Semantic + provider colors stay identical across appearances.
        XCTAssertEqual(light.live, ContinuumTokens.live)
        XCTAssertEqual(light.warn, ContinuumTokens.warn)
        XCTAssertEqual(light.error, ContinuumTokens.error)
    }

    func test_paletteResolver_defaultsToDark() {
        XCTAssertEqual(ContinuumTokens.palette(for: .dark).bg, ContinuumTokens.bg)
        XCTAssertEqual(ContinuumTokens.palette(for: .light).bg, ContinuumTokens.lightPalette.bg)
    }

    @MainActor
    func test_tahoeTokens_make_respectsAppearance() {
        let store = TahoeThemeStore(appearance: .light)
        let tokens = TahoeTokens.make(from: store)
        XCTAssertFalse(tokens.dark)
        XCTAssertEqual(tokens.pageBg, ContinuumTokens.lightPalette.bg)
        XCTAssertEqual(tokens.fg, ContinuumTokens.lightPalette.fg)
        XCTAssertEqual(tokens.metricColor(percent: 50), ContinuumTokens.lightPalette.fg)
    }
    func test_crossCuttingAccentRGB_isRecolored() {
        XCTAssertEqual(AgentKindUI.accentRGB(for: .claude).r, 0xD9)
        let codex = AgentKindUI.accentRGB(for: .codex)
        XCTAssertEqual([codex.r, codex.g, codex.b], [0x8A, 0x90, 0x99]) // graphite, was blue
        let gemini = AgentKindUI.accentRGB(for: .gemini)
        XCTAssertEqual([gemini.r, gemini.g, gemini.b], [0x5C, 0x9D, 0xFF]) // Antigravity, was google-blue
    }
}
#endif
