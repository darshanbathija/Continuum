# Continuum 0.31.16

- The Code composer's **Stop** button now actually clears the "thinking…" indicator (and re-enables Send) for Claude sessions — previously the abort marker flipped it back on.
- The composer footer is consolidated into a single Claude-Desktop-style **"+" menu** (attach, prompt history, saved prompts, paste-without-ANSI, expand) so the bar reads `+ · mic · … · send`.
- **Enter sends; Shift+Return inserts a newline** in Code (was ⌘↩ to send). ⌘↩ still works as a secondary shortcut.
- **Settings simplified:** removed the Live Activities / APNS credential setup, and stripped Pairing down to a single QR your iPhone scans (plus Forget pairing).
- Ships build 224 for Mac (signed Sparkle feed) with iOS/watchOS to TestFlight on the same build.
