import Foundation

class DockEvents {
    private static var axObserver: AXObserver?
    private static var axUiElement: AXUIElement?

    static func observe(_ dockPid: pid_t) {
        if #available(macOS 12.0, *) {
            axUiElement = AXUIElementCreateApplication(dockPid)
            AXObserverCreate(dockPid, handleEvent, &axObserver)
            // are we sure we always get a non-nil axObserver?
            for notification in MissionControlState.allCases {
                AXCallScheduler.shared.schedule(key: "sub-dock-\(notification.rawValue)", context: "dock", pid: dockPid) {
                    if try axUiElement!.subscribeToNotification(axObserver!, notification.rawValue, nil) {
                        if notification == MissionControlState.showDesktop {
                            Logger.debug { "Subscribed to Dock" }
                        }
                    }
                }
            }
            CFRunLoopAddSource(BackgroundWork.missionControlThread.runLoop, AXObserverGetRunLoopSource(axObserver!), .commonModes)
        } else {
            // we could handle macOS < 12 here like yabai does. However, they poll with ax calls until they notice Mission Control stops
            // this takes up ressources when Mission Control is open. If the user keeps it open for a few hours, this would accelerate battery usage
            // SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 1204, NULL);
            // then listen every 0.1f * NSEC_PER_SEC for layer == 18 and owner = "Dock"
            // when found, mission control is not active anymore
        }
    }

    private static let handleEvent: AXObserverCallback = { _, _, notificationName, _ in
        Logger.debug { notificationName }
        let state = MissionControlState(rawValue: notificationName as String)!
        MissionControl.setState(state)
        // Opening Mission Control / Exposé / Show Desktop re-shows the whole desktop 12-106ms later, as
        // order-ins with no order-out in front of them — indistinguishable from a Cmd+` raise per window, so
        // the active app's windows would all re-front (#5936). Stamped and dispatched from THIS thread's
        // arrival (the observer runs on `missionControlThread`) so the mute is armed by the time the burst's
        // own main-queue blocks run. Exiting is deliberately NOT armed: no capture has ever shown a burst on
        // the way out, and the mute for this source is short precisely so that cycling windows right after
        // dismissing Mission Control still moves the MRU.
        guard state != .inactive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { TrackedWindowStateBridge.dispatch(.systemReshow(now: now, source: .missionControl)) }
    }
}
