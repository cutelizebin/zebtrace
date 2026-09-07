import AppKit
import ZebTraceCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recordingLocation = RecordingLocation()
    private let preferences = RecordingPreferences()
    private let languagePreferences = LanguagePreferences()
    private lazy var controller = RecordingController(recordingLocation: recordingLocation, preferences: preferences)
    private lazy var analysis = AnalysisController()
    private lazy var workspace = WorkspaceController(analysis: analysis, location: recordingLocation,
        toggleRecording: { [weak self] in self?.toggleRecording() },
        chooseFolder: { [weak self] in self?.selectRecordingLocation() },
        showError: { [weak self] message in self?.showError(message) })
    private let mainWindowItem = NSMenuItem(title: "", action: #selector(openMainWindow), keyEquivalent: "0")
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStartPending = false
    private var sleeping = false
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
    private let analysisStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let analysisMenu = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let summarizeLatest = NSMenuItem(title: "", action: #selector(summarizeLatestRecording), keyEquivalent: "")
    private let summarizeOther = NSMenuItem(title: "", action: #selector(summarizeOtherRecording), keyEquivalent: "")
    private let cancelAnalysis = NSMenuItem(title: "", action: #selector(cancelAnalysisTask), keyEquivalent: "")
    private let viewResult = NSMenuItem(title: "", action: #selector(viewLatestResult), keyEquivalent: "")
    private let automaticSummary = NSMenuItem(title: "", action: #selector(toggleAutomaticSummary), keyEquivalent: "")
    private let manageModels = NSMenuItem(title: "", action: #selector(manageAnalysisModels), keyEquivalent: "")
    private var languageChoices: [AppLanguage: NSMenuItem] = [:]
    private var localeObserver: NSObjectProtocol?
    private var segmentChoices: [RecordingSegmentLength: NSMenuItem] = [:]
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
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
        analysis.restoreLatestSessionIfNeeded(in: recordingLocation.directory)
        workspace.onChange = { [weak self] in self?.refresh() }
        workspace.onUninstall = { [weak self] in self?.instanceLock?.prepareForUninstall() }
        workspace.migrateLegacyModels()
        refresh()
        if CommandLine.arguments.contains("--open-library") { openMainWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow(); return true
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        [status, system, microphone, detail, location, analysisStatus].forEach { $0.isEnabled = false }
        mainWindowItem.target = self
        menu.addItem(mainWindowItem)
        menu.addItem(.separator())
        menu.addItem(status)
        menu.addItem(system)
        menu.addItem(microphone)
        menu.addItem(detail)
        menu.addItem(.separator())
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let analysisItems = NSMenu()
        analysisItems.autoenablesItems = false
        analysisItems.addItem(analysisStatus)
        analysisItems.addItem(.separator())
        [summarizeLatest, summarizeOther, cancelAnalysis, viewResult, automaticSummary, manageModels].forEach {
            $0.target = self
            analysisItems.addItem($0)
        }
        analysisMenu.submenu = analysisItems
        menu.addItem(analysisMenu)
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
        controller.onSaved = { [weak self] directory in
            guard let self, !self.terminationPending, !self.sleeping else { return }
            self.analysis.didSave(directory)
        }
        analysis.onChange = { [weak self] in self?.refresh() }
        analysis.onError = { [weak self] message in self?.showError(message) }
        analysis.onResult = { [weak self] in self?.viewLatestResult() }
        analysis.canAnalyze = { [weak self] in
            guard let self else { return false }
            return self.controller.canStartRecording && !self.recordingStartPending &&
                !self.terminationPending && !self.sleeping && !self.workspace.isBusy
        }
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
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.recordingStartTask?.cancel()
                self.analysis.cancel(reason: .sleep)
                self.controller.stop(reason: "systemSleep")
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = false
                self?.refresh()
            }
        }
    }

    private func refresh() {
        mainWindowItem.title = L10n.string("workspace.open")
        latest.title = L10n.string("menu.latest")
        folder.title = L10n.string("menu.recordings")
        chooseLocation.title = L10n.string("menu.chooseLocation")
        permissions.title = L10n.string("menu.permissions")
        quit.title = L10n.string("menu.quit")
        languageMenu.title = L10n.string("menu.language")
        for (language, item) in languageChoices {
            item.title = L10n.string(language.titleKey)
            item.state = language == languagePreferences.selection ? .on : .off
        }
        var iconState: StatusIcon.State
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
        if controller.canStartRecording, analysis.isBusy || recordingStartPending { iconState = .busy }
        if recordingStartPending { toggle.title = L10n.string("analysis.menu.startingRecording") }
        toggle.isEnabled = controller.phase != .stopping && !recordingStartPending && !terminationPending && !sleeping && !workspace.isBusy
        chooseLocation.isEnabled = !analysis.isBusy && controller.canStartRecording && !recordingStartPending && !terminationPending && !sleeping && !workspace.isBusy
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
        refreshAnalysisMenu()
        statusItem?.button?.image = StatusIcon.image(for: iconState)
        statusItem?.button?.toolTip = status.title
        statusItem?.button?.setAccessibilityLabel(status.title)
    }

    private func refreshAnalysisMenu() {
        let available = controller.canStartRecording && !recordingStartPending && !terminationPending && !sleeping && !workspace.isBusy
        analysisMenu.title = analysis.menuTitle
        analysisStatus.title = String(analysis.statusText.prefix(80))
        analysisStatus.toolTip = analysis.statusText
        summarizeLatest.title = L10n.string("analysis.menu.latest")
        summarizeLatest.isEnabled = available && !analysis.isBusy && analysis.latestSessionDirectory != nil
        summarizeOther.title = L10n.string("analysis.menu.other")
        summarizeOther.isEnabled = available && !analysis.isBusy
        cancelAnalysis.title = L10n.string("analysis.menu.cancel")
        cancelAnalysis.isHidden = !analysis.isBusy
        cancelAnalysis.isEnabled = analysis.isBusy && analysis.phase != .cancelling && !terminationPending
        viewResult.title = L10n.string("workspace.viewRecording")
        viewResult.isEnabled = (analysis.currentSessionDirectory ?? analysis.latestSessionDirectory ?? analysis.latestResult?.directory) != nil && !terminationPending
        automaticSummary.title = L10n.string("analysis.menu.automatic")
        automaticSummary.state = analysis.automaticEnabled ? .on : .off
        automaticSummary.isEnabled = available && analysis.modelsReady && !analysis.isBusy
        automaticSummary.toolTip = L10n.string("analysis.menu.automaticHint")
        manageModels.title = L10n.string("analysis.menu.models")
        manageModels.isEnabled = !terminationPending
        workspace.refresh(state: LibraryLiveState(
            recordingDirectory: controller.phase == .recording || controller.phase == .starting ? controller.lastDirectory : nil,
            recordingTitle: toggle.title, recordingDetail: status.title,
            isRecording: controller.phase == .recording || controller.phase == .starting || controller.phase == .stopping,
            canToggleRecording: toggle.isEnabled, canAnalyze: available))
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
        case .idle, .failed:
            guard !recordingStartPending, !terminationPending, !sleeping, !workspace.isBusy else { return }
            guard analysis.isBusy else { controller.start(); return }
            recordingStartPending = true
            refresh()
            recordingStartTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.analysis.stopForRecording()
                self.recordingStartPending = false
                self.recordingStartTask = nil
                guard !Task.isCancelled, !self.terminationPending, !self.sleeping else {
                    self.refresh()
                    return
                }
                self.controller.start()
            }
        case .starting, .recording: controller.stop()
        case .stopping: break
        }
    }

    @objc private func summarizeLatestRecording() {
        guard let directory = analysis.latestSessionDirectory else { return }
        analysis.start(sessionDirectory: directory, manually: true)
    }

    @objc private func summarizeOtherRecording() {
        guard controller.canStartRecording, !analysis.isBusy, !recordingStartPending else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.string("analysis.folder.title")
        panel.message = L10n.string("analysis.folder.message")
        panel.prompt = L10n.string("analysis.folder.confirm")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = recordingLocation.directory
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let selection = panel.url else { return }
        analysis.start(sessionDirectory: selection, manually: true)
    }

    @objc private func cancelAnalysisTask() { analysis.cancel() }

    @objc private func toggleAutomaticSummary() {
        guard analysis.modelsReady, !analysis.isBusy, controller.canStartRecording else { return }
        analysis.automaticEnabled.toggle()
    }

    @objc private func manageAnalysisModels() { workspace.openModels() }

    @objc private func openMainWindow() { workspace.openLibrary() }

    @objc private func viewLatestResult() {
        workspace.openLibrary(selected: analysis.currentSessionDirectory ?? analysis.latestSessionDirectory ?? analysis.latestResult?.directory)
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
        guard controller.canStartRecording, !analysis.isBusy, !workspace.isBusy else { return }
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
        workspace.changeLocation(to: selection)
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
        if controller.canStartRecording && !analysis.isBusy && !recordingStartPending && !workspace.isBusy { return .terminateNow }
        terminationPending = true
        recordingStartTask?.cancel()
        refresh()
        Task { @MainActor in
            // Finalize audio and stop/reap helpers before allowing the app to exit.
            async let stoppedAnalysis: Void = analysis.shutdown()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                controller.stop(reason: "appQuit") {
                    continuation.resume()
                }
            }
            await stoppedAnalysis
            await workspace.waitForStorage()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        instanceLock?.prepareForUninstall()
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
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
