import AppKit
import Foundation

/// Portable AeroSpace integration. AeroSpace owns topology; AltTab owns windows, MRU, and thumbnails.
final class AeroSpaceWorkspaceCards {
    static let shared = AeroSpaceWorkspaceCards()
    static let managedWorkspaces: Set<String> = ["2", "3", "4", "5"]
    static let proxyAspectRatio = CGSize(width: 16, height: 10)

    struct Entry: Decodable {
        let windowId: UInt32
        let workspace: String
        enum CodingKeys: String, CodingKey { case windowId = "window-id", workspace }
    }
    struct SubscriptionEvent: Decodable {
        let event: String
        let workspace: String?
        let prevWorkspace: String?
        enum CodingKeys: String, CodingKey {
            case event = "_event", workspace, prevWorkspace
        }
    }

    struct Card {
        let workspace: String
        let representative: Window
        let windows: [Window]
        let frames: [CGWindowID: CGRect]
    }

    private(set) var focusedWorkspace = "⠀"
    private var membership = [CGWindowID: String]()
    private var layoutCache = [String: [CGWindowID: CGRect]]()
    private var cardsByRepresentative = [CGWindowID: Card]()
    private var recoveryTimer: Timer?
    private var subscriptionProcess: Process?
    private var subscriptionPipe: Pipe?
    private var subscriptionBuffer = Data()
    private var subscriptionRestartWorkItem: DispatchWorkItem?
    private var topologyRefreshWorkItem: DispatchWorkItem?
    private var geometryRefreshWorkItem: DispatchWorkItem?
    private var subscriptionGeneration: UInt64 = 0
    private var subscriptionFailureCount = 0
    private var monitoringEnabled = false
    private var queryInFlight = false
    private var pendingRefresh = false
    private var revision: UInt64 = 0
    private var consecutiveRefreshFailures = 0
    private var lastStateFingerprint = ""
    private let executable = "/opt/homebrew/bin/aerospace"

    var enabled: Bool { Preferences.aeroSpaceWorkspaceCards }
    var isThumbnailMode: Bool {
        Preferences.effectiveAppearanceStyle(SwitcherSession.activeShortcutIndex) == .thumbnails
    }

    func reconcileMonitoring() {
        if enabled {
            if !monitoringEnabled { start() }
        } else if monitoringEnabled {
            stop()
        }
    }

    func stop() {
        monitoringEnabled = false
        subscriptionGeneration &+= 1
        subscriptionRestartWorkItem?.cancel()
        topologyRefreshWorkItem?.cancel()
        geometryRefreshWorkItem?.cancel()
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        subscriptionPipe?.fileHandleForReading.readabilityHandler = nil
        subscriptionProcess?.terminationHandler = nil
        if subscriptionProcess?.isRunning == true { subscriptionProcess?.terminate() }
        subscriptionProcess = nil
        subscriptionPipe = nil
        subscriptionBuffer.removeAll(keepingCapacity: false)
        pendingRefresh = false
        cardsByRepresentative.removeAll(keepingCapacity: false)
    }

    func start() {
        guard enabled, recoveryTimer == nil else { return }
        monitoringEnabled = true
        refresh()
        startSubscription()
        // Rare safety net only. Normal updates are event-driven.
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        recoveryTimer?.tolerance = 15.0
    }

    private func startSubscription() {
        guard enabled, subscriptionProcess == nil,
              FileManager.default.isExecutableFile(atPath: executable) else { return }
        subscriptionRestartWorkItem?.cancel()
        subscriptionBuffer.removeAll(keepingCapacity: true)

        subscriptionGeneration &+= 1
        let generation = subscriptionGeneration
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["subscribe", "--no-send-initial", "focused-workspace-changed", "focus-changed", "window-detected"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        subscriptionProcess = process
        subscriptionPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, generation == self.subscriptionGeneration, self.monitoringEnabled else { return }
                self.consumeSubscriptionData(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, generation == self.subscriptionGeneration else { return }
                self.subscriptionDidTerminate(generation: generation)
            }
        }
        do {
            try process.run()
        } catch {
            subscriptionDidTerminate(generation: generation)
        }
    }

