# Continuum 0.36.0

Vendor secret sharing and guided CLI onboarding, document tabs and edited-file previews in the Code tab, richer agent transcripts, and more accurate usage analytics.

- **Guided vendor CLI onboarding.** Provisioning settings now walk you through setting up vendor CLIs step by step instead of leaving you to figure it out. (#402)
- **Securely share vendor secrets with agents.** `@`-mention a vendor in the composer to hand an agent the env vars it needs, and save pasted vendor env vars straight from the Code tab chat. (#404, #403)
- **Create a PR from the Code titlebar.** A new Create PR button — with skill attachment — lets you open a pull request without leaving the workspace. (#406)
- **Open outputs in document tabs.** PDFs, HTML, images, and docs an agent produces now open in dedicated Code tab document tabs. (#394)
- **See edits at a glance.** Edited-file chips appear at the end of each session turn and expand inline; hover a chip for a quick diff preview. (#395, #396)
- **Richer agent transcripts.** Tool runs now show rich icons and per-stack logos so you can scan what an agent did faster. (#392)
- **Cloud vs Tailscale pairing, restored.** Choose a Cloud relay or your own Tailscale network when pairing — back in both the download flow and the Devices tab. (#390)
- **Small touches.** Hover-to-copy on chat message rows and a hover effect on the workspace new-tab button. (#405, #400)

## Fixes

- **More accurate spend.** Analytics now pulls Cursor spend from the Cursor dashboard billing API. (#407)
- **More reliable self-hosting.** Relay auto-provision is fixed and self-hosting pairing is Tailscale-first. (#393)
- **Multi-account polish.** Secondary-account usage gauges and menu-bar toggles behave correctly. (#391)
- **Model toggles stay put.** Cross-provider model toggles no longer jump off the current tab. (#398)
- **Terminal niceties.** The terminal auto-focuses when a Claude session is ready, and terminal tabs are labelled "Terminal — branch" instead of "Shell". (#401, #399)

Ships build 236 for Mac (signed Sparkle feed) with iOS/watchOS to TestFlight and the public App Store on the same build.
