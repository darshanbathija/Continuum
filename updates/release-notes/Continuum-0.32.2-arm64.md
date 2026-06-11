# Continuum 0.32.2

Workspace and menu bar polish — six targeted bug fixes across the Mac sidebar, pane transitions, and status-bar interactions.

- **Workspace tabs keep the branch visible when closing a tab.** The branch name row no longer disappears when you close another tab in the same workspace.
- **Smooth expand/collapse pane transition.** Expand and collapse now use a fluid animated transition with the correct label state throughout.
- **Archive button no longer overlaps the live dot.** The archive action in the sidebar is properly offset so it doesn't occlude the active-session indicator.
- **Provider logos render at the correct aspect ratio in menu bar badges.** Logo images in the menu bar gauge are no longer stretched — they respect their original proportions.
- **Larger hit target for the menu bar checkbox on the Usage tab.** The checkbox is easier to tap and no longer requires pixel-precise clicks.
- **Larger hit area for workspace tab close buttons with hover chrome.** The × button now has a generous hover zone and a visible background on hover for clarity.
- Ships build 229 for Mac (signed Sparkle feed) with iOS/watchOS to TestFlight on the same build.
