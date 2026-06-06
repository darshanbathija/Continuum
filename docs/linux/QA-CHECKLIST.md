# Linux Manual QA Checklist

Status: future release gate. The Linux packaging jobs are quarantined while the
daemon/tray binaries remain stubs, so this checklist is not required for normal
Mac/iOS releases.

This document is the **release gate** for every Linux build. Container CI
(see `.github/workflows/linux.yml`) verifies that the artifacts compile,
install, and respond to `--version`. It **cannot** verify the actual UI
surfaces — that requires a real Linux desktop VM.

**Per codex C10 + D11**: every release PR must have this checklist signed
off on both Ubuntu 24.04 and ZorinOS 17 VMs before merge. Items annotated
`[backend-only]` can be skipped if the PR doesn't touch UI / tray / WebKit /
VTE / pairing surfaces.

## VM setup

Two VMs, one for each distro:
- `Ubuntu 24.04 stock` — `https://releases.ubuntu.com/24.04/` desktop image, fresh install, no extra extensions.
- `ZorinOS 17 Core` — `https://help.zorin.com/docs/getting-started/install-zorin-os/` (latest Core).

VMs run with **2 vCPU / 4GB RAM / 20GB disk / X11 (not Wayland for tray test compatibility)**.
Take a snapshot before each test pass so failures can be retried cleanly.

## Test passes

### Pass 1: AppImage install

- [ ] Download `Clawdmeter-<version>-x86_64.AppImage` from GitHub Releases.
- [ ] `chmod +x Clawdmeter-*.AppImage`
- [ ] Double-click in the file manager — `clawdmeter` window opens within 3s.
- [ ] **Tray icon appears in the top bar** within 5s of launch.
- [ ] Right-click the tray icon: menu shows "Open dashboard", "Force poll Claude", "Force poll Codex", "Settings…", "Quit".
- [ ] Click "Open dashboard" → window opens, analytics row visible (numbers may be zero if no Claude / Codex JSONLs present).

### Pass 2: .deb install

- [ ] `sudo apt install ./clawdmeter_<version>_amd64.deb`
- [ ] Open the app from the GNOME Activities overview — finds "Continuum".
- [ ] Tray icon shows up.
- [ ] `systemctl --user status clawdmeter.service` — service available (may be inactive; that's OK).
- [ ] `systemctl --user enable --now clawdmeter.service` — daemon starts, listens on 21731.
- [ ] `curl -v http://127.0.0.1:21731/health` — returns 401 (missing auth header).

### Pass 3: AppIndicator extension missing path (Ubuntu only)

- [ ] On a stock Ubuntu 24.04 install (extension not preinstalled):
  - [ ] First launch shows the `MissingTraySupportDialog` with "Install extension" + "Continue without menu bar".
  - [ ] "Install extension" opens https://extensions.gnome.org/extension/615/ in browser via xdg-open.
  - [ ] "Continue without menu bar" — dialog dismisses, dashboard opens, opt-out persisted (relaunch doesn't re-prompt).
- [ ] Install the extension: `sudo apt install gnome-shell-extension-appindicator`, log out + back in.
- [ ] Relaunch Continuum — tray icon now visible; no dialog.

### Pass 4: Live gauge update

- [ ] With a valid Claude OAuth token (paste in Settings → Token), run `claude` once in a terminal.
- [ ] Tray icon label updates to current session % within 60s.
- [ ] Icon refreshes (different gauge graphic) every 60s.

### Pass 5: iPhone pairing over Tailscale [if pairing changed]

- [ ] `tailscale up` on the Linux VM.
- [ ] Open Continuum Settings → Sessions → "Sync with iPhone".
- [ ] QR code visible. URL field shows `http://100.x.x.x:21731/...` (Tailscale CGNAT).
- [ ] Scan from iPhone Continuum — paired status appears.
- [ ] iPhone "Open on Mac" button → Linux dashboard composer pre-fills.
- [ ] iPhone spawn session → tmux pane created on Linux (visible via `tmux ls`).
- [ ] Chat snapshot streams back to iPhone.

### Pass 6: In-app browser [if WebKit changed]

- [ ] In Sessions tab, ask agent to "open google.com in the in-app browser".
- [ ] WebKitGTK browser opens; page renders.
- [ ] Ctrl-click on any element — `[BROWSER COMMENT @ <selector>]` injected into tmux pane.
- [ ] Navigation works (back / forward / reload).

### Pass 7: Sessions chat IDE [if UI/Sessions changed]

- [ ] Sessions tab visible.
- [ ] Empty-state composer renders centered.
- [ ] Type a prompt → first send spawns Claude session, tmux pane visible.
- [ ] Drag a file into the composer — attachment chip appears.
- [ ] Paste image from clipboard — image chip appears with thumbnail.
- [ ] `/skill-name` palette opens; lists skills from `~/.claude/skills/`.
- [ ] `@`-mention opens picker.
- [ ] Plan mode toggle: enter plan, see Plan card, "Approve & run" works.

### Pass 8: VTE terminal [if VTE changed]

- [ ] Cmd+T (or Ctrl+T) overlay opens raw tmux pane.
- [ ] tmux output streams live.
- [ ] Keystrokes forward correctly.

### Pass 9: Uninstall

- [ ] `sudo apt remove clawdmeter` (or delete AppImage).
- [ ] Daemon stops.
- [ ] User data preserved (`~/.local/share/clawdmeter/`, `~/.config/clawdmeter/`).
- [ ] `sudo apt purge clawdmeter` removes the user data too.

## Sign-off

| Pass | Ubuntu 24.04 | ZorinOS 17 |
|---|---|---|
| 1: AppImage install | ☐ | ☐ |
| 2: .deb install | ☐ | ☐ |
| 3: SNI extension missing | ☐ | N/A (Zorin preinstalls) |
| 4: Live gauge update | ☐ | ☐ |
| 5: Pairing | ☐ / N/A | ☐ / N/A |
| 6: In-app browser | ☐ / N/A | ☐ / N/A |
| 7: Sessions IDE | ☐ / N/A | ☐ / N/A |
| 8: VTE | ☐ / N/A | ☐ / N/A |
| 9: Uninstall | ☐ | ☐ |

Reviewer: __________________________
Date: __________________________
Version: __________________________
