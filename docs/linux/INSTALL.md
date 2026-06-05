# Installing Continuum on Linux

Continuum ships for Ubuntu 24.04+ and ZorinOS 17+. On older LTS releases
(Ubuntu 22.04 / ZorinOS 16) use the AppImage — it bundles the GTK4 + WebKitGTK 6.0
dependencies that the older archive doesn't ship.

## AppImage (works everywhere; recommended for older LTS)

```bash
# 1. Download the latest AppImage from Releases
wget https://github.com/darshanbathija/Clawdmeter/releases/latest/download/Clawdmeter-x86_64.AppImage

# 2. Make it executable
chmod +x Clawdmeter-x86_64.AppImage

# 3. Run
./Clawdmeter-x86_64.AppImage
```

The AppImage is ~200MB. Bundles the Swift 6 runtime + WebKitGTK 6.0 + VTE
2.91-GTK4 + bubblewrap + xdg-dbus-proxy + GStreamer plugins. Runs on any
distro with a glibc ≥ 2.35 and GTK4 ≥ 4.10 installed.

### Optional: integrate with the system

```bash
# Move to a stable location
mkdir -p ~/Applications
mv Clawdmeter-x86_64.AppImage ~/Applications/

# Right-click in your file manager → "Properties" → "Open With" set to itself
# OR use AppImageLauncher (https://github.com/TheAssassin/AppImageLauncher)
# for proper desktop integration.
```

## .deb (Ubuntu 24.04+ / ZorinOS 17+)

```bash
# 1. Download the .deb
wget https://github.com/darshanbathija/Clawdmeter/releases/latest/download/clawdmeter_amd64.deb

# 2. Install (apt resolves the system GTK4 / libsecret / libwebkitgtk-6.0 deps)
sudo apt install ./clawdmeter_amd64.deb

# 3. Launch from GNOME Activities or run `clawdmeter` from a terminal.
```

The .deb is ~30MB. Pulls system GTK4, libadwaita, libwebkitgtk-6.0,
libsecret, libayatana-appindicator3, libvte-2.91-gtk4, bubblewrap,
xdg-dbus-proxy as runtime deps.

### Optional: enable the headless daemon

The .deb ships a systemd-user service for the headless daemon. Useful if
you want the iPhone-pairing daemon running without the desktop UI.

```bash
systemctl --user enable --now clawdmeter.service
systemctl --user status clawdmeter.service
```

The service listens on 127.0.0.1:21731 (HTTP) and 127.0.0.1:21732 (WS).
Tailscale CGNAT (100.64.0.0/10) is also allowlisted at the peer filter
so iPhones on the same tailnet can pair.

## GNOME AppIndicator extension (Ubuntu only — Zorin preinstalls it)

The menu-bar gauge needs the AppIndicator shell extension to render on
stock GNOME 40+. ZorinOS 17 ships it by default; Ubuntu 24.04 does not.

```bash
# Install the apt-provided extension
sudo apt install gnome-shell-extension-appindicator

# Log out + log back in so GNOME picks it up.
# Verify in: Extensions app (or https://extensions.gnome.org/local/)
```

If you skip this, Continuum detects the missing extension on first launch
and shows a dialog with the install link. You can choose "Continue without
menu bar" and use the dashboard window directly.

## Verifying the install

```bash
clawdmeter --version
# clawdmeter (Linux desktop) 0.4.0

clawdmeterd --version
# clawdmeterd 0.4.0
```

If `clawdmeter --version` fails, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Next steps

- [PAIRING.md](PAIRING.md) — pair your iPhone over Tailscale.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — common issues and fixes.
- [QA-CHECKLIST.md](QA-CHECKLIST.md) — the release-gate test plan.
