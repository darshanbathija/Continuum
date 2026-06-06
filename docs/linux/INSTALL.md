# Linux Status

Continuum does not currently ship a supported Linux desktop or daemon build.
The `linux/` package is scaffolding that should compile for development, but
the desktop app, daemon transport, pairing flow, AppImage, and `.deb` packaging
remain stubbed.

## Development Build

Use this only to keep the Linux package healthy while implementing the real
runtime:

```bash
sudo apt install -y \
  libgtk-4-dev libadwaita-1-dev \
  libayatana-appindicator3-dev libsecret-1-dev \
  libcairo2-dev libpango1.0-dev \
  libwebkitgtk-6.0-dev libvte-2.91-gtk4-dev \
  pkg-config

cd linux
./scripts/configure-c-shims.sh
swift build
swift test
```

## Release Blockers

Do not publish Linux artifacts until these are true:

- `clawdmeterd` runs a real HTTP/WebSocket transport and passes a health check.
- `clawdmeter` renders a real tray/dashboard instead of the Phase 0 skeleton.
- Pairing/auth matches the Mac daemon security model.
- `tools/build-linux-appimage.sh` and `tools/build-linux-deb.sh` produce real
  artifacts without `CLAWDMETER_PACKAGING_ALLOW_STUB=1`.
- The QA checklist passes on Ubuntu 24.04 and ZorinOS 17.

Related scaffolding docs:

- [PAIRING.md](PAIRING.md)
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- [QA-CHECKLIST.md](QA-CHECKLIST.md)
