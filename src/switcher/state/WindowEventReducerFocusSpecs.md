# WindowEventReducer — the front of the MRU after a removal — Specs

## Summary

Covers `WindowEventReducer.refrontAfterRemovingTheFocusedWindow`: what happens to MRU slot 0 when the window
holding it is removed. Specs + Tests without a same-named kernel (like `WindowEventReducerPhantom`): the
subject is a reducer decision, not a pure function of its own.

The captured scenario is driven through `TestReducerRunner`, because the bug only appears as a SEQUENCE
(activation, two 808s, a removal); the rule-level scenarios drive `WindowEventReducer.reduce` directly.

## Why this exists (#5346)

The reporter's REAPER window stopped moving in the switcher: every alt-tab landed back on the window they
were already in, and the first tile was a Finder window they had left minutes ago. Their `--logs=debug`
capture (2026-07-27, v11.4.3) shows the exact instant it breaks:

    13:28:08.607 focusTarget (pid:681 finder) (wid:3449)      ← Finder takes MRU slot 0
    13:28:13.634 WS windowFocused wid=4557                     ← REAPER's "Insert Multiple Media Items",
    13:28:13.845 discovered a new window: (wid:4557)             opened by a drag while REAPER is BACKGROUND
    13:28:14.961 WS windowFocused wid=4557                     ← the click that dismisses it ACTIVATES REAPER
    13:28:14.962 WS windowFocused wid=4274                     ← the main window, 1 ms later
    13:28:16.960 deinit (wid:4557 title:Insert Multiple Media Items)

