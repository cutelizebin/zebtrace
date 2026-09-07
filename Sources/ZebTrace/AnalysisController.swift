import AppKit
import ZebTraceAnalysis
import ZebTraceCore

/// Owns one analysis/download task. Recording always takes priority over this work.
@MainActor
final class AnalysisController {
    enum Phase { case idle, downloading, analyzing, cancelling }
    enum CancellationReason { case user, recording, sleep, shutdown }

    private(set) var phase: Phase = .idle
    private(set) var latestSessionDirectory: URL?
    private(set) var latestResult: AnalysisResult?
    private(set) var latestResultIsTranscriptOnly = false
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onResult: (() -> Void)?
    var canAnalyze: (() -> Bool)?

    private var models = LocalModelStore()
    private(set) var currentSessionDirectory: URL?
    private(set) var isRelocating = false
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var downloadProgress: ModelDownloadProgress?
    private var analysisProgress: AnalysisProgress?
    private var cancellationReason: CancellationReason?
    private var statusKey: String?
    private var failureDetail: String?
    private var shuttingDown = false
    private var sessionLookup: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let path = defaults.string(forKey: "analysis.latestSessionPath") {
            latestSessionDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let path = defaults.string(forKey: "analysis.latestResultPath") {
            latestResult = AnalysisResult(directory: URL(fileURLWithPath: path, isDirectory: true))
            latestResultIsTranscriptOnly = defaults.bool(forKey: "analysis.latestResultIsTranscriptOnly")
        }
    }

    var isBusy: Bool { task != nil || isRelocating }
    var canCancel: Bool { task != nil && phase != .cancelling }
    var runtimeActive: Bool { task != nil && (phase == .analyzing || phase == .cancelling) }
    var modelDirectory: URL { models.directory }
    var fraction: Double? {
        if let value = downloadProgress, value.totalBytes > 0 { return Double(value.downloadedBytes) / Double(value.totalBytes) }
        if let value = analysisProgress, value.total > 0 { return Double(value.completed) / Double(value.total) }
        return nil
    }
    func modelStatuses() -> [LocalModelStatus] { (try? models.statuses()) ?? [] }

    /// A catalog filename is the durable identity. Unknown saved selections
    /// fall back to the catalog default instead of becoming arbitrary paths.
    var selectedASRFilename: String {
        let choices = models.descriptors.filter { $0.role == "asr" }
        let saved = defaults.string(forKey: "analysis.asrModelFilename")
        return choices.first { $0.filename == saved }?.filename ?? choices.first?.filename ?? ""
    }

    func selectASRModel(filename: String) {
        guard !shuttingDown, !isBusy, canAnalyze?() == true,
              models.descriptors.contains(where: { $0.role == "asr" && $0.filename == filename }),
              filename != selectedASRFilename else { return }
        defaults.set(filename, forKey: "analysis.asrModelFilename")
        statusKey = nil
        failureDetail = nil
        // Selection changes only future work. Downloading and regenerating
        // remain explicit, and saved transcripts/results stay untouched.
        onChange?()
    }

    func relocateModels(to root: URL, from source: URL? = nil) async throws {
        guard !isBusy else { throw AnalysisFailure(L10n.string("storage.error.busy")) }
        isRelocating = true
        onChange?()
        defer { isRelocating = false; onChange?() }
        let destination = LocalModelStore(directory: root.appendingPathComponent("Models", isDirectory: true))
        let origin = source ?? models.directory
        let result = try await Task.detached(priority: .utility) {
            try destination.migrateModels(from: origin)
        }.value
        models = destination
        if !result.retained.isEmpty {
            onError?(L10n.string("storage.migration.retained", origin.path))
        }
    }

    func prepareModels() {
        guard !shuttingDown, !isBusy, canAnalyze?() == true, runtimeIsAvailable(manually: true) else { return }
        begin(sessionDirectory: nil, manually: true)
    }

    func deleteModels(filename: String? = nil) throws {
        guard !isBusy else { throw AnalysisFailure(L10n.string("storage.error.busy")) }
        if let filename { try models.removeModel(filename: filename) }
        else { try models.removeModels() }
        // Removing an unused alternative must not disable a ready pipeline.
        if !modelsReady { automaticEnabled = false }
        statusKey = nil; failureDetail = nil
        onChange?()
    }

    func forget(_ directory: URL) {
        if latestSessionDirectory?.standardizedFileURL == directory.standardizedFileURL {
            latestSessionDirectory = nil; defaults.removeObject(forKey: "analysis.latestSessionPath")
        }
        if latestResult?.directory.standardizedFileURL == directory.standardizedFileURL {
            latestResult = nil; latestResultIsTranscriptOnly = false
            defaults.removeObject(forKey: "analysis.latestResultPath")
            defaults.removeObject(forKey: "analysis.latestResultIsTranscriptOnly")
        }
        onChange?()
    }
    var modelsReady: Bool { models.isReady(asrFilename: selectedASRFilename) }
    var menuTitle: String {
        let stage: String
        switch phase {
        case .downloading: stage = L10n.string("analysis.menu.downloading")
        case .analyzing: stage = L10n.string("analysis.stage." + (analysisProgress?.stage ?? .preparing).rawValue)
        case .cancelling: stage = L10n.string("analysis.status.cancelling")
        case .idle:
            guard statusKey == "analysis.status.completed" else { return L10n.string("analysis.menu.title") }
            stage = L10n.string("analysis.menu.completed")
        }
        return L10n.string("analysis.menu.state", stage)
    }
    var automaticEnabled: Bool {
        get { defaults.bool(forKey: "analysis.automaticallySummarize") }
        set {
            defaults.set(newValue, forKey: "analysis.automaticallySummarize")
            onChange?()
        }
    }

