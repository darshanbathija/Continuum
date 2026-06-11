# Continuum 0.33.0

Light theme, leaderboard, provider logos, and 21 improvements to the Code tab, chat, and Settings.

- **Quiet White light theme.** A crisp light mode variant you can switch to in Settings → Appearance, or let macOS toggle automatically. Default stays Dark.
- **Flat ranked leaderboard for tokens by model.** The model breakdown is now a compact percentage-bar list with token count and cost per model at a glance.
- **Provider logo in the model chip.** The composer and session detail show the provider's logo next to the model name.
- **Effort is its own composer pill.** Reasoning effort (Low / Medium / High / Max) has a dedicated chip in the Code tab composer — change it without touching the model selector.
- **Install All for vendor provisioning.** One-tap button installs every missing dependency without stepping through each prompt.
- **Rename workspace and git branch from the sidebar.** Right-click any workspace → Rename updates both the folder name and its tracking git branch.
- **Worktree branch shown in the Code tab breadcrumb.** The active worktree branch name is now part of the breadcrumb path.
- **Worktree diffs yield to the archive affordance on hover.** The diff preview steps aside so the archive button is always reachable.
- **Segmented controls visible in light mode.** The segment track was transparent in Quiet White — fixed by threading the missing `segmentTrack` token through to both view call sites.
- **Usage bars are evenly spaced.** Provider gauge columns divide width equally when fewer than the maximum providers are active.
- **Worktree live-status dot stays in position.** The green activity dot no longer shifts when a row is hovered or selected.
- **Duplicate Diff label is gone.** The Settings pane no longer shows the Diff heading twice.
- **Mic permission prompt appears for composer dictation.** Ctrl+M now asks for microphone access instead of silently failing.
- **Redundant Worktree mode removed from the Code tab header.** The mode selector no longer duplicates the option already in the composer chip.
- **Code tab empty state refreshed.** Clearer icon and copy for new users.
- **Chat provider rows are fully clickable in Ask or Compare.** The whole row responds to a click, not just the trailing button.
- **Custom provider sheet opens on click.** Add in Settings → Providers no longer needs a second tap.
- **"You're up to date" shows after manual update checks.** The status banner now appears when no update is available, instead of showing nothing.
- **Repo removal in the Code sidebar feels instant.** The sidebar responds in under 250ms with no visual stutter.
- **Code workspace tabs stay put.** The tab strip no longer scrolls horizontally when the window is resized.
- **Diagnostics removed from Settings.** Settings is now five clean tabs.
- Ships build 230 for Mac (signed Sparkle feed) with iOS/watchOS to TestFlight on the same build.
