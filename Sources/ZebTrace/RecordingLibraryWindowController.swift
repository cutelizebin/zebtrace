import AppKit
import Combine
import SwiftUI
import ZebTraceCore

@MainActor
struct LibraryActions {
    var toggleRecording: () -> Void = {}
    var analyze: (URL) -> Void = { _ in }
    var cancelAnalysis: () -> Void = {}
    var setAutomatic: (Bool) -> Void = { _ in }
    var manageModels: () -> Void = {}
    var manageStorage: () -> Void = {}
    var chooseFolder: () -> Void = {}
    var deleteRecording: (URL) -> Void = { _ in }
    var deleteGeneratedContent: (URL) -> Void = { _ in }
}

struct LibraryLiveState {
    var recordingDirectory: URL? = nil
    /// The recording button's action label, such as Start Recording or Pause and Save.
    var recordingTitle: String = ""
    var recordingDetail: String = ""
    var isRecording = false
    var canToggleRecording = true
    var analysisDirectory: URL? = nil
    var analysisBusy = false
    var analysisCanCancel = false
    var analysisStatus: String = ""
    var analysisFraction: Double? = nil
    var canAnalyze = true
    var automaticallySummarize = false
    var modelsReady = false
}

/// A single reusable library window. AppDelegate remains the owner of capture and inference.
/// AppKit owns the window chrome and sidebar; SwiftUI renders the recording content.
@MainActor
final class RecordingLibraryWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private enum ToolbarID {
        static let record = NSToolbarItem.Identifier("ZebTrace.Library.Record")
        static let divider = NSToolbarItem.Identifier("ZebTrace.Library.Divider")
        static let actions = NSToolbarItem.Identifier("ZebTrace.Library.Actions")
    }

    private let model: RecordingLibraryModel
    private let splitController = NSSplitViewController()
    private let recordButton = NSButton()
    private var recordItem: NSToolbarItem?
    private var recordButtonWidth: NSLayoutConstraint?
    private var actionsItem: NSToolbarItem?
    private var modelObservation: AnyCancellable?

    init(actions: LibraryActions) {
        model = RecordingLibraryModel(actions: actions)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 780, height: 520)
        window.isReleasedWhenClosed = false
        window.title = "ZebTrace"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self

        let sidebar = NSSplitViewItem(sidebarWithViewController:
            NSHostingController(rootView: RecordingLibrarySidebar(model: model)))
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 320
        sidebar.preferredThicknessFraction = 0.27
        sidebar.holdingPriority = .defaultHigh
        sidebar.canCollapse = true
        sidebar.canCollapseFromWindowResize = false
        sidebar.titlebarSeparatorStyle = .none

        let detail = NSSplitViewItem(viewController:
            NSHostingController(rootView: RecordingLibraryDetailView(model: model)))
        detail.minimumThickness = 450
        detail.titlebarSeparatorStyle = .none
        splitController.splitView.isVertical = true
        splitController.splitView.dividerStyle = .thin
        splitController.splitView.autosaveName = "ZebTrace.Library.Split"
        splitController.addSplitViewItem(sidebar)
        splitController.addSplitViewItem(detail)
        window.contentViewController = splitController

        let toolbar = NSToolbar(identifier: "ZebTrace.Library.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: 1000, height: 700))
        if !window.setFrameUsingName("ZebTrace.Library.Window") {
            window.center()
            splitController.view.layoutSubtreeIfNeeded()
            splitController.splitView.setPosition(270, ofDividerAt: 0)
        }
        window.setFrameAutosaveName("ZebTrace.Library.Window")

        // Published properties announce changes before their setters complete.
        // Deliver on the next main-loop turn so the native button reads the new state.
        modelObservation = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateToolbar() }
        updateToolbar()
    }

    required init?(coder: NSCoder) { return nil }

    func present(root: URL, selectedSession: URL? = nil) {
        let wasVisible = window?.isVisible == true
        model.present(root: root, selectedSession: selectedSession)
        updateToolbar()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !wasVisible {
            // Opening the library should emphasize the selection, not place a
            // bright editing ring around an otherwise idle search field.
            window?.makeFirstResponder(nil)
        }
    }

    func refresh(root: URL, state: LibraryLiveState) {
        model.refresh(root: root, state: state)
        updateToolbar()
    }

    func stopPlayback() { model.player.stop() }
    func reload() { model.reload() }

    func windowWillClose(_ notification: Notification) { model.dismiss() }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, ToolbarID.divider, ToolbarID.record, .flexibleSpace, ToolbarID.actions]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case ToolbarID.divider:
            return NSTrackingSeparatorToolbarItem(identifier: identifier,
                                                  splitView: splitController.splitView,
                                                  dividerIndex: 0)
        case ToolbarID.record:
            let item = NSToolbarItem(itemIdentifier: identifier)
            recordButton.bezelStyle = .texturedRounded
            recordButton.isBordered = false
            recordButton.imagePosition = .imageLeading
            recordButton.cell?.wraps = false
            recordButton.cell?.lineBreakMode = .byClipping
            recordButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            recordButton.keyEquivalent = "r"
            recordButton.keyEquivalentModifierMask = .command
            recordButtonWidth = recordButton.widthAnchor.constraint(equalToConstant: 76)
            recordButtonWidth?.isActive = true
            recordButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
            recordButton.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            recordButton.target = self
            recordButton.action = #selector(toggleRecording)
            item.view = recordButton
            item.autovalidates = false
            item.visibilityPriority = .high
            recordItem = item
            updateToolbar()
            return item
        case ToolbarID.actions:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let host = NSHostingView(rootView: RecordingLibraryActionsMenu(model: model)
                .frame(width: 32, height: 28))
            host.frame = NSRect(x: 0, y: 0, width: 32, height: 28)
            item.view = host
            item.autovalidates = false
            item.label = L10n.string("library.recording.actions")
            item.toolTip = item.label
            actionsItem = item
            return item
        default:
            return nil
        }
    }

    private func updateToolbar() {
        let label = L10n.string(model.live.isRecording ? "library.design.stop" : "library.design.record")
        let action = model.live.recordingTitle.isEmpty ? label : model.live.recordingTitle
        let symbol = model.live.isRecording ? "stop.fill" : "record.circle.fill"
        recordButton.title = label
        recordButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        recordButton.isEnabled = model.live.canToggleRecording
        recordButton.toolTip = [action, model.live.recordingDetail].filter { !$0.isEmpty }.joined(separator: " — ")
        recordButton.setAccessibilityLabel(action)
        // A toolbar may otherwise compress the image-and-title button to one
        // glyph wide, wrapping CJK labels vertically. Size the visible action
        // explicitly while allowing translations to use their natural width.
        let font = recordButton.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let width = max(76, ceil((label as NSString).size(withAttributes: [.font: font]).width) + 38)
        recordButtonWidth?.constant = width
        recordButton.setFrameSize(NSSize(width: width, height: 28))
        recordItem?.label = label
        recordItem?.toolTip = recordButton.toolTip
        recordItem?.isEnabled = model.live.canToggleRecording
        actionsItem?.label = L10n.string("library.recording.actions")
        actionsItem?.toolTip = actionsItem?.label
    }

    @objc private func toggleRecording() {
        guard model.live.canToggleRecording else { return }
        model.toggleRecording()
    }
}
