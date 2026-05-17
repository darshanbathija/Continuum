# Pairing your iPhone with Clawdmeter for Linux

Clawdmeter for Linux pairs to the iPhone app over **Tailscale**. Same
mechanism as the Mac: scan a QR, share a per-device bearer token, the
iPhone speaks to the Linux daemon at `http://100.x.x.x:21731`.

## Prerequisites

1. **Tailscale** on the Linux host and the iPhone:
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   tailscale status   # confirm both machines on the same tailnet
   ```
   On iPhone: install [Tailscale from the App Store](https://apps.apple.com/app/tailscale/id1470499037),
   sign in to the same account.

2. **Clawdmeter daemon running**. Either:
   - Foreground via the desktop launcher (`clawdmeter --with-tray` — default).
   - Headless via the systemd-user service: `systemctl --user enable --now clawdmeter.service`.

3. **iPhone Clawdmeter** installed (TestFlight or App Store).

## Pairing flow

1. **On Linux**: open Clawdmeter → **Settings → Sessions → "Sync with iPhone"**.
   A QR code popover appears. Below the QR is the URL:
   ```
   http://100.64.x.x:21731/pair?token=<43-char-base64url>
   ```
   The token is per-device, generated on first launch, stored in GNOME
   Keyring (or in `~/.config/clawdmeter/.token` chmod 0600 on headless
   server installs).

2. **On iPhone**: open Clawdmeter → **Sessions tab → "Pair with Mac/Linux"**
   → **Scan QR**. Point the camera at the Linux screen.

3. Within ~1s the iPhone shows **"Paired with <hostname>"**. The Sessions
   tab now lists any sessions the Linux daemon owns.

## What works

Once paired, the iPhone can:
- **Start a session** in any repo on the Linux machine (worktree-mode supported).
- **View live chat snapshots** as Claude/Codex respond.
- **Approve plan-mode** for both Claude (`--permission-mode plan`) and Codex (`-s read-only`).
- **See live diff** and accept the merge.
- **Trigger PR review** via the embedded GitHub API client.
- **Switch model / effort mid-session** (Conductor-grade).
- **Send keystrokes** through the same byte-identical `submitToTmux` heuristic
  used by Mac (codex C7 — both transports call the shared function so the
  wire is identical).

## Troubleshooting

### "Mac unreachable" on iPhone

Linux side:
- Check `tailscale status` — daemon must be running.
- Check `systemctl --user status clawdmeter.service` (or that the desktop
  app is running with a tray icon).
- Check `ss -tnlp | grep 21731` — daemon must be listening.
- Check the iPhone is on the same tailnet: `tailscale status` should
  list the iPhone's Tailscale name.

iPhone side:
- Open Settings → General → Network — confirm Tailscale is connected.
- Tap the paired-host row → "Reconnect".

### QR scans but pairs to wrong host

The QR contains a bearer token plus the host URL. If you have multiple
Clawdmeter installs (Mac + Linux), the iPhone may have a stale token from
the other. Tap the paired-host row → "Forget" → re-scan.

### "Tailscale installed but not running" warning in the QR popover

```bash
sudo systemctl enable --now tailscaled
tailscale up
```

If Tailscale isn't installed at all, the daemon falls back to `127.0.0.1`
which iPhone obviously can't reach. Install Tailscale first.

### Bearer token leaked / lost phone

Linux side: **Settings → Sessions → "Regenerate token"**. This invalidates
the old token; every paired iPhone needs to re-scan the new QR.

```bash
# Or via CLI on the Linux host:
clawdmeterd --regenerate-pairing-token
```

## Wire compatibility

The daemon implements protocol v4 (`wireVersion: 4` in `/health`). iPhone
clients below v4 see "Update Clawdmeter on the Mac" in the new-session
sheet. Update the iOS app via TestFlight / App Store.

## Security model

- **Bearer auth + peer-filter dual gate.** Every request needs a valid
  `Authorization: Bearer <token>` AND must originate from loopback or
  Tailscale CGNAT (100.64.0.0/10) or Tailscale ULA (fd7a:115c:a1e0::/48).
- **Tailscale identity confirmation.** Non-loopback peers additionally
  verified via `tailscale whois` (60s cache, fail-closed on error).
- **No tokens in transit.** The QR carries the token only on the local
  Tailscale-encrypted path; never over the public internet.
- **Per-repo autopilot trust.** Even with a valid token, autopilot
  (`--dangerously-skip-permissions`) only enables for repos the user has
  explicitly trusted on the Linux side. Trust list at
  `~/.local/share/clawdmeter/autopilot-trusted-repos.json`.
