import AppKit
import ZebTraceCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recordingLocation = RecordingLocation()
    private let preferences = RecordingPreferences()
    private let languagePreferences = LanguagePreferences()
    private lazy var controller = RecordingController(recordingLocation: recordingLocation, preferences: preferences)
    private var statusItem: NSStatusItem?
    private let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let system = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let microphone = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "", action: #selector(toggleRecording), keyEquivalent: "r")
    private let latest = NSMenuItem(title: "", action: #selector(openLatest), keyEquivalent: "")
    private let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let location = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let chooseLocation = NSMenuItem(title: "", action: #selector(selectRecordingLocation), keyEquivalent: "")
    private let segmentLength = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let folder = NSMenuItem(title: "", action: #selector(openRecordings), keyEquivalent: "o")
    private let permissions = NSMenuItem(title: "", action: #selector(openPermissions), keyEquivalent: "")
    private let quit = NSMenuItem(title: "", action: #selector(quitApp), keyEquivalent: "q")
    private let languageMenu = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var languageChoices: [AppLanguage: NSMenuItem] = [:]
    private var localeObserver: NSObjectProtocol?
    private var segmentChoices: [RecordingSegmentLength: NSMenuItem] = [:]
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var instanceLock: SingleInstanceLock?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { instanceLock = try SingleInstanceLock() }
        catch {
            showError(L10n.string("app.error.launch", error.localizedDescription),
                      terminateAfterDismissal: true)
            return
        }
        LegacyPreferencesMigration.migrateFromLegacyDomain()
        NSApplication.shared.setActivationPolicy(.accessory)
        configureMenu()
        observeRecording()
        do { try SessionWriter.recoverInterruptedSessions(at: recordingLocation.directory) }
        catch { showError(L10n.string("app.error.recovery", error.localizedDescription)) }
        refresh()
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        [status, system, microphone, detail, location].forEach { $0.isEnabled = false }
        menu.addItem(status)
        menu.addItem(system)
        menu.addItem(microphone)
        menu.addItem(detail)
        menu.addItem(.separator())
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        latest.target = self
        menu.addItem(latest)
        folder.target = self
        menu.addItem(folder)
        menu.addItem(location)
        chooseLocation.target = self
        menu.addItem(chooseLocation)
        let lengths = NSMenu()
        lengths.autoenablesItems = false
        for length in RecordingSegmentLength.allCases {
            let item = NSMenuItem(title: length.title, action: #selector(selectSegmentLength(_:)), keyEquivalent: "")
            item.tag = length.rawValue
            item.target = self
            lengths.addItem(item)
            segmentChoices[length] = item
        }
        segmentLength.submenu = lengths
        menu.addItem(segmentLength)
        let languages = NSMenu()
        languages.autoenablesItems = false
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: "", action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            languages.addItem(item)
            languageChoices[language] = item
        }
        languageMenu.submenu = languages
        menu.addItem(languageMenu)
        permissions.target = self
        menu.addItem(permissions)
        menu.addItem(.separator())
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    private func observeRecording() {
        controller.onChange = { [weak self] in self?.refresh() }
        controller.onError = { [weak self] message in self?.showError(message) }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controller.tick() }
        }
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.controller.stop(reason: "systemSleep") }
        }
    }

    private func refresh() {
        latest.title = L10n.string("menu.latest")
        folder.title = L10n.string("menu.recordings")
        chooseLocation.title = L10n.string("menu.chooseLocation")
        permissions.title = L10n.string("menu.permissions")
        quit.title = L10n.string("menu.quit")
        languageMenu.title = L10n.string("menu.language")
        for (language, item) in languageChoices {
            let key: String
            switch language {
            case .system: key = "language.system"
            case .english: key = "language.english"
            case .chinese: key = "language.chinese"
            }
            item.title = L10n.string(key)
            item.state = language == languagePreferences.selection ? .on : .off
        }
        let iconState: StatusIcon.State
        switch controller.phase {
        case .idle:
            status.title = L10n.string(controller.lastDirectory == nil ? "status.idle" : "status.saved")
            toggle.title = L10n.string("menu.start")
            iconState = .idle
        case .starting:
            status.title = L10n.string("status.starting")
            toggle.title = L10n.string("menu.cancel")
            iconState = .busy
        case .recording:
            let elapsed = max(0, Int(Date().timeIntervalSince(controller.startedAt ?? Date())))
            let duration = String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
            status.title = L10n.string("status.recording", duration)
            toggle.title = L10n.string("menu.pause")
            iconState = .recording
        case .stopping:
            status.title = L10n.string("status.saving")
            toggle.title = L10n.string("menu.saving")
            iconState = .busy
        case .failed:
            status.title = L10n.string("status.failed")
            toggle.title = L10n.string("menu.retry")
            iconState = .failed
        }
        toggle.isEnabled = controller.phase != .stopping
        chooseLocation.isEnabled = controller.canStartRecording
        segmentLength.isEnabled = chooseLocation.isEnabled
        segmentLength.title = L10n.string("menu.segmentLength", preferences.segmentLength.title)
        for (length, item) in segmentChoices {
            item.title = length.title
            item.isEnabled = chooseLocation.isEnabled
            item.state = length == preferences.segmentLength ? .on : .off
        }
        let path = (recordingLocation.directory.path as NSString).abbreviatingWithTildeInPath
        let displayPath = path.count > 48 ? String(path.prefix(20)) + "…" + String(path.suffix(25)) : path
        location.title = L10n.string("menu.location", displayPath)
        location.toolTip = recordingLocation.directory.path
        latest.isEnabled = controller.lastDirectory != nil && controller.phase != .stopping
        let capturing = controller.phase == .recording
        system.title = sourceTitle(.system, name: L10n.string("source.system"), capturing: capturing)
        microphone.title = sourceTitle(.microphone, name: L10n.string("source.microphone"), capturing: capturing)
        detail.isHidden = controller.lastError == nil
        detail.title = controller.lastError.map { String($0.prefix(60)) } ?? ""
        detail.toolTip = controller.lastError
        statusItem?.button?.image = StatusIcon.image(for: iconState)
        statusItem?.button?.toolTip = status.title
        statusItem?.button?.setAccessibilityLabel(status.title)
    }

    private func sourceTitle(_ source: AudioSource, name: String, capturing: Bool) -> String {
        let state: String
        if !capturing {
            state = "source.inactive"
        } else if let activity = controller.activity[source], activity.buffers > 0,
                  let receivedAt = activity.lastReceivedAt, Date().timeIntervalSince(receivedAt) < 3 {
            state = activity.peak > 0.003 ? "source.active" : "source.silent"
        } else {
            state = "source.waiting"
        }
        return L10n.string("source.status", name, L10n.string(state))
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let language = AppLanguage(rawValue: value) else { return }
        languagePreferences.selection = language
        refresh()
    }

    @objc private func toggleRecording() {
        switch controller.phase {
        case .idle, .failed: controller.start()
        case .starting, .recording: controller.stop()
        case .stopping: break
        }
    }

    @objc private func openRecordings() {
        do {
            let directory = recordingLocation.directory
            if !FileManager.default.fileExists(atPath: directory.path) {
                if recordingLocation.hasCustomDirectory {
                    showError(L10n.string("app.error.folderUnavailable"))
                    return
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            NSWorkspace.shared.open(directory)
        } catch { showError(error.localizedDescription) }
    }

    @objc private func selectRecordingLocation() {
        guard controller.canStartRecording else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.string("folder.title")
        panel.message = L10n.string("folder.message")
        panel.prompt = L10n.string("folder.confirm")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let directory = recordingLocation.directory
        panel.directoryURL = FileManager.default.fileExists(atPath: directory.path)
            ? directory : directory.deletingLastPathComponent()
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let selection = panel.url,
              controller.canStartRecording else { return }
        do {
            try recordingLocation.select(selection)
            refresh()
            try SessionWriter.recoverInterruptedSessions(at: recordingLocation.directory)
        } catch { showError(error.localizedDescription) }
    }

    @objc private func selectSegmentLength(_ sender: NSMenuItem) {
        guard controller.canStartRecording,
              let length = RecordingSegmentLength(rawValue: sender.tag) else { return }
        preferences.segmentLength = length
        refresh()
    }

    @objc private func openLatest() {
        if let directory = controller.lastDirectory { NSWorkspace.shared.open(directory) }
    }

    @objc private func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        switch controller.phase {
        case .idle, .failed: return .terminateNow
        case .starting, .recording, .stopping:
            terminationPending = true
            controller.stop(reason: "appQuit") {
                DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    private func showError(_ message: String, terminateAfterDismissal: Bool = false) {
        // A failure is visible in the menu as well as here; ordinary operation has no window.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminationPending else { return }
            let alert = NSAlert()
            alert.messageText = "ZebTrace"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.string("alert.ok"))
            alert.runModal()
            if terminateAfterDismissal { NSApplication.shared.terminate(nil) }
        }
    }
}