    var statusText: String {
        if isRelocating { return L10n.string("storage.migrating") }
        if phase == .cancelling { return L10n.string("analysis.status.cancelling") }
        if let downloadProgress, phase == .downloading {
            return L10n.string("analysis.status.downloading", downloadProgress.modelName,
                               Self.byteCount(downloadProgress.downloadedBytes),
                               Self.byteCount(downloadProgress.totalBytes))
        }
        if let analysisProgress, phase == .analyzing {
            let stage = L10n.string("analysis.stage." + analysisProgress.stage.rawValue)
            return L10n.string("analysis.status.progress", stage, analysisProgress.completed,
                               max(1, analysisProgress.total))
        }
        if let failureDetail { return L10n.string("analysis.status.failed", failureDetail) }
        if let statusKey { return L10n.string(statusKey) }
        return L10n.string(modelsReady ? "analysis.status.ready" : "analysis.status.setup")
    }

    func didSave(_ directory: URL) {
        latestSessionDirectory = directory
        defaults.set(directory.path, forKey: "analysis.latestSessionPath")
        onChange?()
        guard automaticEnabled, modelsReady else { return }
        start(sessionDirectory: directory, manually: false)
    }

    func restoreLatestSessionIfNeeded(in root: URL) {
        if let latestSessionDirectory,
           latestSessionDirectory.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
           Self.savedManifest(in: latestSessionDirectory) != nil { return }
        latestSessionDirectory = nil
        let lookup = UUID()
        sessionLookup = lookup
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) { Self.newestSavedSession(in: root) }.value
            guard let self, self.sessionLookup == lookup, self.latestSessionDirectory == nil,
                  !self.shuttingDown else { return }
            self.latestSessionDirectory = found
            if let found { self.defaults.set(found.path, forKey: "analysis.latestSessionPath") }
            self.onChange?()
        }
    }

    func start(sessionDirectory: URL, manually: Bool) {
        guard !shuttingDown, !isBusy, canAnalyze?() == true else { return }
        // Catch an accidentally selected date/root folder before asking for a model download.
        guard Self.savedManifest(in: sessionDirectory) != nil else {
            report(AnalysisFailure(L10n.string("analysis.error.session")), manually: manually)
            return
        }
        guard runtimeIsAvailable(manually: manually) else { return }
        if !modelsReady {
            guard manually, confirmDownload() else { return }
        }
        // A modal confirmation may have allowed recording, sleep, or quit to intervene.
        guard !shuttingDown, !isBusy, canAnalyze?() == true else { return }
        begin(sessionDirectory: sessionDirectory, manually: manually)
    }

    func cancel(reason: CancellationReason = .user) {
        guard let task else { return }
        cancellationReason = reason
        phase = .cancelling
        onChange?()
        task.cancel()
    }

    func stopForRecording() async {
        cancel(reason: .recording)
        let running = task
        await running?.value
    }

    func shutdown() async {
        shuttingDown = true
        cancel(reason: .shutdown)
        let running = task
        await running?.value
    }

    private var runtimeDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    private func runtimeIsAvailable(manually: Bool) -> Bool {
        let ready = ["whisper-cli", "llama-completion"].allSatisfy {
            FileManager.default.isExecutableFile(atPath: runtimeDirectory.appendingPathComponent($0).path)
        }
        if !ready {
            failureDetail = L10n.string("analysis.error.runtime")
            statusKey = nil
            onChange?()
            if manually { onError?(failureDetail!) }
        }
        return ready
    }

    private func confirmDownload(allowRemoval: Bool = false) -> Bool {
        let required: [LocalModelDescriptor]
        do { required = try models.requiredDescriptors(asrFilename: selectedASRFilename) }
        catch { report(error, manually: true); return false }
        let hasFiles = ((try? FileManager.default.contentsOfDirectory(atPath: models.directory.path)) ?? []).isEmpty == false
        let canRemove = allowRemoval && hasFiles
        let alert = NSAlert()
        alert.messageText = L10n.string("analysis.models.title")
        alert.informativeText = L10n.string("analysis.models.downloadDescription",
                                          required.map(\.name).joined(separator: " + "),
                                          Self.byteCount(required.reduce(0) { $0 + $1.bytes }), modelFolderDisplay)
        alert.addButton(withTitle: L10n.string("analysis.models.download"))
        if canRemove { alert.addButton(withTitle: L10n.string("analysis.models.remove")) }
        alert.addButton(withTitle: L10n.string("alert.cancel"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        guard !shuttingDown, !isBusy, canAnalyze?() == true else { return false }
        if canRemove, choice == .alertSecondButtonReturn { removeModels() }
        return choice == .alertFirstButtonReturn
    }

    private func removeModels() {
        do {
            try models.removeModels()
            automaticEnabled = false
            statusKey = nil
            failureDetail = nil
            onChange?()
        } catch { report(error, manually: true) }
    }

    private func begin(sessionDirectory: URL?, manually: Bool) {
        let asrFilename = selectedASRFilename
        let current = UUID()
        generation = current
        cancellationReason = nil
        failureDetail = nil
        downloadProgress = nil
        analysisProgress = nil
        phase = modelsReady ? .analyzing : .downloading
        statusKey = phase == .downloading ? "analysis.status.downloadingModels" : "analysis.stage.preparing"
        let language = LanguagePreferences().resolvedLanguage().rawValue
        currentSessionDirectory = sessionDirectory
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let files = try await self.models.prepare(asrFilename: asrFilename) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == current, self.phase == .downloading else { return }
                        self.downloadProgress = progress
                        self.onChange?()
                    }
                }
                try Task.checkCancellation()
                if let sessionDirectory {
                    guard self.canAnalyze?() == true else { throw CancellationError() }
                    self.phase = .analyzing
                    self.analysisProgress = AnalysisProgress(stage: .preparing)
                    self.onChange?()
                    let configuration = AnalysisConfiguration(runtimeDirectory: self.runtimeDirectory,
                                                              asrModelURL: files.asr,
                                                              summaryModelURL: files.summary,
                                                              language: language)
                    let result = try await SessionAnalysisService().analyze(
                        sessionDirectory: sessionDirectory, configuration: configuration
                    ) { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.generation == current, self.phase != .cancelling else { return }
                            self.analysisProgress = progress
                            self.onChange?()
                        }
                    }
                    try Task.checkCancellation()
                    self.publish(result, transcriptOnly: false)
                    self.statusKey = "analysis.status.completed"
                    if manually, !self.shuttingDown { self.onResult?() }
                } else {
                    self.statusKey = "analysis.status.ready"
                }
            } catch {
                if let sessionDirectory {
                    let result = AnalysisResult(directory: sessionDirectory)
                    if let recording = try? RecordingLibrary.recording(at: sessionDirectory),
                       recording.resultStatus == .transcriptOnly || recording.resultStatus == .ready {
                        // This can be from an earlier attempt; label it as saved text,
                        // without suggesting that this attempt produced a summary.
                        self.publish(result, transcriptOnly: true)
                    }
                }
                if Task.isCancelled || error is CancellationError {
                    self.statusKey = self.cancellationReason == .recording
                        ? "analysis.status.recordingDeferred" : "analysis.status.cancelled"
                } else {
                    self.report(error, manually: manually)
                }
            }
            guard self.generation == current else { return }
            // Do not permit another job until the service has reaped its helper.
            self.task = nil
            self.generation = nil
            self.phase = .idle
            self.currentSessionDirectory = nil
            self.downloadProgress = nil
            self.analysisProgress = nil
            self.onChange?()
        }
        onChange?()
    }

    private func publish(_ result: AnalysisResult, transcriptOnly: Bool) {
        latestResult = result
        latestResultIsTranscriptOnly = transcriptOnly
        defaults.set(result.directory.path, forKey: "analysis.latestResultPath")
        defaults.set(transcriptOnly, forKey: "analysis.latestResultIsTranscriptOnly")
    }

    private nonisolated static func savedManifest(in directory: URL) -> SessionManifest? {
        let file = directory.appendingPathComponent("session.json")
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(SessionManifest.self, from: data),
              manifest.schemaVersion == 1, manifest.status == .completed, manifest.endedAt != nil else { return nil }
        return manifest
    }

    private nonisolated static func newestSavedSession(in root: URL) -> URL? {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let days = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles]) else { return nil }
        var newest: (directory: URL, startedAt: Date)?
        for day in days {
            guard day.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  let values = try? day.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let sessions = try? manager.contentsOfDirectory(at: day, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles]) else { continue }
            for session in sessions {
                guard let values = try? session.resourceValues(forKeys: Set(keys)),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      let manifest = savedManifest(in: session) else { continue }
                let name = session.lastPathComponent
                let newLayout = manifest.directoryName == name && name.hasPrefix(day.lastPathComponent + "_")
                let legacyLayout = name.count == 45 && name.lowercased().hasSuffix("-" + manifest.id.uuidString.lowercased())
                guard newLayout || legacyLayout else { continue }
                if newest == nil || manifest.startedAt > newest!.startedAt {
                    newest = (session, manifest.startedAt)
                }
            }
        }
        return newest?.directory
    }

    private var modelFolderDisplay: String {
        (models.directory.path as NSString).abbreviatingWithTildeInPath
    }

    private func report(_ error: Error, manually: Bool) {
        failureDetail = error.localizedDescription
        statusKey = nil
        onChange?()
        if manually, !shuttingDown { onError?(L10n.string("analysis.status.failed", error.localizedDescription)) }
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
