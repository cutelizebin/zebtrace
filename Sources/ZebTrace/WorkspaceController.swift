import AppKit
import ZebTraceAnalysis
import ZebTraceCore

/// Connects native management windows to capture/inference owners. Disk actions
/// are explicit user operations; opening a window never starts inference.
@MainActor
final class WorkspaceController {
    private let analysis: AnalysisController
    private let location: RecordingLocation
    private let toggleRecording: () -> Void
    private let chooseFolder: () -> Void
    private let showError: (String) -> Void
    var onChange: (() -> Void)?
    var onUninstall: (() -> Void)?
    private var library: RecordingLibraryWindowController?
    private var models: ModelManagementWindowController?
    private var storage: StorageManagementWindowController?
    private var state = LibraryLiveState()
    private var storageTask: Task<Void, Never>?
    private(set) var isBusy = false

    init(analysis: AnalysisController, location: RecordingLocation,
         toggleRecording: @escaping () -> Void, chooseFolder: @escaping () -> Void,
         showError: @escaping (String) -> Void) {
        self.analysis = analysis; self.location = location
        self.toggleRecording = toggleRecording; self.chooseFolder = chooseFolder; self.showError = showError
    }

    func refresh(state: LibraryLiveState) {
        var updated = state
        updated.analysisDirectory = analysis.currentSessionDirectory
        updated.analysisBusy = analysis.isBusy
        updated.analysisCanCancel = analysis.canCancel
        updated.analysisStatus = analysis.statusText
        updated.analysisFraction = analysis.fraction
        updated.automaticallySummarize = analysis.automaticEnabled
        updated.modelsReady = analysis.modelsReady
        updated.canAnalyze = state.canAnalyze && !isBusy
        self.state = updated
        library?.refresh(root: location.directory, state: updated)
        if let models { models.refresh(state: modelState()) }
    }

    func openLibrary(selected: URL? = nil) {
        if library == nil {
            library = RecordingLibraryWindowController(actions: LibraryActions(
                toggleRecording: { [weak self] in self?.toggleRecording() },
                analyze: { [weak self] url in self?.analysis.start(sessionDirectory: url, manually: true) },
                cancelAnalysis: { [weak self] in self?.analysis.cancel() },
                setAutomatic: { [weak self] enabled in
                    guard let self, self.state.canAnalyze, self.analysis.modelsReady, !self.analysis.isBusy else { return }
                    self.analysis.automaticEnabled = enabled
                },
                manageModels: { [weak self] in self?.openModels() },
                manageStorage: { [weak self] in self?.openStorage() },
                chooseFolder: { [weak self] in self?.chooseFolder() },
                deleteRecording: { [weak self] url in self?.removeRecording(url, generatedOnly: false) },
                deleteGeneratedContent: { [weak self] url in self?.removeRecording(url, generatedOnly: true) }
            ))
        }
        library?.refresh(root: location.directory, state: state)
        library?.present(root: location.directory, selectedSession: selected)
    }

    func openModels() {
        if models == nil {
            models = ModelManagementWindowController(actions: ModelManagementActions(
                prepare: { [weak self] in self?.analysis.prepareModels() },
                selectASRModel: { [weak self] filename in
                    guard let self, self.state.canAnalyze, !self.isBusy else { return }
                    self.analysis.selectASRModel(filename: filename)
                },
                cancelAndRelease: { [weak self] in self?.analysis.cancel() },
                removeModel: { [weak self] name in self?.removeModel(name) },
                removeAllModels: { [weak self] in self?.removeModel(nil) },
                openModelFolder: { [weak self] in
                    guard let self else { return }
                    do {
                        try FileManager.default.createDirectory(at: self.analysis.modelDirectory, withIntermediateDirectories: true,
                                                                attributes: [.posixPermissions: 0o700])
                        NSWorkspace.shared.open(self.analysis.modelDirectory)
                    } catch { self.showError(error.localizedDescription) }
                },
                manageStorage: { [weak self] in self?.openStorage() }
            ))
        }
        models?.present(state: modelState())
    }

    private func modelState() -> ModelManagementState {
        let items = analysis.modelStatuses().map { item in
            ModelManagementItem(id: item.descriptor.filename, name: item.descriptor.name,
                role: item.descriptor.role, downloadBytes: item.descriptor.bytes,
                installedBytes: item.installedBytes, isReady: item.isReady,
                license: item.descriptor.license, path: item.fileURL.path)
        }
        return ModelManagementState(models: items, isBusy: analysis.isBusy || isBusy, status: analysis.statusText,
            fraction: analysis.fraction, runtimeActive: analysis.runtimeActive,
            modelDirectoryPath: analysis.modelDirectory.path, canModifyModels: state.canAnalyze && !isBusy,
            canCancel: analysis.canCancel, selectedASRFilename: analysis.selectedASRFilename,
            selectedModelsReady: analysis.modelsReady)
    }

