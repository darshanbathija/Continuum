# Continuum 0.31.17

- **Relay pairing now works in a downloaded build.** Settings → Pair iPhone gains a **"Relay access token"** field, stored in your Mac's Keychain, so the Mac can mint pairing QRs against the production relay. Previously the grant token was only read from an environment variable — which a notarized, double-clicked app never has — so relay pairing silently fell back to a key the relay rejects.
- The Mac now points at the **production relay Worker** by default.
- Ships build 225 for Mac (signed Sparkle feed) with iOS/watchOS to TestFlight on the same build.