    private func subscriptionDidTerminate(generation: UInt64) {
        guard generation == subscriptionGeneration else { return }
        subscriptionPipe?.fileHandleForReading.readabilityHandler = nil
        subscriptionProcess = nil
        subscriptionPipe = nil
        guard enabled, monitoringEnabled else { return }
        let delays: [TimeInterval] = [2, 5, 15, 30, 30]
        let delay = delays[min(subscriptionFailureCount, delays.count - 1)]
        subscriptionFailureCount = min(subscriptionFailureCount + 1, delays.count - 1)
        let work = DispatchWorkItem { [weak self] in self?.startSubscription() }
        subscriptionRestartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func consumeSubscriptionData(_ data: Data) {
        subscriptionBuffer.append(data)
        while let newline = subscriptionBuffer.firstIndex(of: 0x0A) {
            let line = subscriptionBuffer.prefix(upTo: newline)
            subscriptionBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let event = try? JSONDecoder().decode(SubscriptionEvent.self, from: Data(line)) else { continue }
            handleSubscriptionEvent(event)
        }
    }

    private func handleSubscriptionEvent(_ event: SubscriptionEvent) {
        subscriptionFailureCount = 0
        if event.event == "focused-workspace-changed", let workspace = event.workspace {
            focusedWorkspace = workspace
            scheduleGeometryRefresh(delay: 0.12)
            scheduleTopologyRefresh(delay: 0.10)
        } else if event.event == "focus-changed" {
            if let workspace = event.workspace { focusedWorkspace = workspace }
            scheduleGeometryRefresh(delay: 0.08)
        } else if event.event == "window-detected" {
            scheduleTopologyRefresh(delay: 0.15)
        }
    }

    /// Called by AltTab's existing WindowServer stream. Geometry changes are local and need no CLI.
    func notifyWindowServerChange(topologyChanged: Bool) {
        guard enabled else { return }
        if topologyChanged {
            scheduleTopologyRefresh(delay: 0.18)
        } else {
            scheduleGeometryRefresh(delay: 0.20)
        }
    }

    private func scheduleTopologyRefresh(delay: TimeInterval) {
        topologyRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        topologyRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleGeometryRefresh(delay: TimeInterval) {
        geometryRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.captureActiveLayout()
        }
        geometryRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Background cache refresh. This is never called from shortcut/show/navigation paths.
    private func refresh() {
        guard enabled, FileManager.default.isExecutableFile(atPath: executable) else { return }
        if queryInFlight {
            pendingRefresh = true
            return
        }
        queryInFlight = true
        run(["list-windows", "--all", "--json", "--format", "%{window-id} %{workspace}"]) { [weak self] status, data in
            guard let self else { return }
            guard status == 0, let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
                self.finishRefresh()
                self.consecutiveRefreshFailures += 1
                return
            }
            self.run(["list-workspaces", "--focused"]) { [weak self] focusStatus, focusData in
                guard let self else { return }
                self.finishRefresh()
                guard focusStatus == 0,
                      let value = String(data: focusData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else {
                    self.consecutiveRefreshFailures += 1
                    return
                }
                self.consecutiveRefreshFailures = 0
                self.apply(entries, focusedWorkspace: value)
            }
        }
    }

    private func finishRefresh() {
        queryInFlight = false
        guard pendingRefresh else { return }
        pendingRefresh = false
        scheduleTopologyRefresh(delay: 0.05)
    }

    private func run(_ arguments: [String], completion: @escaping (Int32, Data) -> Void) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        process.terminationHandler = { task in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async { completion(task.terminationStatus, data) }
        }
        do { try process.run() } catch { DispatchQueue.main.async { completion(-1, Data()) } }
    }

    private func apply(_ entries: [Entry], focusedWorkspace: String) {
        self.focusedWorkspace = focusedWorkspace
        membership = Dictionary(uniqueKeysWithValues: entries.map { (CGWindowID($0.windowId), $0.workspace) })
        captureActiveLayout()
        let fingerprint = stateFingerprint(entries)
        guard fingerprint != lastStateFingerprint else { return }
        lastStateFingerprint = fingerprint
        revision &+= 1
        #if DEBUG
        writeDiagnostics(entries)
        #endif
    }

    /// Frames are trusted only while AeroSpace says that workspace is focused.
    private func captureActiveLayout() {
        guard Self.managedWorkspaces.contains(focusedWorkspace), let screen = NSScreen.main?.frame else { return }
        var frames = [CGWindowID: CGRect]()
        for window in Windows.list where !window.isFullscreen {
            guard let wid = window.cgWindowId, membership[wid] == focusedWorkspace,
                  let position = window.position, let size = window.size,
                  size.width > 0, size.height > 0 else { continue }
            frames[wid] = CGRect(x: (position.x - screen.minX) / screen.width,
                                 y: (position.y - screen.minY) / screen.height,
                                 width: size.width / screen.width,
                                 height: size.height / screen.height)
        }
        if !frames.isEmpty { layoutCache[focusedWorkspace] = frames }
    }

    /// Pure projection over cached state. It performs no process, capture, AX, or disk operation.
    func applyProjection() {
        reconcileMonitoring()
        cardsByRepresentative.removeAll(keepingCapacity: true)
        guard enabled, isThumbnailMode else { return }
        let candidates = Windows.list.filter {
            guard let wid = $0.cgWindowId, !$0.isFullscreen, $0.shouldShowTheUser,
                  let workspace = membership[wid] else { return false }
            return Self.managedWorkspaces.contains(workspace)
        }
        let groups = Dictionary(grouping: candidates) { membership[$0.cgWindowId!]! }
        for workspace in Self.managedWorkspaces.sorted() {
            guard let members = groups[workspace], !members.isEmpty else { continue }
            let ordered = members.sorted { $0.lastFocusOrder < $1.lastFocusOrder }
            guard let representative = ordered.first, let wid = representative.cgWindowId else { continue }
            ordered.dropFirst().forEach { $0.shouldShowTheUser = false }
            cardsByRepresentative[wid] = Card(workspace: workspace,
                                               representative: representative,
                                               windows: ordered,
                                               frames: layoutCache[workspace] ?? [:])
        }
    }

    func card(for window: Window) -> Card? { window.cgWindowId.flatMap { cardsByRepresentative[$0] } }

    func previewSize(for window: Window, fallback: NSSize?) -> NSSize? {
        guard card(for: window) != nil else { return fallback }
        let height = TileView.maxThumbnailHeight() - Appearance.edgeInsetsSize * 2 - Appearance.intraCellPadding - Appearance.iconSize
        return NSSize(width: height * Self.proxyAspectRatio.width / Self.proxyAspectRatio.height, height: height)
    }

    enum GroupAction { case close, minimize, hide, quit, fullscreen }

    @discardableResult
    func performGroupAction(_ action: GroupAction, selected window: Window?) -> Bool {
        guard isThumbnailMode, let window, let card = card(for: window) else { return false }
        let windows = card.windows.filter { !$0.isFullscreen && $0.cgWindowId != nil }
        guard !windows.isEmpty else { return true }
        let representativeId = card.representative.cgWindowId
        let ordered = windows.sorted {
            if $0.cgWindowId == representativeId { return false }
            if $1.cgWindowId == representativeId { return true }
            return $0.lastFocusOrder > $1.lastFocusOrder
        }
        switch action {
        case .close:
            ordered.forEach { $0.close() }
        case .minimize:
            let target = ordered.contains { !$0.isMinimized }
            ordered.forEach { $0.setMinimized(target) }
        case .hide:
            let apps = uniqueApplications(ordered)
            let targetHidden = apps.contains { !$0.runningApplication.isHidden }
            apps.forEach { app in
                if app.runningApplication.isHidden != targetHidden { app.hideOrShow() }
            }
        case .quit:
            uniqueApplications(ordered).forEach { $0.quit() }
        case .fullscreen:
            break
        }
        return true
    }

    private func uniqueApplications(_ windows: [Window]) -> [Application] {
        var seen = Set<pid_t>()
        return windows.compactMap { window in
            let app = window.application
            guard seen.insert(app.pid).inserted else { return nil }
            return app
        }
    }

    func activateIfProxy(_ window: Window) -> Bool {
        guard isThumbnailMode, let card = card(for: window) else { return false }
        // Fast path: focus exactly one real window using AltTab's native cross-Space implementation.
        // AeroSpace observes that focus and activates the rest of the target logical workspace.
        card.representative.focus()
        return true
    }

    func configurePresentation(in view: TileView, for window: Window) {
        clearPresentation(in: view)
        guard isThumbnailMode, let card = card(for: window), !view.thumbnail.isHidden else { return }

        view.thumbnail.isHidden = true
        view.appIcon.isHidden = true
        view.label.stringValue = "Workspace \(card.workspace)"
        view.setAccessibilityLabel("Workspace \(card.workspace)")

        let canvas = view.thumbnail.frame
        let background = CALayer()
        background.frame = canvas
        background.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        background.cornerRadius = 4
        background.masksToBounds = true
        view.layer?.addSublayer(background)
        view.aeroSpaceDecorationLayers.append(background)

        let rawFrames = card.frames.isEmpty ? equalGrid(card.windows) : card.frames
        let frames = normalizedToCanvas(rawFrames, windows: card.windows)
        for member in card.windows.reversed() {
            guard let wid = member.cgWindowId, let normalized = frames[wid] else { continue }
            let layer = LightImageLayer()
            let content = member.thumbnail ?? .cgImage(member.icon)
            let layerSize = NSSize(width: max(1, canvas.width * normalized.width), height: max(1, canvas.height * normalized.height))
            layer.updateContents(content, layerSize)
            layer.frame.origin = CGPoint(x: canvas.minX + canvas.width * normalized.minX,
                                         y: canvas.minY + canvas.height * normalized.minY)
            layer.masksToBounds = true
            layer.borderWidth = 0.6
            layer.borderColor = NSColor.disabledControlTextColor.cgColor
            view.layer?.addSublayer(layer)
            view.aeroSpacePreviewLayers.append(layer)
        }

        // One icon per window, including duplicate applications, ordered by window MRU.
        // The strip occupies AltTab's normal leading app-icon slot; the title is moved after it.
        let iconSize = min(24, max(16, view.appIcon.frame.height))
        let spacing: CGFloat = 3
        let stripWidth = CGFloat(card.windows.count) * iconSize + CGFloat(max(0, card.windows.count - 1)) * spacing
        var x = view.appIcon.frame.minX
        let y = view.appIcon.frame.minY + max(0, (view.appIcon.frame.height - iconSize) / 2)
        for member in card.windows {
            let iconLayer = LightImageLayer()
            iconLayer.updateContents(.cgImage(member.icon), NSSize(width: iconSize, height: iconSize))
            iconLayer.frame.origin = CGPoint(x: x, y: y)
            view.layer?.addSublayer(iconLayer)
            view.aeroSpaceIconLayers.append(iconLayer)
            x += iconSize + spacing
        }
        let titleX = view.appIcon.frame.minX + stripWidth + Appearance.appIconLabelSpacing
        view.label.frame.origin.x = titleX
        view.label.setWidth(max(1, view.frame.width - titleX - Appearance.edgeInsetsSize - view.statusIcons.totalWidth))
    }

    private func clearPresentation(in view: TileView) {
        view.aeroSpacePreviewLayers.forEach { $0.removeFromSuperlayer() }
        view.aeroSpaceIconLayers.forEach { $0.removeFromSuperlayer() }
        view.aeroSpaceDecorationLayers.forEach { $0.removeFromSuperlayer() }
        view.aeroSpacePreviewLayers.removeAll(keepingCapacity: true)
        view.aeroSpaceIconLayers.removeAll(keepingCapacity: true)
        view.aeroSpaceDecorationLayers.removeAll(keepingCapacity: true)
        view.thumbnail.isHidden = Appearance.hideThumbnails
        view.appIcon.isHidden = false
    }

    /// Preserve overlap and relative z-order. Clamp only the outer canvas, not intersections.
    private func normalizedToCanvas(_ source: [CGWindowID: CGRect], windows: [Window]) -> [CGWindowID: CGRect] {
        let valid = windows.compactMap { window -> CGRect? in
            guard let wid = window.cgWindowId, let rect = source[wid], rect.width > 0, rect.height > 0 else { return nil }
            return rect
        }
        guard let first = valid.first else { return equalGrid(windows) }
        let union = valid.dropFirst().reduce(first) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return equalGrid(windows) }
        var result = [CGWindowID: CGRect]()
        for window in windows {
            guard let wid = window.cgWindowId, let rect = source[wid] else { continue }
            let normalized = CGRect(x: (rect.minX - union.minX) / union.width,
                                    y: (rect.minY - union.minY) / union.height,
                                    width: rect.width / union.width,
                                    height: rect.height / union.height)
            result[wid] = normalized
        }
        return result
    }

