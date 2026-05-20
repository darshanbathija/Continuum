import SwiftUI
import ClawdmeterShared

/// v0.7.11 — segmented permission-mode picker matching the
/// Claude/Codex/Gemini agent strip's visual weight. Replaces the
/// compact `PermissionModeChip` menu on the composer bottom bar so the
/// active mode reads at a glance instead of hiding behind a chevron.
///
/// 3 modes in empty-state composer (Ask / Edits / Plan); 4 modes in
/// bound sessions (… + Bypass). Segmented picker auto-sizes from
/// content so the bar layout stays compact when Bypass is hidden.
struct PermissionModeSegmented: View {
    let mode: PermissionMode
    let availableModes: [PermissionMode]
    let onChange: (PermissionMode) -> Void

    var body: some View {
        Picker(
            "Permission",
            selection: Binding(
                get: { mode },
                set: { newMode in
                    guard newMode != mode else { return }
                    onChange(newMode)
                }
            )
        ) {
            ForEach(availableModes, id: \.self) { candidate in
                Text(candidate.shortLabel).tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Permission mode — ⌘⇧1-4 to switch")
    }
}
