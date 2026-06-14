# Continuum 0.41.0

Smoother Code-workspace resizing, clearer terminal tabs, and a quieter, more polished Code tab — plus faster app updates under the hood.

## New

- **Smooth pane resizing.** Dragging the Code-workspace sidebar and review-pane dividers now tracks your cursor smoothly instead of snapping, and your chosen widths persist. (#476)
- **Numbered terminal tabs.** Mac terminal tabs are now labeled positionally (T1, T2, T3…) so you can tell panes apart at a glance. (#475)
- **Drag a project to reorder it.** The whole project header in the Code sidebar is now a drag handle with a palm cursor — the grip dots are gone, and the row lights up on hover. (#468, #469)

## Fixes

- **Terminals re-fit after you resize.** A terminal pane now recalibrates its size when you drag the review-pane divider, instead of staying stuck at its old width. (#473)
- **Review pane keeps a constant width.** Switching to the Diff tab no longer widens the review pane — it stays the width you set across every tab. (#477)

## Polish

- **Cleaner Code tab.** Removed the redundant session-detail metadata strip and the hairline divider above the composer for a calmer layout. (#467, #471)
- **Consistent hover + cursor feedback.** Review-pane tabs, terminal tabs (with a hover-close affordance), and the worktree archive button now show hover states and the pointing-hand cursor. (#472, #474, #478)

## Under the hood

- **Faster, smaller app updates.** Continuum now ships Sparkle binary-delta updates, so updating downloads only what changed instead of the whole app. (#470)

Ships build 246 for Mac (signed Sparkle feed), with iOS/watchOS to TestFlight.
