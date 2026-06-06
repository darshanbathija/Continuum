import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Completion chime sound packs. Sessions v2 Phase 11 / T20.
///
/// Bundles four packs as `.caf` resources (added in v2.0.1 once audio
/// licensing is sorted — for now the player handles the missing-asset
/// case gracefully). Users pick a pack in Settings → Sounds. Off during
/// quiet hours (Settings → Sounds → Quiet hours window).
public enum ChimePack: String, CaseIterable, Codable, Sendable {
    case off            = "off"
    case sfMuni         = "sfMuni"      // SF Muni "doors closing"
    case nycMta         = "nycMta"      // NYC subway chime
    case bell           = "bell"        // Gentle bell
    case fanfare        = "fanfare"     // Triumphant fanfare

    public var displayName: String {
        switch self {
        case .off:     return "Off"
        case .sfMuni:  return "SF Muni"
        case .nycMta:  return "NYC MTA"
        case .bell:    return "Gentle Bell"
        case .fanfare: return "Triumphant Fanfare"
        }
    }
}

/// Per-user chime configuration: pack + quiet-hours window.
public struct ChimeSettings: Codable, Sendable {
    public var pack: ChimePack
    /// Quiet hours: when (now-of-day ≥ quietStart || now-of-day < quietEnd)
    /// the chime is silent. Stored as minutes since midnight (0..1440).
    public var quietStartMinutes: Int
    public var quietEndMinutes: Int

    public init(pack: ChimePack = .bell, quietStartMinutes: Int = 22 * 60, quietEndMinutes: Int = 7 * 60) {
        self.pack = pack
        self.quietStartMinutes = quietStartMinutes
        self.quietEndMinutes = quietEndMinutes
    }

    public func isQuietNow(date: Date = Date()) -> Bool {
        let cal = Calendar.current
        let nowMin = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        if quietStartMinutes <= quietEndMinutes {
            return nowMin >= quietStartMinutes && nowMin < quietEndMinutes
        } else {
            // Wraps midnight (e.g., 22:00 → 07:00).
            return nowMin >= quietStartMinutes || nowMin < quietEndMinutes
        }
    }
}

/// Cross-platform audio player. Sessions v2 Phase 11.
@MainActor
public final class ChimeAudioPlayer: ObservableObject {
    public static let shared = ChimeAudioPlayer()

    @Published public var settings: ChimeSettings {
        didSet { persist() }
    }

    private static let storageKey = "clawdmeter.chime.settings"

    #if canImport(AVFoundation)
    private var player: AVAudioPlayer?
    #endif

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let settings = try? JSONDecoder().decode(ChimeSettings.self, from: data) {
            self.settings = settings
        } else {
            self.settings = ChimeSettings()
        }
    }

    /// Play the configured chime. No-op when pack is off or during quiet hours.
    /// Falls back to system sound when the bundled `.caf` is missing (v2.0
    /// ships the player wired; v2.0.1 bundles the audio assets).
    public func playCompletion() {
        guard settings.pack != .off, !settings.isQuietNow() else { return }
        #if canImport(AVFoundation)
        let resourceName = settings.pack.rawValue
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "caf") {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                player.play()
                self.player = player
            } catch {
                // Best-effort fallback to system sound.
                playFallbackSound()
            }
        } else {
            playFallbackSound()
        }
        #endif
    }

    #if canImport(AudioToolbox)
    private func playFallbackSound() {
        // System sound 1336 = "Tink" — short, neutral, ubiquitous.
        // Available on iOS + macOS; watchOS doesn't expose AudioServices
        // so this is a no-op there (the watch app will silently skip the
        // chime, which is fine — watchOS has its own haptics-driven
        // completion signal via WKInterfaceDevice.play(_:) in v2.1).
        AudioServicesPlaySystemSound(1336)
    }
    #else
    private func playFallbackSound() { /* no system sound API */ }
    #endif

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
