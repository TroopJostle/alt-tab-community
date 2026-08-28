import Cocoa

class ScreensEvents {
    private static let screenChangeThrottler = Throttler(delayInMs: 200)

    static func observe() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleEvent), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private static func handleEvent(_ notification: Notification) {
        // Adding, removing or resizing a screen re-shows every window ~500ms later, as order-ins with no
        // order-out in front of them, which the raise rule would read as the user fronting each one (#5936).
        // Armed OUTSIDE the throttler: the throttle exists to collapse the grouped notifications into one
        // expensive refresh, while this is one assignment that must not be delayed or dropped.
        TrackedWindowStateBridge.dispatch(.systemReshow(now: ProcessInfo.processInfo.systemUptime, source: .screens))
        // screen notifications often arrive in groups (e.g. 2 in a row in a short time)
        screenChangeThrottler.throttleOrProceed {
            Logger.debug { notification.name.rawValue }
            Spaces.refresh()
            Screens.refresh()
            // a screen added or removed, or screen resolution change can mess up layout; we reset components
            App.resetPreferencesDependentComponents()
            // a screen added or removed can shuffle windows around Spaces; we refresh them
            App.refreshOpenUiAfterExternalEvent(Windows.list)
            Logger.info { "screens:\(NSScreen.screens.map { ($0.cachedUuid() ?? "nil" as CFString, $0.frame) })" }
            Logger.info { "currentSpace:\(Spaces.currentSpaceIndex) (id:\(Spaces.currentSpaceId)) spaces:\(Spaces.screenSpacesMap)" }
        }
    }
}
