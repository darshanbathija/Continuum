# Continuum 0.31.15

- Code workspace polish on Mac: the whole "Ask" permission pill is clickable (not just the chevron), the model/effort and mode pills now hug and center their text, and the redundant inline checkpoint "Restore" strip and the terminal "Terminal connected · Shell" strip are gone.
- Closing a Code tab no longer tears down the branch: the worktree is kept while sibling or draft tabs still live in it, and ownership hands off to a survivor so the last tab still cleans up — on both the Mac and the daemon delete path.
- The per-repo "+" opens a Codex · GPT-5.5 · Extra High · Plan-mode workspace by default.
- The embedded terminal now opens Claude in the worktree instead of a bare shell.
- iOS: the live-composer model/effort pill hugs and centers its label (no more clipped "Model · Effort"), matching the Mac fix.
- Reliability: cross-provider model swaps are now rejected at the daemon (preventing the "Connecting to Claude…" strand from any client), the menu-bar popover stays dark over light desktops, and models without a reasoning dial (e.g. Haiku) no longer receive a spurious effort flag.
- Ships build 223 for Mac (signed Sparkle feed) with iOS/watchOS to TestFlight on the same build.