    private func equalGrid(_ windows: [Window]) -> [CGWindowID: CGRect] {
        let count = max(windows.count, 1)
        let columns = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        var result = [CGWindowID: CGRect]()
        for (index, window) in windows.enumerated() {
            guard let wid = window.cgWindowId else { continue }
            result[wid] = CGRect(x: CGFloat(index % columns) / CGFloat(columns),
                                 y: CGFloat(index / columns) / CGFloat(rows),
                                 width: 1 / CGFloat(columns), height: 1 / CGFloat(rows))
        }
        return result
    }

    private func stateFingerprint(_ entries: [Entry]) -> String {
        var parts = ["focus=\(focusedWorkspace)"]
        for entry in entries.sorted(by: { $0.windowId < $1.windowId }) {
            parts.append("w=\(entry.windowId):\(entry.workspace)")
        }
        for workspace in Self.managedWorkspaces.sorted() {
            guard let frames = layoutCache[workspace] else { continue }
            for (windowId, rect) in frames.sorted(by: { $0.key < $1.key }) {
                parts.append(String(format: "f=%@:%u:%.4f:%.4f:%.4f:%.4f", workspace, windowId, rect.origin.x, rect.origin.y, rect.size.width, rect.size.height))
            }
        }
        return parts.joined(separator: "|")
    }