The dialog is discovered while its app is in the background, so the freshly-created promotion fronts it
(correctly — it IS the focused window). The click then activates REAPER, and of the two 808s that activation
emits, the first (the dialog) is the focus and the second (the main window) is the raise tail, which
`ActivationFocusResolver` swallows by design (#5596). Both decisions are right on their own. What was missing
is the third: when the dialog is removed, closing the MRU gap hands slot 0 to whoever held slot 1 — **Finder**,
an app that is not even frontmost.

Nothing corrected it afterwards, which is why the reporter saw it as permanent rather than as a glitch:
re-focusing the already-focused window of the already-frontmost app emits neither an activation nor an 808, so
each alt-tab (`13:28:42.720`, `43.671`, `44.680`, all `focusTarget (wid:4274)`) selected the window the user
was already in and left the order exactly as it was.

**The rule: macOS never moves focus to another app because a window closed.** So when the removed window held
slot 0, the front goes to the frontmost app's own next window, not to the global runner-up.

---

## Test scenarios

Mirrors `WindowEventReducerFocusTests.swift` 1:1.

### A. The captured #5346 sequence

- **testDialogClosingLeavesTheFrontmostAppInFront** — the transcribed REAPER capture: after the dialog is
  removed, the main window owns slot 0 and Finder is behind it. Without the re-front this ends `reaper=1
  finder=0`, which is the reported bug exactly (first tile Finder, alt-tab lands on the current window).
- **testTheSameSequenceWithoutTheActivationNeedsNoRepair** — the counterfactual that isolates the trigger:
  drop the activation and the main window's 808 is no longer a raise tail, so the ordinary focus path already
  puts it in front. The repair is what covers the activation timing, nothing else.

### B. The rule

- **testRemovingTheFocusedWindowPromotesTheFrontmostAppsNextWindow** — another app holds slot 1; the
  frontmost app's own next window is promoted over it, and `.applyFocus` names it.
- **testRemovingANonFrontWindowPromotesNothing** — a window at slot 2 closes: slot 0 is untouched, so nothing
  is re-fronted and no ordinary close churns the MRU.
- **testRemovingTheFrontmostAppsOnlyWindowPromotesNothing** — with no window left in the frontmost app there
  is nothing to promote, and the global shift stands (the app is about to go windowless).
- **testMinimizedWindowsAreNotPromoted** — a minimized window is not on screen and did not receive the focus
  the closing window gave up.
- **testInactiveTabsAreNotPromoted** — an inactive tab isn't on screen either; its group's representative is
  what the user sees.

### C. Restoring a minimized window (QA I-11, #5439's shape)

Restoring is the ONE AltTab focus that stirs the app's other windows: it deminiaturizes before focusing.
Every other AltTab focus raises exactly one window, which is why an AltTab-initiated activation normally
snapshots nothing (`ActivationFocusResolver.onActivation`) — and why that premise had to be narrowed here
rather than dropped. These two pin the reducer end: the kernel only learns the target was minimized because
`appActivated` reads it off our own model, and no kernel test can prove that call site passes it.

- **testRestoringAMinimizedWindowKeepsItInFrontOfItsSibling** — the transcribed capture: AltTab focuses the
  minimized window, macOS answers with a focus 808 for the SIBLING 38ms in, and the restored window must
  still own slot 0 with the sibling not moving at all. Without the fix the sibling takes slot 0 and the
  window the user picked is second — the reported bug exactly.
- **testFocusingANonMinimizedWindowStillLetsTheSiblingsFocusBump** — the counterfactual that keeps #5785
  safe: the same tail against a non-minimized target still bumps, because there no tail was caused. The two
  behaviours differ only by whether AltTab had to deminiaturize.

### D. The desktop being put back (#5936)

An order-in of the active app's window is read as a raise, because the native Cmd+` emits nothing else.
Three OS gestures break that reading, all with the same signature: every window of every app ordered in
inside one millisecond, and — unlike a Space re-show, an un-hide or a fullscreen exit — **no order-out
first**, so `offScreen` is empty and `cameBackOnScreen` cannot tell a re-show from a raise. Measured live
(macOS 26, 2026-08-12), each with the lag from its own signal to the burst:

| trigger | signal | lag | mute | notes |
|---|---|---|---|---|
| Mission Control / App Exposé | `AXExposeShowAllWindows` (Dock AX) | 12-106ms | 0.5s | the common one; caught doing the full damage |
| display wake / unlock | `screensDidWake` / `screenIsUnlocked` | 2.03s (×3) | 3s | only bites on a Mac that does not lock |
| display reconfiguration | `didChangeScreenParameters` | ~500ms | 1.5s | was surviving on luck inside `inSpaceTransition`, once by 28ms |

`WindowEventReducer.systemReshowMute(source)` sizes each mute for its own trigger, 3-5x that trigger's lag,
armed from `DockEvents`, `SleepWakeEvents` / `ScreenLockEvents` and `ScreensEvents`. One 3s window for all
three put the cost where users meet it: dismiss Mission Control, cycle windows a beat later, and the raise
lands inside a mute sized for a wake that never happened.

The wake case only bites where the screen does not lock: with loginwindow holding the front, the
app-is-active guard already swallows the burst. Mission Control has no such accidental cover, which is why
it is the trigger that reproduces on any Mac, at any time of day, with no idling involved.

- **testTheWakeBurstDoesNotReorderTheMru** — the measured burst against an interleaved MRU: no window is
  re-fronted and the order is untouched. Without the mute the active app's windows walk to the top in burst
  order, which is the report ("all my Chrome windows are at the front", after only stepping away).
- **testTheMissionControlBurstDoesNotReorderTheMru** — the capture that showed the damage in full: the
  frontmost app's three windows, at MRU 0, 2 and 3, all re-fronted 12ms after the Dock notification with
  nothing else in flight. Same rule, the trigger users actually hit.

Under the signals sits a BACKSTOP that needs none of them (`reshowBurstGap`, 5ms): a raise moves one window,
a re-show moves all of them at once, so an order-in landing within 5ms of an order-in for a DIFFERENT window
does not bump. It covers the race the signals cannot promise to win — both the Dock notification and the
burst reach the main queue by `async`, and three of ten measured rounds had them in the same millisecond —
and any re-show trigger nobody has wired a signal for. It cannot judge a burst's FIRST member, which is the
harmless one (the frontmost app's front window, at MRU 0 in both captures).

- **testABurstIsCaughtByItsShapeWithNoSignalArmed** — the same burst with nothing armed: the first member
  keeps the front it already had, the rest do not move.
- **testALoneOrderInStillBumps** — Cmd+` keeps working: an order-in arriving alone bumps, 200ms being under
  the fastest human action ever captured (219ms).
- **testTheSameWindowTwiceIsNotABurst** — one window reported twice in an instant is not two windows; that
  is the shape of every genuine focus, whose 808 and 815 land together.
- **testAnUntrackedWidCountsAsBurstEvidence** — the record covers the whole order-in stream, tracked or not,
  since a burst with holes in it stops looking like a burst.
- **testAnInAppRaiseStillBumpsOnceTheMuteExpired** — time-bounded, because the signal it stands in front of
  is real: past the window, an order-in is a Cmd+` raise again.
- **testAnInAppRaiseASecondAfterMissionControlStillBumps** / **testTheWakeMuteStillCoversItsOwnLateBurst** —
  the pair that pins the per-source sizing from both ends: a raise 1s after Mission Control bumps, while a
  burst 2.03s after a wake does not. A single 3s mute fails the first; a single 0.5s mute fails the second.
- **testAFocusEventDuringTheMuteStillBumps** — only the order-in path is muted. An 808 is the OS stating a
  focus rather than us inferring one, and the burst contains none.
- **testRestoringAMinimizedWindowDuringTheMuteStillBumps** — an un-minimize is spared, as it is spared the
  `cameBackOnScreen` exclusion: a wake leaves minimized windows minimized, and a Dock restore inside the
  frontmost app emits ONLY that order-in, so a swallowed bump would never be corrected (#5439).
