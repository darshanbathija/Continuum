# Add Repo flow — manual QA checklist

Run this once on a development build of the Mac + iPhone apps before
merging the Add-Repo PR. Five paths can't be automated unit-tests; this
catches what XCTest can't.

## Mac

### 1. Open project (folder picker)

- [ ] Click the sidebar "+" (terra-cotta `folderPlus`). Menu opens.
- [ ] Pick **Open project**. NSOpenPanel appears titled "Open project".
- [ ] Navigate to a folder with `.git` (e.g. this repo). Pick it.
  - Expected: sidebar grows an entry for that repo.
- [ ] Click "+" again → Open project → pick a folder WITHOUT `.git`.
  - Expected: confirm dialog "This folder isn't a git repository — Add anyway / Cancel".
  - Pick Add anyway → sidebar shows the folder under "Other" group.
  - Pick Cancel → no side effects.
- [ ] Click "+" → Open project → cancel the NSOpenPanel.
  - Expected: no state mutation, no toast.

### 2. Clone from GitHub

- [ ] Click "+" → **Open GitHub project**.
- [ ] Status row shows "GitHub CLI installed" (green) when `gh` is on PATH.
- [ ] Type `anthropics/claude-code-sdk` in spec, leave destination at default `~/code/`.
  - Expected: Clone button enables. Tap. Progress spinner shows "Cloning anthropics/claude-code-sdk…".
  - On success: sheet dismisses, sidebar grows `claude-code-sdk` entry.
  - Verify `~/code/claude-code-sdk/.git/` exists on disk.
- [ ] Temporarily move `gh` aside: `mv $(which gh) /tmp/gh.bak`. Restart Continuum.
  - Status row shows "GitHub CLI not found — Copy install command".
  - Clone a public repo. Expected: succeeds via `git clone https://github.com/...`.
  - Try cloning a **private** repo. Expected: auth banner with "Copy `gh auth login`" button.
  - Restore `gh`: `mv /tmp/gh.bak $(which gh 2>/dev/null || echo /opt/homebrew/bin/gh)`.
- [ ] Type an invalid spec (`asdf` with no slash).
  - Expected: Clone button stays disabled.
- [ ] Type a non-existent repo (`fakeuser/fakerepo`). Tap Clone.
  - Expected: error banner with stderr from gh/git.

### 3. Quick start

- [ ] Click "+" → **Quick start**.
- [ ] Type name `scratchpad`. Pick parent `/tmp`. Tap Create.
  - Expected: sheet dismisses, sidebar grows `scratchpad` entry.
  - Verify `/tmp/scratchpad/.git/` exists.
- [ ] Try names: empty, `with/slash`, `.hidden`.
  - Expected: Create button stays disabled.
- [ ] Use an already-existing folder name.
  - Expected: error banner "Folder already exists at /tmp/scratchpad".

### Mac muscle-memory regression (CRITICAL)

- [ ] `Cmd+N` opens the New Session sheet (not the Add Repo menu).
- [ ] Click the per-repo `+` button on any repo row in the sidebar.
  - Expected: New Session sheet opens preselected to that repo.
- [ ] Right-click on a repo row.
  - Expected: context menu includes the existing items + the sidebar's
    existing affordances still work.

## iOS (with paired Mac on wire v23+)

### 4. Clone from GitHub on Mac

- [ ] Open Code tab on iPhone. Tap the folder icon in the header.
  - Expected: workspace switcher sheet opens.
- [ ] Scroll to "Add project" section. Tap **+ Add project**.
  - Expected: confirmation dialog with 3 options.
- [ ] Tap **Open GitHub Project**. Sheet shows spec + destination fields.
- [ ] Allowed roots row shows the Mac's `defaultParent` + scan roots.
- [ ] Type `anthropics/claude-code-sdk` + a destination under an allowed
  root. Tap Clone.
  - Expected: progress, then sheet dismisses + new workspace appears in
    the switcher.
- [ ] Try a destination OUTSIDE the allow-list (e.g. `/etc`).
  - Expected: error inline before posting (pre-validation kicks in).

### 5. iOS Open Project on a sleeping Mac

- [ ] Lid-close the Mac. Wait 5s for screen lock.
- [ ] On iOS, tap "+ Add project" → "Open Project on Mac".
  - Expected: "Mac is asleep — wake it and try again" + Wake Mac banner appears.
- [ ] Tap **Wake Mac**.
  - Expected: caffeinate fires on the Mac (display wakes briefly), banner shows
    "Wake signal sent. Try Open Project again."
- [ ] Open lid. Re-tap "Open Project on Mac".
  - Expected: NSOpenPanel appears on the Mac. Pick a folder.
  - iOS workspace switcher refreshes; new entry appears.

### 6. iOS wire-version banner

- [ ] Pair to an older Mac (wire v22). Open workspace switcher footer.
  - Expected: "Update Continuum on the Mac to add projects from iOS."
  - The Add project button is NOT shown.
