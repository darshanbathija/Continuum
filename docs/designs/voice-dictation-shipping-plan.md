# Voice & Dictation Shipping Plan

**Status:** Accepted (product decisions locked)
**Target:** Mac (Continuum / ClawdmeterMac)
**Last updated:** 2026-06-12

Ship Continuum from **in-app composer dictation** (Apple Speech, ⌃M → Code only) to **system-wide dictation** comparable to [Mac Parakeet](https://github.com/moona3k/macparakeet) and [Handy](https://github.com/cjpais/handy), with a **future release** adding a user-selectable, downloadable local model picker.

---

## 0. Baseline (today)

| Layer | Status |
|---|---|
| STT engine | `SpeechDictation` → `SFSpeechRecognizer` + `AVAudioEngine` |
| Model | Apple system speech model for `Locale.current` — **no user choice** |
| In-app targets | Code composer ✅, Chat composer ✅ (mic button only) |
| Global shortcut | ⌃M via `ShortcutOverrideMonitor` — **local monitor, app-focused only** |
| Routing | Always switches to Code tab + `.composerToggleDictation` |
| Settings | Voice tab: shortcut, permissions, recognition info |
| System-wide paste | Not implemented |
| Menu bar dictation agent | Not implemented (menu bar exists for quota gauges only) |

**Key files:**

| File | Role |
|---|---|
| `apple/ClawdmeterMac/AgentControl/SpeechDictation.swift` | STT engine |
| `apple/ClawdmeterMac/Workspace/Composer/ComposerInputCore.swift` | Code composer mic + ⌃M |
| `apple/ClawdmeterMac/Workspace/ChatV2/MacChatV2View.swift` | Chat composer mic (no ⌃M) |
| `apple/ClawdmeterMac/Tahoe/MacRootView.swift` | Shortcut routing (`runGlobalCommand`) |
| `apple/ClawdmeterMac/Tahoe/MacSettingsView.swift` | Voice settings tab |
| `apple/ClawdmeterShared/.../SessionPresentationStore.swift` | Client-local prefs persistence |
| `apple/ClawdmeterMac/AppDelegate.swift` | Existing `NSStatusItem` menu bar infrastructure |

**Known bug to fix opportunistically:** P2-M5 partial transcript duplication in `SpeechDictation` (partial results replace full field each fire rather than incremental merge).

---

## Product decisions (locked)

| # | Decision |
|---|---|
| 1 | **Primary trigger is Fn double-tap** — not ⌃⌥M or another chord |
| 2 | **One gesture, two contexts** — Fn double-tap works both in-app (composer) and system-wide (paste). Same `GlobalDictationCoordinator`; output target depends on which app is focused |
| 3 | **No persistent menu bar mic** — dictation works without a always-visible status item. If needed later, show a **transient** menu bar indicator only while recording or processing (optional, not required for v1 of system-wide) |

**Implications:**

- Fn double-tap requires a **global `CGEvent` tap** from Phase 2 onward (Accessibility permission when pasting outside Continuum).
- ⌃M remains a **secondary in-app shortcut** through Phase 1; once Fn ships, Voice settings can list Fn as primary and ⌃M as optional override.
- **Floating overlay** is the primary visual feedback — not the menu bar.
- Phase 3 "menu bar agent" is **removed**; coordinator still lives in `AppRuntime` so dictation works with the window closed, but triggered only via Fn (and optional ⌃M when Continuum is focused).

---

## 1. Architecture target

```
┌─────────────────────────────────────────────────────────────┐
│                        Triggers                              │
│  Fn double-tap (primary) │ ⌃M (secondary) │ mic button       │
└────────────────────────────┬────────────────────────────────┘
                             ▼
              ┌──────────────────────────────┐
              │  GlobalDictationCoordinator   │  ← app-scoped (AppRuntime)
              │  • Fn tap → start/stop        │
              │  • Continuum focused → composer│
              │  • Other app focused → AX paste│
              └──────────────┬───────────────┘
                             ▼
              ┌──────────────────────────────┐
              │      STTTranscribing          │  ← protocol
              │  AppleSpeech │ WhisperKit │ …  │
              └──────────────┬───────────────┘
                             ▼
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
   Code composer      Chat composer      AX / ⌘V paste
                             +
              Floating overlay (recording / processing)
              [optional transient menu bar mic — defer]
```

**Design principles:**

1. **One coordinator** owns dictation lifecycle; composers and system paste are output sinks.
2. **STT is pluggable** behind a protocol so the future model picker slots in without rewriting hotkeys or paste.
3. **Port patterns, don't copypaste** — Mac Parakeet is GPL-3.0; reimplement from API docs + small reference snippets.
4. **Voice settings tab** is the single surface for shortcut, permissions, mode, and (future) model choice.

---

## 2. Phase 1 — Near term: unified in-app ⌃M

**Goal:** ⌃M toggles dictation in whichever composer is active (Code or Chat). No tab hijacking when Chat is already focused.

> **Note:** Phase 1 ships ⌃M routing as an interim in-app shortcut. Phase 2 makes **Fn double-tap** the primary trigger for both in-app and system-wide; ⌃M becomes optional secondary.

**Effort:** 1–2 days
**Release:** Next minor (e.g. v0.23.x)

### 2.1 Tasks

#### A. Dictation routing

Introduce routing so the global shortcut targets the active composer instead of always forcing Code.

**Option A (recommended):** Small `@MainActor DictationRouter` singleton:

```swift
@MainActor
final class DictationRouter: ObservableObject {
    static let shared = DictationRouter()
    /// Which composer should receive the next toggle.
    enum Target { case active, code, chat }
    func requestToggle(target: Target = .active)
    /// Composers subscribe and call toggleDictation() when targeted.
}
```

**Option B:** Extend notification payload:

```swift
// SessionWorkspaceNotifications.swift
// userInfo: ["target": "active" | "code" | "chat"]
```

#### B. Smart routing in `MacRootView.runGlobalCommand`

Replace current always-Code behavior:

```swift
case "composer.dictation":
    tab = .code
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .composerToggleDictation, object: nil)
    }
```

**New behavior:**

1. If `tab == .chat` and Chat composer is editable → route to Chat, **do not switch tabs**
2. Else if Code tab has an active composer → route to Code
3. Else → switch to `lastDictationTab` (persist in `SessionPresentationStore`) and route there
4. Never switch away from a tab that is actively recording

Persist `lastDictationTab: String?` (`"chat"` | `"code"`) in `SessionPresentationSnapshot`.

#### C. Wire Chat to global shortcut

In `MacChatV2View.ComposerBar`:

- Subscribe to dictation toggle (via router or notification)
- Guard: skip if viewing archived/read-only transcript
- Add local `.keyboardShortcut("m", modifiers: [.control])` on mic button (parity with Code)
- Update tooltip: `"Stop dictation (Ctrl+M)"` / `"Dictate (Ctrl+M)"`

#### D. Centralize shared dictation merge logic

Extract duplicated partial-transcript merge into a shared helper:

```swift
enum DictationTextMerge {
    static func merged(base: String, partial: String) -> String
}
```

Used by both `ComposerInputCore` and `MacChatV2View.ComposerBar`. Fix P2-M5 duplication bug here.

#### E. Voice settings copy update

Clarify in Voice tab:

- "Routes to the active composer (Chat or Code)"
- Default shortcut behavior description

### 2.2 Acceptance criteria

- [x] ⌃M in Chat tab toggles Chat mic without switching to Code
- [x] ⌃M in Code tab toggles Code mic (unchanged)
- [x] ⌃M from Settings/Usage tab routes to last composer tab
- [x] Command palette "Toggle Dictation" follows same routing
- [x] Archived Chat transcript: ⌃M does nothing or shows toast
- [x] UI tests: extend `CodeTabHoverShortcutUITests` + add Chat dictation routing test

### 2.3 Files touched

- `MacRootView.swift`
- `ComposerInputCore.swift`
- `MacChatV2View.swift`
- `SessionWorkspaceNotifications.swift` or new `DictationRouter.swift`
- `SessionPresentationStore.swift` (`lastDictationTab`)
- `MacSettingsView.swift` (copy)
- `SpeechDictation.swift` or new `DictationTextMerge.swift`

---

## 3. Phase 2 — Medium term: Fn double-tap + system-wide dictation

**Goal:** **Fn double-tap** is the single primary trigger — works in Continuum (active composer) and in any other app (paste). Optional system-wide toggle in Voice settings gates external paste; Fn gesture itself is always handled by the global tap once enabled.

**Effort:** 1.5–2 weeks
**Release:** Following minor (e.g. v0.24.x)

### 3.1 New modules

Port/adapt patterns from Mac Parakeet (reimplement, don't copy GPL code):

| Module | Mac Parakeet reference | Responsibility |
|---|---|---|
| `GlobalHotkeyManager` | `HotkeyManager.swift` | `CGEvent` tap; Fn modifier + double-tap detection |
| `HotkeyGestureController` | `HotkeyGestureController.swift` | **`doubleTapOnly` default**; optional PTT modes later |
| `AccessibilityPasteService` | `AccessibilityService.swift` | Read focused element, inject text |
| `GlobalDictationCoordinator` | `DictationFlowCoordinator.swift` | Record → transcribe → paste orchestration |
| `VoicePreferences` | — | Persist toggles + hotkey config |

**Suggested file layout:**

```
apple/ClawdmeterMac/Voice/
  GlobalDictationCoordinator.swift
  GlobalHotkeyManager.swift
  HotkeyGestureController.swift
  AccessibilityPasteService.swift
  VoicePreferences.swift
  STTTranscribing.swift           // protocol
  AppleSpeechTranscriber.swift    // wraps SpeechDictation
  DictationRouter.swift           // from Phase 1
  DictationTextMerge.swift        // from Phase 1
```

### 3.2 STT abstraction (prep for model picker)

```swift
@MainActor
protocol STTTranscribing: AnyObject {
    var partialTranscript: Published<String>.Publisher { get }
    var state: Published<DictationState>.Publisher { get }
    func start(locale: Locale) async throws
    func stop() async -> String
    func cancel()
}

enum DictationState: Equatable {
    case idle, requestingPermission, denied(String), unavailable(String), recording
}
```

- `AppleSpeechTranscriber` wraps existing `SpeechDictation`
- `GlobalDictationCoordinator` depends on `STTTranscribing`, not `SpeechDictation` directly
- In-app composers can migrate to protocol later; not blocking for Phase 2

### 3.3 Fn double-tap global hotkey

**Permissions required:**

| Permission | Status today | Phase 2 |
|---|---|---|
| Microphone | ✅ Have | Required |
| Speech Recognition | ✅ Have | Required |
| Accessibility | ❌ Not used | **Required** (global tap + paste outside Continuum) |

Accessibility: `AXIsProcessTrusted()` + prompt via `AXIsProcessTrustedWithOptions`. No special entitlement; user grants in System Settings.

**Primary trigger (locked):**

| Trigger | Gesture | Scope |
|---|---|---|
| **Fn double-tap** | Double-tap Fn within tap threshold | In-app **and** system-wide — one coordinator |
| ⌃M (secondary) | Control+M | In-app only, when Continuum focused (existing local monitor) |

**Fn gesture mode:** `HotkeyGestureController.Mode.doubleTapOnly` as default — first double-tap starts recording, second double-tap stops and delivers text. Matches Mac Parakeet hands-free dictation.

**Routing on stop (same gesture, context-aware):**

```
Fn double-tap stop
    ├─ frontmost app == Continuum → DictationRouter → active composer (Phase 1)
    └─ frontmost app != Continuum → AccessibilityPasteService (if system-wide enabled)
                                    else toast: "Enable system-wide in Voice settings"
```

**Implementation steps:**

1. `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, ...)` — listen for `flagsChanged` on Fn
2. `HotkeyGestureController(mode: .doubleTapOnly)` — port double-tap state machine from Mac Parakeet
3. Side-specific Fn matching (`ModifierKeyMatcher`) for Apple vs external keyboards
4. On start/stop → `GlobalDictationCoordinator`
5. Handle `tapDisabledByTimeout` / `tapDisabledByUserInput` (auto-recover)
6. Install tap when dictation feature enabled + permissions granted; runs even when window closed (coordinator in `AppRuntime`)

**Local ⌃M monitor (secondary):**

- Existing `ShortcutOverrideMonitor` continues to handle ⌃M when Continuum is focused
- Routes through same `GlobalDictationCoordinator` / `DictationRouter` — never installs a second STT session
- Voice settings: "Also allow Control+M in composer" toggle (default on for backward compatibility)

### 3.4 Paste pipeline

On recording **start**, capture `NSWorkspace.shared.frontmostApplication` (Mac Parakeet "finish-target" model — paste goes to app focused at stop time, refreshed near stop).

On recording **stop**:

1. Transcribe via `STTTranscribing`
2. If frontmost app is Continuum → route to active composer (Phase 1 router)
3. Else → paste via Accessibility:
   - Try `kAXSelectedTextRangeAttribute` + insert at caret
   - Fallback: copy to pasteboard + simulate ⌘V via `CGEvent`
4. On failure: toast "Could not paste — copied to clipboard"

### 3.5 Voice settings additions

Extend Voice tab + `VoicePreferences` in `SessionPresentationStore`:

| Setting | Type | Default |
|---|---|---|
| System-wide dictation | Toggle | Off |
| Primary trigger | Read-only info | Fn double-tap |
| Secondary shortcut (in-app) | Chord override | ⌃M |
| Fn gesture mode | Enum | `doubleTapOnly` |
| When Continuum focused | Enum | `activeComposer` (Fn → composer; never paste into self via AX) |
| Paste method | Enum | `accessibilityThenCmdV` |
| Accessibility permission | Status row + Open Settings | — |

Onboarding when enabling system-wide:

> Double-tap Fn to dictate anywhere. Continuum needs Accessibility to paste into other apps. Your voice stays on-device when Apple Speech supports it for your locale.

Voice tab shows Fn double-tap as the primary trigger (not a remappable chord — Fn is fixed). ⌃M override stays in Voice tab under "Secondary shortcut."

### 3.6 Lifecycle

- Move `GlobalDictationCoordinator` to `AppRuntime` in Phase 2 (not Phase 3) so Fn works with main window closed
- Start global Fn tap when: dictation enabled AND Accessibility granted
- Stop tap when dictation disabled or app terminates
- Re-install tap on Accessibility grant (user returns from System Settings)
- **No persistent menu bar item** — lifecycle is tap + overlay only

### 3.7 Acceptance criteria

- [x] Fn double-tap starts/stops dictation in Continuum (active composer)
- [x] Fn double-tap with system-wide ON + Accessibility: pastes into Safari/Slack/Notes
- [x] Fn double-tap with system-wide OFF + external app focused: toast prompting to enable system-wide
- [x] ⌃M still works in-app as secondary shortcut (Phase 1 routing preserved)
- [x] Denied Accessibility: Fn works in Continuum only; system-wide toggle shows warning
- [x] Clipboard fallback when AX paste fails
- [x] Fn tap works with main window closed/minimized
- [ ] Unit tests: Fn double-tap state machine, paste target decision logic
- [ ] Manual QA: Apple Silicon MacBook Fn, external keyboard, 10-app paste matrix

### 3.8 Risks

| Risk | Mitigation |
|---|---|
| Fn conflicts with macOS system dictation | Document disable macOS Dictation in System Settings; detect conflict if possible |
| CGEvent tap disabled by macOS | Auto-recover on timeout (Mac Parakeet pattern) |
| AX paste fails in Electron apps | ⌘V fallback + clipboard |
| ⌃M + Fn both fire | Coordinator dedupes; ignore ⌃M while Fn session active |
| External keyboards lack Fn | Voice settings documents requirement; ⌃M fallback always available |

---

## 4. Phase 3 — Long term: overlay + optional gesture modes

**Goal:** Visible feedback during dictation and optional advanced Fn modes. No persistent menu bar presence.

**Effort:** 1–1.5 weeks
**Release:** v0.25.x ("Voice" feature release)

### 4.1 No persistent menu bar agent

**Decision:** Do not add an always-visible dictation mic in the menu bar.

- Dictation is triggered by **Fn double-tap** (and optional ⌃M in-app) — no menu bar click target needed
- Coordinator in `AppRuntime` ensures Fn works when the main window is closed
- **Optional deferral:** transient menu bar mic shown **only while recording or processing** if user testing shows they need it — not in initial Phase 3 scope

### 4.2 Floating recording overlay (primary feedback)

Port concept from Mac Parakeet `DictationOverlayController` / `IdlePillView` / `WaveformView`:

```
apple/ClawdmeterMac/Voice/Overlay/
  DictationOverlayController.swift   // NSPanel, non-activating, all spaces
  DictationOverlayView.swift         // SwiftUI waveform + state pill
```

**States:** recording → processing → success / error (hidden when idle)
**Placement:** Bottom-center of active display
**Audio level:** RMS from `AVAudioEngine` tap

Show overlay for all dictation (Fn and ⌃M, in-app and system-wide). This replaces menu bar as the "something is happening" indicator.

### 4.3 Optional advanced Fn modes

Additional modes in Voice settings (default remains `doubleTapOnly`):

| Mode | Gesture | Use case |
|---|---|---|
| `doubleTapOnly` | Double-tap Fn start/stop | **Default (locked)** |
| `doubleTapAndHold` | Double-tap Fn, hold second | Mac Parakeet-style longer utterances |
| `pushToTalk` | Hold Fn | Handy-style |
| `holdOnly` | Hold Fn | Simple PTT |

**Escape:** Cancel in-progress recording (Mac Parakeet pattern).

### 4.4 Dictation history (optional, lower priority)

- Last 20 transcriptions in command palette or Voice tab
- "Copy last dictation" action
- No audio retention

Defer if schedule slips.

### 4.5 Acceptance criteria

- [ ] Floating overlay appears on Fn double-tap start, hides on idle
- [ ] Overlay visible during system-wide dictation in external apps
- [ ] Optional advanced Fn modes work without changing default
- [ ] No persistent menu bar dictation icon
- [ ] Escape cancels in-progress recording
- [ ] No regression to Phase 1 ⌃M routing or Phase 2 Fn paste

---

## 5. Future release — Local model picker (TODO)

**Goal:** User-selectable, downloadable, on-device STT models — parity with Handy / Mac Parakeet model selection.

**Effort:** 3–4 weeks
**Release:** v0.26.x ("Voice Pro" or similar)
**Prerequisite:** Phase 2 STT protocol + download infrastructure

### 5.1 Model candidates

| Model | Integration | Pros | Cons |
|---|---|---|---|
| **WhisperKit** | [argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit) SPM | Swift-native, multiple sizes, Intel + AS | Larger downloads |
| **Parakeet TDT** | [FluidAudio](https://github.com/FluidInference/FluidAudio) | Fast on ANE, excellent accuracy | Apple Silicon only |
| **Apple Speech** | Current `SFSpeechRecognizer` | Zero setup | No model choice |

**Recommendation:** Ship WhisperKit first (broader hardware support), add Parakeet as "Best on Apple Silicon" later.

### 5.2 Model manager

```
apple/ClawdmeterMac/Voice/Models/
  STTModelDescriptor.swift        // id, name, size, engine, locales
  STTModelCatalog.swift           // available models registry
  STTModelDownloadManager.swift   // download, verify, delete, resume
  WhisperKitTranscriber.swift     // STTTranscribing impl
  ParakeetTranscriber.swift       // future
```

**Storage:** `~/Library/Application Support/Continuum/VoiceModels/<model-id>/`

### 5.3 Voice settings — Model section

| UI element | Behavior |
|---|---|
| Engine picker | Apple Speech / Local model |
| Model picker | tiny, base, small, medium (WhisperKit tiers) |
| Download button | Progress bar, cancel, resume |
| Delete button | Reclaim disk space |
| Disk usage | Per-model + total |
| Language | Override locale for local models |

**Default for new users:** Apple Speech (no download required).

### 5.4 Runtime selection

```swift
func makeTranscriber(for preferences: VoicePreferences) -> STTTranscribing {
    switch preferences.sttEngine {
    case .appleSpeech:
        return AppleSpeechTranscriber(locale: preferences.locale)
    case .whisperKit:
        return WhisperKitTranscriber(modelID: preferences.selectedModelID)
    case .parakeet:
        return ParakeetTranscriber(modelID: preferences.selectedModelID)
    }
}
```

Both in-app and system-wide paths use the same factory.

### 5.5 Acceptance criteria (future release)

- [ ] Download Whisper model from Voice settings
- [ ] Switch models without app restart
- [ ] System-wide dictation uses selected local model
- [ ] Fallback to Apple Speech if model missing or download incomplete
- [ ] Disk space warning before large downloads (>500 MB)
- [ ] Privacy copy: "Local models run entirely on your Mac"
- [ ] On-device badge in Voice tab reflects active engine

---

## 6. Cross-cutting work

### 6.1 Testing strategy

| Phase | Automated | Manual |
|---|---|---|
| 1 | UI tests for ⌃M routing | Chat + Code dictation smoke |
| 2 | Fn double-tap state machine unit tests, paste decision tests | Fn on MacBook + external keyboard, 10-app paste matrix |
| 3 | Gesture mode unit tests | Overlay, optional PTT modes |
| Future | Model download mock tests | Accuracy spot-checks per model |

### 6.2 Privacy & permissions

| Phase | Info.plist / copy updates |
|---|---|
| 1 | None |
| 2 | Accessibility usage description; update mic/speech strings for Fn + system-wide |
| 3 | Overlay / Fn gesture copy |
| Future | Local model storage path disclosure |

Voice tab remains single source of truth for permission status rows.

### 6.3 Out of scope (this plan)

- iOS composer dictation ("coming soon" alert stays)
- Watch voice reply (stub remains)
- Server-side transcription
- Custom vocabulary / snippets (Mac Parakeet feature — consider later)

---

## 7. Milestone timeline

| Milestone | Scope | Cumulative |
|---|---|---|
| **M1** | Phase 1: unified ⌃M routing | +1 week |
| **M2** | STT protocol + VoicePreferences schema | +3 days |
| **M3** | Phase 2: Fn double-tap + global tap + AX paste + AppRuntime coordinator | +1.5 weeks |
| **M4** | Phase 3: floating overlay | +1 week |
| **M5** | Phase 3: optional advanced Fn modes + dictation history | +3 days |
| **M6** | Future: model catalog + WhisperKit + picker | +3–4 weeks |

**To Mac Parakeet parity (minus custom models):** ~3.5–4 weeks
**Including local model picker:** ~7–8 weeks

---

## 8. PR sequence

| PR | Contents | Phase |
|---|---|---|
| PR1 | `DictationRouter` + Phase 1 ⌃M routing + Chat ⌃M + merge fix + tests | 1 |
| PR2 | `STTTranscribing` protocol + `VoicePreferences` in `SessionPresentationStore` | 2 prep |
| PR3 | `GlobalHotkeyManager` + `HotkeyGestureController` (Fn double-tap) + `AccessibilityPasteService` | 2 |
| PR4 | `GlobalDictationCoordinator` in `AppRuntime` + system-wide toggle + Voice settings | 2 |
| PR5 | Floating overlay (`DictationOverlayController`) | 3 |
| PR6 | Optional advanced Fn modes + Escape cancel | 3 |
| PR7 | Model download manager + WhisperKit + model picker UI | Future |

---

## 9. Remaining open items

| Item | Notes |
|---|---|
| **Sandbox** | Release build is non-sandboxed (#230); confirm AX paste in shipped DMG |
| **macOS Dictation conflict** | Document disabling System Settings → Keyboard → Dictation if Fn conflicts |
| **Transient menu bar mic** | Defer unless user testing demands it; overlay is primary feedback |

---

## 10. Definition of done

The Voice feature is complete when:

- [ ] Fn double-tap dictates into the active composer when Continuum is focused
- [ ] Fn double-tap pastes into any app when system-wide is enabled
- [ ] ⌃M remains available as secondary in-app shortcut
- [ ] Dictation works with main window closed (coordinator in `AppRuntime`)
- [ ] Floating overlay shows recording/processing state — no persistent menu bar mic
- [ ] Optional advanced Fn modes available in Voice settings
- [ ] Voice settings centralize permissions, system-wide toggle, and engine info
- [ ] **Future:** Local downloadable models are user-selectable without re-architecting Fn or paste
