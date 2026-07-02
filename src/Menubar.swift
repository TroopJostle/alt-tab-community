import Cocoa

class Menubar {
    static var statusItem: NSStatusItem!
    static var menu: NSMenu!
    static var permissionCalloutMenuItems: [NSMenuItem]?
    private static var permissionCallout: PermissionCallout?
    private static let menuDelegate = MenubarMenuDelegate()
    private static var isVisibleObserver: NSKeyValueObservation?

    @discardableResult
    static func addMenuItem(_ title: String, _ action: Selector, _ keyEquivalent: String, _ symbolName: String?, _ color: NSColor? = nil, _ target: AnyObject? = nil) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        if #available(macOS 26.0, *), let symbolName {
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            if let color {
                item.image = item.image?.withSymbolConfiguration(.init(paletteColors: [color]))
            }
        }
        return item
    }

    static func initialize() {
        menu = NSMenu()
        menu.title = App.name // perf: prevent going through expensive code-path within appkit
        menu.delegate = menuDelegate
        let permissionCalloutMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let callout = PermissionCallout()
        permissionCallout = callout
        permissionCalloutMenuItem.view = callout
        let calloutSeparator = NSMenuItem.separator()
        permissionCalloutMenuItems = [permissionCalloutMenuItem, calloutSeparator]
        addMenuItem(NSLocalizedString("Show", comment: "Menubar option"), #selector(App.showUiFromShortcut0), "", "eye", nil, App.self)
        menu.addItem(NSMenuItem.separator())
        addMenuItem(NSLocalizedString("Settings…", comment: "Menubar option"), #selector(App.showSettingsWindow), ",", "gear", nil, App.self)
        addMenuItem(NSLocalizedString("Check for updates…", comment: "Menubar option"), #selector(App.checkForUpdatesNow), "", "checkmark.arrow.trianglehead.clockwise", nil, App.self)
        addMenuItem(NSLocalizedString("Check permissions…", comment: "Menubar option"), #selector(App.checkPermissions), "", "hand.raised", nil, App.self)
        menu.addItem(NSMenuItem.separator())
        addMenuItem(String(format: NSLocalizedString("About %@", comment: "Menubar option. %@ is AltTab"), App.name), #selector(App.showAboutWindow), "", "info.circle", nil, App.self)
        addMenuItem(NSLocalizedString("Debug tools", comment: "Menubar option"), #selector(App.showDebugWindow), "", "scope", nil, App.self)
        addMenuItem(NSLocalizedString("Send feedback…", comment: "Menubar option"), #selector(App.showFeedbackPanel), "", "text.bubble", nil, App.self)
        addMenuItem(NSLocalizedString("Support this project", comment: "Menubar option"), App.supportProjectAction, "", "heart.fill", .red, App.self)
        menu.addItem(NSMenuItem.separator())
        addMenuItem(String(format: NSLocalizedString("Quit %@", comment: "%@ is AltTab"), App.name), #selector(NSApplication.terminate(_:)), "q", nil) // "xmark.rectangle" is not necessary; macos automatically recognizes Quit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.target = self
        statusItem.button!.action = #selector(statusItemOnClick)
        statusItem.button!.sendAction(on: [.leftMouseDown, .rightMouseDown])
        // Apply icon prefs eagerly here, while the status item is still being added to the
        // menubar. Doing it later (from PreferencesEvents.initialize) sets `button.image` after
        // the WindowServer has already laid the menubar out at its imageless default size, then
        // invalidates NSStatusBarContentView mid-FBS-scene-update — `_NSDetectedLayoutRecursion`.
        applyMenubarIconPreferences()
        observeRemovalFromMenubar()
        #if DEBUG
        installQAMenuMiddleClickMonitor()
        #endif
    }

    #if DEBUG
    private static var qaMenuMiddleClickMonitor: Any?

    // NSStatusBarButton doesn't forward `.otherMouseDown` to its action even when added to
    // `sendAction(on:)`. A local event monitor sees the click before the button can swallow it.
    private static func installQAMenuMiddleClickMonitor() {
        qaMenuMiddleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard event.buttonNumber == 2,
                  let buttonWindow = statusItem?.button?.window,
                  event.window === buttonWindow else { return event }
            QAMenu.toggleVisibility()
            return nil
        }
    }
    #endif

    // The callout is only useful when the user lacks Screen Recording AND has settings that need it
    // (Thumbnails style or window previews). Users who skipped the permission but use neither aren't
    // nagged (see #5623). Its copy names whichever of the two features are actually affected, so we
    // refresh the text before showing it. Re-evaluated on permission ticks and on each menu open
    // (settings can change). Decision logic lives in `PermissionCalloutResolver` (unit-tested).
    static func refreshPermissionCallout() {
        let dependentFeatures = Preferences.screenRecordingDependentFeatures
        let show = PermissionCalloutResolver.shouldShowCallout(
            screenRecordingGranted: ScreenRecordingPermission.status == .granted,
            dependentFeatures: dependentFeatures)
        if show { permissionCallout?.update(dependentFeatures) }
        togglePermissionCallout(show)
    }

    // NSMenuItem.isHidden isn't reliable with custom views. We add/remove to hide/show these items
    static func togglePermissionCallout(_ show: Bool) {
        permissionCalloutMenuItems?.enumerated().forEach { offset, element in
            if show && !menu.items.contains(element) {
                menu.insertItem(element, at: offset)
            }
            if !show && menu.items.contains(element) {
                menu.removeItem(element)
            }
        }
    }

    @objc static func statusItemOnClick() {
        // NSApp.currentEvent == nil if the icon is "clicked" through VoiceOver
        if let type = NSApp.currentEvent?.type, type != .leftMouseDown {
            App.showUiFromShortcut0()
        } else {
            statusItem.popUpMenu(Menubar.menu)
        }
    }

    static func menubarIconCallback(_: NSControl?) {
        // Guard: can be invoked before `Menubar.initialize()`, at which point `statusItem` is still nil.
        guard statusItem != nil else { return }
        applyMenubarIconPreferences()
        if let menubarIconDropdown = GeneralTab.menubarIconDropdown {
            menubarIconDropdown.isEnabled = Preferences.menubarIconShown
        }
    }

    static private func applyMenubarIconPreferences() {
        if Preferences.menubarIconShown {
            loadPreferredIcon()
        } else {
            statusItem.isVisible = false
        }
    }

    // The user can ⌘-drag the icon off the menubar (enabled by `.removalAllowed`). When that
    // happens, `isVisible` flips true→false and we persist the preference. Observing here in
    // `Menubar` rather than in `GeneralTab` means we react whether or not Settings is open.
    static private func observeRemovalFromMenubar() {
        statusItem.behavior = .removalAllowed
        isVisibleObserver = statusItem.observe(\.isVisible, options: [.old, .new]) { _, change in
            if change.oldValue == true && change.newValue == false {
                Preferences.set("menubarIconShown", "false")
                GeneralTab.menuIconShownToggle?.setSilently(.off)
            }
        }
    }

    static private func loadPreferredIcon() {
        let i = Preferences.menubarIcon.indexAsString
        let image = NSImage(named: "menubar-\(i)")!
        image.isTemplate = i != "2"
        statusItem.button!.image = image
        statusItem.isVisible = true
        statusItem.button!.imageScaling = .scaleProportionallyUpOrDown
    }
}

private final class MenubarMenuDelegate: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        Menubar.refreshPermissionCallout()
    }
}

class PermissionCallout: StackView {
    private var label: NSTextField!
    private var button: NSButton!

    convenience init() {
        let label = NSTextField(wrappingLabelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.preferredMaxLayoutWidth = 250
        label.isSelectable = false
        label.addOrUpdateConstraint(label.widthAnchor, 250)
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.attributedTitle = NSAttributedString(string: NSLocalizedString("Grant permission", comment: "Menubar callout button"), attributes: [NSAttributedString.Key.foregroundColor: NSColor.white])
        self.init([label, button], .vertical, true, top: 8, right: 15, bottom: 10, left: 15)
        self.label = label
        self.button = button
        wantsLayer = true
        layer!.backgroundColor = NSColor.purple.cgColor
    }

    // NSControl target/action never fires inside an NSMenuItem custom view: the menu's modal
    // tracking loop swallows the click before the button's own mouse-tracking can call sendAction.
    // So we route the click through the container exactly like `UpgradeMenuItemView` — `hitTest`
    // keeps the button visual-only, and `mouseUp` runs the action and dismisses the menu. (#5771)
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard button.frame.contains(location) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        Preferences.remove("screenRecordingPermissionSkipped")
        App.restart()
    }

    // Name only the feature(s) the user actually enabled, so we never promise back a feature they
    // don't use. The wrapped label's height depends on the message, so re-fit after setting it.
    func update(_ dependentFeatures: PermissionCalloutResolver.DependentFeatures) {
        label.stringValue = PermissionCallout.message(dependentFeatures)
        // The earlier fit() pinned our height with a required constraint sized for the previous
        // (initially empty) message. While it stays active, fittingSize keeps reporting that stale
        // height, so re-fitting can't grow to fit the new text and the last line clips. Drop the
        // self-imposed size constraints first so fit() measures the real content. (#5771)
        constraints.filter {
            ($0.firstAnchor == widthAnchor || $0.firstAnchor == heightAnchor) && $0.secondAnchor == nil
        }.forEach { $0.isActive = false }
        fit()
    }

    // One reusable sentence template + a feature subject inserted at `%@`, so translators localize the
    // shared sentence (and the spacing/punctuation between its two clauses) once and only the subject
    // varies. The Thumbnails subject reuses the existing appearance-style string, already translated
    // everywhere. `.none` is unreachable here — the callout is hidden when no feature needs it.
    static func message(_ dependentFeatures: PermissionCalloutResolver.DependentFeatures) -> String {
        let subject: String
        switch dependentFeatures {
            case .thumbnails: subject = NSLocalizedString("Thumbnails", comment: "")
            case .previews: subject = NSLocalizedString("Window previews", comment: "Menubar callout subject: the preview-selected-window feature")
            case .both: subject = NSLocalizedString("Thumbnails and window previews", comment: "Menubar callout subject")
            case .none: return ""
        }
        return String(format: NSLocalizedString("AltTab is running without Screen Recording permissions. %@ won’t show.", comment: "Menubar callout. %@ is one or more feature names, e.g. Thumbnails"), subject)
    }
}
