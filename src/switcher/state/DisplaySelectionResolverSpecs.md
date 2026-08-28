# Fixed display selection

AltTab can pin its switcher to one display by persisting that display's UUID. UUIDs survive display
reordering and resolution changes, unlike `NSScreen.screens` indices.

## Behavior

- The existing Active, Mouse, and Menu Bar display policies remain unchanged and Active remains the default.
- Specific Screen uses the persisted UUID whenever that display is connected.
- If the selected display is disconnected, AltTab keeps the persisted selection but temporarily uses the
  active display. If that fallback cannot be resolved, it uses the first connected display.
- Reconnecting the selected display restores it automatically. With no connected displays, resolution returns nil.

## Tests

- **testConnectedSelectionWins** — a connected selected UUID overrides the fallback.
- **testDisconnectedSelectionUsesConnectedFallback** — a missing selection uses the connected active display.
- **testUnavailableFallbackUsesFirstConnectedDisplay** — a stale fallback safely uses the first connected display.
- **testNoConnectedDisplayReturnsNil** — an empty display list cannot produce a selection.
