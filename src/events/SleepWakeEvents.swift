import Cocoa

class SleepWakeEvents {
    static func observe() {
        // system sleep/wake and display sleep/wake both suspend our event taps long enough for macOS to
        // disable them with kCGEventTapDisabledByTimeout; we re-enable them on resume (#5723)
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private static func handleWake(_ notification: Notification) {
        Logger.info { "" }
        reEnableAllTaps()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reEnableAllTaps() }
        // the WindowServer puts the screen's windows back a beat later, as order-ins that are not raises (#5936)
        TrackedWindowStateBridge.dispatch(.systemReshow(now: ProcessInfo.processInfo.systemUptime, source: .wake))
    }

    static func reEnableAllTaps() {
        TrackpadEvents.reEnableTapIfNeeded()
        ScrollwheelEvents.reEnableTapIfNeeded()
        KeyboardEvents.reEnableTapIfNeeded()
        CursorEvents.reEnableTapIfNeeded()
    }
}