    private func removeModel(_ filename: String?) {
        guard state.canAnalyze, !analysis.isBusy, !isBusy else { return }
        let name = filename.flatMap { name in LocalModelStore.models.first { $0.filename == name }?.name }
            ?? L10n.string("storage.allModels")
        guard confirm("storage.deleteModels.title", message: L10n.string("storage.deleteModels.message", name),
                      button: "storage.delete") else { return }
        guard state.canAnalyze, !analysis.isBusy, !isBusy else { return }
        do { try analysis.deleteModels(filename: filename); onChange?(); storage?.reload() }
        catch { showError(error.localizedDescription) }
    }

    private func removeRecording(_ directory: URL, generatedOnly: Bool) {
        guard state.canAnalyze, !analysis.isBusy, !isBusy else { return }
        do {
            let recording = try RecordingLibrary.recording(at: directory)
            let root = directory.deletingLastPathComponent().deletingLastPathComponent()
            guard location.knownDirectories.contains(where: { $0.standardizedFileURL == root.standardizedFileURL }) else {
                throw AnalysisFailure(L10n.string("storage.error.outside"))
            }
            guard confirm(generatedOnly ? "storage.deleteGenerated.title" : "storage.deleteRecording.title",
                          message: L10n.string(generatedOnly ? "storage.deleteGenerated.message" : "storage.deleteRecording.message", directory.path),
                          button: "storage.trash") else { return }
            guard state.canAnalyze, !analysis.isBusy, !isBusy else { return }
            library?.stopPlayback()
            try ManagedStorage.withExclusiveAccess(recording: recording, root: root) { _ in
                let urls = try generatedOnly ? ManagedStorage.generatedURLsForTrash(recording: recording, root: root)
                    : [ManagedStorage.recordingURLForTrash(recording: recording, root: root)]
                for url in urls { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            }
            analysis.forget(directory)
            analysis.restoreLatestSessionIfNeeded(in: location.directory)
            library?.reload(); storage?.reload()
        } catch { showError(error.localizedDescription) }
    }

    func migrateLegacyModels() {
        guard !isBusy else { return }
        performStorage {
            _ = try self.location.prepareForRecording()
            try await self.analysis.relocateModels(to: self.location.directory, from: LocalModelStore.legacyDirectory)
            self.removeEmptyLegacyDirectories()
        }
    }

    func changeLocation(to directory: URL) {
        guard state.canAnalyze, !analysis.isBusy, !isBusy else { return }
        let old = location.directory
        guard old.standardizedFileURL != directory.standardizedFileURL else { return }
        // Preserve old recordings in their existing roots; only the shared model
        // folder moves. The storage page retains every selected root for cleanup.
        performStorage {
            try self.location.validateSelection(directory)
            try await self.analysis.relocateModels(to: directory)
            do { try self.location.select(directory) }
            catch {
                try? await self.analysis.relocateModels(to: old)
                throw error
            }
            try SessionWriter.recoverInterruptedSessions(at: directory)
            self.analysis.restoreLatestSessionIfNeeded(in: directory)
            self.library?.reload(); self.storage?.reload()
        }
    }

    private func performStorage(_ operation: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; onChange?()
        storageTask = Task { @MainActor in
            defer { self.isBusy = false; self.storageTask = nil; self.onChange?() }
            do { try await operation() }
            catch { self.showError(error.localizedDescription) }
        }
    }

    func waitForStorage() async { await storageTask?.value }

    func openStorage() {
        if storage == nil {
            storage = StorageManagementWindowController(location: location,
                chooseFolder: { [weak self] in self?.chooseFolder() },
                manageModels: { [weak self] in self?.openModels() },
                cleanup: { [weak self] uninstall, erase in self?.cleanup(uninstall: uninstall, eraseRecordings: erase) },
                languageChanged: { [weak self] in self?.onChange?() })
        }
        storage?.present()
    }

    private func cleanup(uninstall: Bool, eraseRecordings: Bool) {
        guard state.canAnalyze, !analysis.isBusy, !isBusy else {
            showError(L10n.string("storage.error.busy")); return
        }
        if uninstall {
            let bundle = Bundle.main
            guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier == "org.zebtrace.app",
                  FileManager.default.isExecutableFile(atPath: bundle.bundleURL.appendingPathComponent("Contents/MacOS/ZebTrace").path) else {
                showError(L10n.string("storage.error.notApp")); return
            }
        }
        let paths = location.knownDirectories.map(\.path).joined(separator: "\n")
        guard confirm(uninstall ? "storage.uninstall.title" : "storage.cleanup.title",
            message: L10n.string(eraseRecordings ? "storage.cleanup.eraseMessage" : "storage.cleanup.keepMessage", paths),
            button: uninstall ? "storage.uninstall.confirm" : "storage.cleanup.confirm") else { return }
        guard state.canAnalyze, !analysis.isBusy, !isBusy else { return }
        performStorage {
            self.library?.stopPlayback()
            // Validate everything before any destructive work, including extra files
            // that must not be silently removed from a user-selected directory.
            var inventories: [(URL, ManagedStorageInventory)] = []
            for root in self.location.knownDirectories {
                if !FileManager.default.fileExists(atPath: root.path) {
                    if eraseRecordings, root.path.hasPrefix("/Volumes/") {
                        throw AnalysisFailure(L10n.string("storage.error.unavailable", root.path))
                    }
                    continue
                }
                let inventory = try ManagedStorage.inventory(root: root)
                if eraseRecordings {
                    for recording in inventory.recordings { _ = try ManagedStorage.recordingURLForTrash(recording: recording, root: root) }
                }
                inventories.append((root, inventory))
            }
            for (root, inventory) in inventories {
                if eraseRecordings {
                    for recording in inventory.recordings {
                        try ManagedStorage.withExclusiveAccess(recording: recording, root: root) { _ in
                            let url = try ManagedStorage.recordingURLForTrash(recording: recording, root: root)
                            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        }
                    }
                }
                try LocalModelStore(directory: root.appendingPathComponent("Models")).removeModels()
                self.removeEmptyChildDirectories(root, recognizedDays: Set(inventory.recordings.map { $0.directory.deletingLastPathComponent().lastPathComponent }))
            }
            // Migration is idempotent; remove only known model files from legacy
            // storage, never unknown user files or unrelated Application Support.
            try LocalModelStore(directory: LocalModelStore.legacyDirectory).removeModels()
            self.removeEmptyLegacyDirectories()
            for name in ["org.zebtrace.app", LegacyPreferencesMigration.legacyBundleIdentifier] {
                for relative in ["Library/Caches/\(name)", "Library/Saved Application State/\(name).savedState"] {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative)
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                }
            }
            if uninstall {
                try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
            }
            UserDefaults.standard.removePersistentDomain(forName: "org.zebtrace.app")
            UserDefaults.standard.removePersistentDomain(forName: LegacyPreferencesMigration.legacyBundleIdentifier)
            UserDefaults.standard.synchronize()
            self.onUninstall?()
            NSApplication.shared.terminate(nil)
        }
    }

