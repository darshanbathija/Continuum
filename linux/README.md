# Continuum for Linux

Native Linux desktop port of Continuum targeting **Ubuntu 24.04+** and **ZorinOS 17+** (GNOME-based).

## What's in this directory

```
linux/
├── Package.swift                       Swift Package spec for the Linux app + daemon
├── Sources/
│   ├── ClawdmeterDaemon/               @main headless daemon binary (Hummingbird HTTP+WS)
│   ├── ClawdmeterLinux/                desktop app sources (tray + UI + storage adapters)
│   │   ├── Transport/                  HummingbirdTransport + PeerFilter + BearerAuth middleware
│   │   ├── Storage/                    XDG-based storage; libsecret token providers; LinuxUsageStore
│   │   ├── Tray/                       AppIndicator + Cairo gauge renderer + SNI watcher detection
│   │   ├── UI/
│   │   │   ├── Primitives/             LinuxUIWidget protocol + SwiftCrossUI adapter (D3 + D14)
│   │   │   ├── Onboarding/             Missing-tray dialog (D5)
│   │   │   ├── Charts/                 Cairo-on-GtkDrawingArea bar chart + sparkline
│   │   │   ├── Diagnostics/            Audit log viewer + Wire inspector
│   │   │   └── Sessions/               Sessions chat IDE (hybrid SwiftCrossUI + direct CGtk4)
│   ├── CAyatanaAppIndicator/           C shim module map (pkg-config-resolved)
│   ├── CCairo/                         C shim module map
│   ├── CLibSecret/                     C shim module map
│   ├── CGtk4/                          C shim module map
│   ├── CLibAdwaita/                    C shim module map
│   ├── CWebKitGTK/                     C shim module map
│   ├── CVTE/                           C shim module map
│   └── CLibUtil/                       C shim for openpty(3) on Linux
├── Tests/
│   └── ClawdmeterLinuxTests/
│       ├── Security/                   peer-filter + bearer-auth tests (D7)
│       ├── Transport/                  send-handler heuristic tests (D6 / C7)
│       ├── Visual/                     golden-image visual regression (D10)
│       └── Tray/                       SNI watcher + Cairo render tests
├── scripts/
│   └── configure-c-shims.sh            pkg-config-resolved C shim module map generator (D9)
└── resources/
    ├── clawdmeter.desktop              .desktop file for menu integration
    ├── clawdmeter.appdata.xml          AppStream metadata for software centers
    ├── clawdmeter.service              systemd-user service unit
    ├── clawdmeter.png + .svg           icon (16/22/24/32/48/64/128/256/512)
    └── packaging/
        ├── appimage/                   linuxdeploy + appimagetool config
        └── deb/                        dpkg-deb control + postinst
```

## Build (development)

```bash
# Install Swift 6.0+ from https://swift.org/install/linux/
# Install GTK4 + system deps:
sudo apt install -y \
  libgtk-4-dev libadwaita-1-dev \
  libayatana-appindicator3-dev libsecret-1-dev \
  libcairo2-dev libpango1.0-dev \
  libwebkitgtk-6.0-dev libvte-2.91-gtk4-dev \
  pkg-config

cd linux
./scripts/configure-c-shims.sh   # resolves system header paths via pkg-config
swift build
swift test
```

## Build (distribution)

```bash
../tools/build-linux-appimage.sh   # → ../dist/Clawdmeter-<version>-x86_64.AppImage
../tools/build-linux-deb.sh        # → ../dist/clawdmeter_<version>_amd64.deb
```

See `../tools/build-mac-dmg.sh` for the Mac analog. Versioning shared via root `VERSION`.

## Architecture

Three layers, all sharing `apple/ClawdmeterShared`:

1. **Daemon** (`ClawdmeterDaemon` binary). Headless, Hummingbird-based HTTP+WS on ports 21731/21732. Same wire as Mac. Mirrors Mac's iPhone pairing flow over Tailscale. Can run with `--with-tray` (default for desktop AppImage) or `--headless` (server).
2. **System tray** (`ClawdmeterLinux/Tray`). `libayatana-appindicator3` via Swift C interop. Cairo-rendered live gauge PNG written to `$XDG_RUNTIME_DIR/clawdmeter/`. SNI watcher detection with first-run dialog if extension missing.
3. **Dashboard + Sessions** (`ClawdmeterLinux/UI`). SwiftCrossUI primary binding (per D14, after codex flagged adwaita-swift instability). Simple surfaces use `LinuxUIWidget` protocol (D3); complex surfaces (Sessions IDE) use direct CGtk4 C interop.

See `../docs/linux/INSTALL.md` for install instructions and `../docs/linux/PAIRING.md` for iPhone pairing.
