# Continuum 0.42.2

A polish pass across the chat thread, the composer, and the Code workspace — clearer "working" indicators, a tidier composer, and live-updating diff and PR-status indicators.

## Chat & working indicators

- **Steadier "working" indicator.** The live activity stream now uses a consistent orange working accent, blends seamlessly into the thread without a pill border, and stops the moment a turn completes instead of lingering. (#499, #506, #510)
- **Quieter turns.** Chat turns with nothing to expand no longer show an empty disclosure control. (#498)
- **Jump-to-latest, repositioned.** The "jump to latest" button now sits just above the composer where it's easier to reach. (#501)
- **Visible copy button.** The message copy affordance is now a clear, self-contained button. (#502)

## Composer

- **Tidier follow-up queue.** Queued follow-up sends now render above the composer box (not inside it), and the redundant in-composer queue button is gone — queue a follow-up by pressing Return while a session is working. (#508, #509)
- **No more stuck attachments.** Fixed an attachment that could stay "pending" in the composer after you sent a message. (#497)
- **Cleaner context indicator.** Removed the redundant context-usage percent label next to the usage ring. (#496)

## Code workspace

- **Live diff & PR indicators.** The +N/-N diff counts now refresh live as files change, the branch PR-status icon updates promptly, and the worktree diff stays visible even while hovering the archive button. (#505, #504, #507)
- **Clearer session labels.** Active-session tab labels resolve more reliably and show a live activity stream behind running sessions. (#500)
- **Edited-file icons.** Edited-file chips now show each file's tech-stack brand icon. (#503)

Ships build 249 for Mac (signed Sparkle feed), with iOS/watchOS to TestFlight.
