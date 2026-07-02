import Cocoa

class ShortcutsWhenActiveSheet: SheetWindow {
    private static let title = NSLocalizedString("Shortcuts When Active", comment: "")
    // Row titles come from `ControlsTab.staticShortcutLabels` (single source of truth, also used by
    // the conflict dialog to name these actions).
    private static let labelFocus = ControlsTab.staticShortcutLabels["focusWindowShortcut"]!
    private static let labelPrevious = ControlsTab.staticShortcutLabels["previousWindowShortcut"]!
    private static let labelCancel = ControlsTab.staticShortcutLabels["cancelShortcut"]!
    private static let labelSearch = ControlsTab.staticShortcutLabels["searchShortcut"]!
    private static let labelLockSearch = ControlsTab.staticShortcutLabels["lockSearchShortcut"]!
    private static let labelClose = ControlsTab.staticShortcutLabels["closeWindowShortcut"]!
    private static let labelMinDemin = ControlsTab.staticShortcutLabels["minDeminWindowShortcut"]!
    private static let labelFullscreen = ControlsTab.staticShortcutLabels["toggleFullscreenWindowShortcut"]!
    private static let labelQuit = ControlsTab.staticShortcutLabels["quitAppShortcut"]!
    private static let labelHideShow = ControlsTab.staticShortcutLabels["hideShowAppShortcut"]!

    /// Pre-build search index for the open-button. See `SettingsSearchIndex.sheetSearchableStrings`.
    static let searchableStrings: [String] = [
        title,
        labelFocus, labelPrevious, labelCancel,
        labelSearch, labelLockSearch,
        labelClose, labelMinDemin, labelFullscreen, labelQuit, labelHideShow,
    ]

    override func makeContentView() -> NSView {
        let focusWindowShortcut = TableGroupView.Row(leftTitle: Self.labelFocus,
            rightViews: [LabelAndControl.makeLabelWithRecorder(Self.labelFocus, "focusWindowShortcut", Preferences.focusWindowShortcut, labelPosition: .right)[0]])
        let previousWindowShortcut = TableGroupView.Row(leftTitle: Self.labelPrevious,
            rightViews: [LabelAndControl.makeLabelWithRecorder(Self.labelPrevious, "previousWindowShortcut", Preferences.previousWindowShortcut, labelPosition: .right)[0]])
        let cancelShortcut = TableGroupView.Row(leftTitle: Self.labelCancel,
            rightViews: [LabelAndControl.makeLabelWithRecorder(Self.labelCancel, "cancelShortcut", Preferences.cancelShortcut, labelPosition: .right)[0]])
        let closeWindowShortcut = TableGroupView.Row(leftTitle: Self.labelClose,
            rightViews: [LabelAndControl.makeLabelWithRecorder(Self.labelClose, "closeWindowShortcut", Preferences.closeWindowShortcut, labelPosition: .right)[0]])
        let minDeminWindowShortcut = TableGroupView.Row(leftTitle: Self.labelMinDemin,
            rightViews: [LabelAndControl.makeLabelWithRecorder(Self.labelMinDemin, "minDeminWindowShortcut", Preferences.minDeminWindowShortcut, labelPosition: .right)[0]])
        let toggleFullscreenWindowShortcut = TableGroupView.Row(leftTitle: Self.labelFullscreen,
            rightViews: [LabelAndControl.makeLabelWithRecorder(Self.labelFullscreen, "toggleFullscreenWindowShortcut", Preferences.toggleFullscreenWindowShortcut, labelPosition: .right)[0]])
        let quitAppShortcut = TableGroupView.Row(leftTitle: Self.labelQuit,
            rightViews: [LabelAndControl.makeLabelWithRecorder(Self.labelQuit, "quitAppShortcut", Preferences.quitAppShortcut, labelPosition: .right)[0]])
        let hideShowAppShortcut = TableGroupView.Row(leftTitle: Self.labelHideShow,
            rightViews: [LabelAndControl.makeLabelWithRecorder(Self.labelHideShow, "hideShowAppShortcut", Preferences.hideShowAppShortcut, labelPosition: .right)[0]])
        let table = TableGroupView(title: Self.title, width: SheetWindow.width)
        _ = table.addRow(focusWindowShortcut)
        _ = table.addRow(previousWindowShortcut)
        _ = table.addRow(cancelShortcut)
        _ = table.addRow(leftText: Self.labelSearch,
            rightViews: [LabelAndControl.makeLabelWithRecorder(Self.labelSearch, "searchShortcut", Preferences.searchShortcut, labelPosition: .right)[0]])
        _ = table.addRow(leftText: Self.labelLockSearch,
            rightViews: [LabelAndControl.makeLabelWithRecorder(Self.labelLockSearch, "lockSearchShortcut", Preferences.lockSearchShortcut, labelPosition: .right)[0]])
        _ = table.addRow(closeWindowShortcut)
        _ = table.addRow(minDeminWindowShortcut)
        _ = table.addRow(toggleFullscreenWindowShortcut)
        _ = table.addRow(quitAppShortcut)
        _ = table.addRow(hideShowAppShortcut)
        return table
    }
}