    private func writeDiagnostics(_ entries: [Entry]) {
        let matchedIds = Set(Windows.list.compactMap { $0.cgWindowId })
        let workspaceData = Self.managedWorkspaces.sorted().map { workspace -> [String: Any] in
            let ids = entries.filter { $0.workspace == workspace }.map { Int($0.windowId) }
            return ["workspace": workspace,
                    "aerospaceWindowIds": ids,
                    "matchedAltTabWindowIds": ids.filter { matchedIds.contains(CGWindowID($0)) },
                    "cachedFrameWindowIds": layoutCache[workspace]?.keys.map { Int($0) } ?? []]
        }
        let object: [String: Any] = ["revision": Int(revision),
                                     "consecutiveRefreshFailures": consecutiveRefreshFailures,
                                     "eventDriven": true,
                                     "subscriptionRunning": subscriptionProcess?.isRunning == true,
                                     "subscriptionFailureCount": subscriptionFailureCount,
                                     "monitoringEnabled": monitoringEnabled,
                                     "recoveryIntervalSeconds": 60,
                                     "focusedWorkspace": focusedWorkspace,
                                     "currentWorkspaceIsGrouped": Self.managedWorkspaces.contains(focusedWorkspace),
                                     "policy": "all-managed-workspaces-including-current",
                                     "managedWorkspaces": workspaceData]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AltTab Reborn")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("AeroSpaceWorkspaceCards.json"), options: .atomic)
    }
}
