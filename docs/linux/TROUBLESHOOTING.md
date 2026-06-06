# Linux troubleshooting

Status: future troubleshooting notes. The Linux app and daemon are still
scaffolding, not supported release artifacts.

## "Tray icon doesn't appear" on stock GNOME

**Symptom**: launching Continuum from the GNOME Activities overview
flashes briefly and disappears. No icon in the top bar.

**Cause**: GNOME 40+ doesn't ship native tray support. You need the
`appindicatorsupport@rgcjonas.gmail.com` shell extension. ZorinOS
preinstalls it; stock Ubuntu does not.

**Fix**:
```bash
sudo apt install gnome-shell-extension-appindicator
# Log out and back in for the extension to load.
```

On first launch after install, the dialog should not re-appear; the tray
icon shows up in the top bar.

**Alternative**: in the missing-tray dialog, choose **"Continue without
menu bar"** and pin the dashboard window to your favorites. The dashboard
has every feature the popover does, just without the always-visible gauge.

## "Cannot open OAuth token" error

**Symptom**: Continuum starts but the analytics show "No data" and the
sessions tab can't spawn agents.

**Cause**: the Secret Service / GNOME Keyring daemon isn't running. This
happens on headless / server installs and some minimal desktop variants.

**Fix**: either install GNOME Keyring:
```bash
sudo apt install gnome-keyring
# May need to log out + back in for the keyring daemon to start.
```

Or use the file fallback. Continuum automatically writes the OAuth token
to `~/.config/clawdmeter/.oauth-tokens.json` (chmod 0600) when Secret
Service isn't available. To migrate manually:
```bash
mkdir -p ~/.config/clawdmeter
cat > ~/.config/clawdmeter/.oauth-tokens.json <<EOF
{"claude-oauth": "sk-ant-oat01-..."}
EOF
chmod 0600 ~/.config/clawdmeter/.oauth-tokens.json
```

## "Daemon won't start on 21731"

**Symptom**: `clawdmeterd --headless` exits with "Address already in use".

**Cause**: another instance is running, or another app grabbed the port.

**Fix**:
```bash
# Find the conflicting process
sudo lsof -i :21731

# If it's a stale clawdmeterd:
pkill -f clawdmeterd

# If it's a different app, override the port:
clawdmeterd --headless --http-port 21733 --ws-port 21734
```

(iPhone pairing assumes the default 21731/21732. If you change ports, the
QR code generation uses your override. Re-scan from iPhone.)

## "WebKit web process crash" in Sessions in-app browser

**Symptom**: clicking a link in the embedded browser shows a "Web process
crashed" placeholder.

**Cause 1**: `bubblewrap` or `xdg-dbus-proxy` missing. WebKitGTK 6.0
sandboxes the WebProcess; without these the sandbox fails to spawn.

**Fix**:
```bash
sudo apt install bubblewrap xdg-dbus-proxy
```

If you're on the AppImage, both are bundled; this shouldn't happen on a
clean Ubuntu 24.04. Check the AppImage version is current.

**Cause 2**: WebKitGTK 6.0 not actually installed (you're on the .deb on
an older distro that didn't pull it).

**Fix**:
```bash
apt list --installed | grep webkitgtk
# Should show libwebkitgtk-6.0-4. If only libwebkit2gtk-4.x is installed,
# you're on the GTK3 build — use the AppImage instead, which bundles the
# right version.
```

## "Pairing QR shows 127.0.0.1 instead of 100.x.x.x"

**Symptom**: scanning the QR pairs to localhost; iPhone can't reach.

**Cause**: Tailscale isn't running on the Linux host.

**Fix**:
```bash
sudo systemctl enable --now tailscaled
tailscale up
```

Restart Continuum; the new QR will use the 100.x.x.x CGNAT address.

## Performance: dashboard is slow on first open

**Symptom**: opening the dashboard takes 3-5 seconds the first time after
a fresh `claude` or `codex` run.

**Cause**: `UsageHistoryLoader` walks `~/.claude/projects/` and
`~/.codex/sessions/` in parallel; first walk is uncached.

**Fix**: this is expected; subsequent opens are <200ms (cache at
`~/.cache/clawdmeter/analytics-cache.json`).

## "swift: command not found" when building from source

You need Swift 6.0+ from swift.org. Ubuntu's archive doesn't ship Swift.

```bash
# Download from https://swift.org/install/linux/
wget https://download.swift.org/swift-6.0-release/ubuntu2404/swift-6.0-RELEASE/swift-6.0-RELEASE-ubuntu24.04.tar.gz
tar xzf swift-6.0-RELEASE-ubuntu24.04.tar.gz
export PATH="$PWD/swift-6.0-RELEASE-ubuntu24.04/usr/bin:$PATH"
swift --version
```

## Filing a bug

If something's broken, file at https://github.com/darshanbathija/Clawdmeter/issues
with:
- Output of `lsb_release -a` (or your distro equivalent).
- Output of `clawdmeter --version` and `swift --version`.
- Output of `journalctl --user -u clawdmeter.service --since "10 minutes ago"`.
- Output of `clawdmeterd --headless` from a fresh terminal (so we see the startup logs).