    private func removeEmptyChildDirectories(_ root: URL, recognizedDays: Set<String> = []) {
        let models = root.appendingPathComponent("Models")
        if let values = try? models.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           values.isDirectory == true, values.isSymbolicLink != true,
           let files = try? FileManager.default.contentsOfDirectory(at: models, includingPropertiesForKeys: nil),
           files.allSatisfy({ [".model-store.lock", ".DS_Store"].contains($0.lastPathComponent) }),
           let lease = try? LocalModelLease(directory: models, exclusive: true) {
            // All weights and resumable files are already gone; remove the empty
            // model folder while owning its coordination lock.
            try? FileManager.default.removeItem(at: models)
            lease.close()
        }
        for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [] {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  (child.lastPathComponent == "Models" || recognizedDays.contains(child.lastPathComponent)),
                  let contents = try? FileManager.default.contentsOfDirectory(atPath: child.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { continue }
            try? FileManager.default.removeItem(at: child)
        }
        if ["ZebTrace", "MyContext"].contains(root.lastPathComponent),
           let contents = try? FileManager.default.contentsOfDirectory(atPath: root.path),
           contents.allSatisfy({ $0 == ".DS_Store" }) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func removeEmptyLegacyDirectories() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in ["ZebTrace", "MyContext"] { removeEmptyChildDirectories(support.appendingPathComponent(name)) }
    }

    private func confirm(_ title: String, message: String, button: String) -> Bool {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = L10n.string(title); alert.informativeText = message
        alert.addButton(withTitle: L10n.string(button)); alert.addButton(withTitle: L10n.string("alert.cancel"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
