import AppKit
import SwiftUI
import ZebTraceAnalysis
import ZebTraceCore

@MainActor
final class RecordingLibraryModel: ObservableObject {
    @Published private(set) var sessions: [LibrarySession] = []
    @Published private(set) var selectedDirectory: URL?
    @Published private(set) var document: LibraryDocument?
    @Published private(set) var live = LibraryLiveState()
    @Published private(set) var root: URL?
    @Published private(set) var scanning = false
    @Published private(set) var loadingDetail = false
    @Published private(set) var scanError: String?
    @Published private(set) var detailError: String?
    @Published var query = ""
    @Published var readingTab: LibraryReadingTab = .summary
    @Published var audioExpanded = false
    let player = LibraryAudioPlayer()
    let actions: LibraryActions

    private var visible = false
    private var requiresScan = true
    private var scanGeneration = UUID()
    private var detailGeneration = UUID()
    private var scanWorker: Task<[LibraryRecording], Error>?
    private var detailWorker: Task<LibraryRecordingDetails, Error>?
    private var lastDetailLoad = Date.distantPast
    private var explicitExternalDirectory: URL?

    init(actions: LibraryActions) { self.actions = actions }

    var selectedSession: LibrarySession? {
        guard let selectedDirectory else { return nil }
        if let document, Self.same(document.session.directory, selectedDirectory) { return document.session }
        return sessions.first { Self.same($0.directory, selectedDirectory) }
    }

    var groups: [(day: Date, sessions: [LibrarySession])] {
        let filtered = sessions.filter { session in
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            let text = "\(LibraryText.date(session.startedAt, time: true)) \(LibraryText.searchDate(session.startedAt)) \(session.summaryPreview) \(status(for: session))"
            return text.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let grouped = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in (day, grouped[day] ?? []) }
    }

    var selectedIsProcessing: Bool { live.analysisBusy && Self.same(live.analysisDirectory, selectedDirectory) }
    var selectedIsRecording: Bool { live.isRecording && Self.same(live.recordingDirectory, selectedDirectory) }
    var canAnalyzeSelection: Bool {
        selectedSession?.recordingStatus == "completed" && live.canAnalyze && !live.analysisBusy && !live.isRecording
    }

    func present(root: URL, selectedSession: URL?) {
        let wasVisible = visible
        visible = true
        if !Self.same(self.root, root) {
            self.root = root
            sessions = []
            select(nil)
            requiresScan = true
        }
        if let selectedSession {
            if !Self.same(selectedSession.deletingLastPathComponent().deletingLastPathComponent(), root) {
                explicitExternalDirectory = selectedSession
            }
            select(selectedSession, force: true)
        }
        else if !wasVisible, selectedDirectory != nil { loadDetail(clear: true) }
        // Opening the library explicitly refreshes files modified while its window was closed.
        reload()
    }

    func refresh(root: URL, state: LibraryLiveState) {
        let old = live
        live = state
        let rootChanged = !Self.same(self.root, root)
        let taskChanged = old.analysisBusy != state.analysisBusy ||
            !Self.same(old.analysisDirectory, state.analysisDirectory) ||
            old.isRecording != state.isRecording || !Self.same(old.recordingDirectory, state.recordingDirectory)
        if rootChanged {
            self.root = root
            sessions = []
            select(nil)
        }
        if state.isRecording && !old.isRecording { player.stop() }
        if rootChanged || taskChanged { requiresScan = true }
        guard visible else { return }
        if requiresScan { reload() }
        else if selectedIsProcessing, old.analysisStatus != state.analysisStatus,
                Date().timeIntervalSince(lastDetailLoad) >= 2 {
            // Only reread the selected session while it progresses. Never rescan
            // the whole library for a timer tick or download byte update.
            loadDetail(clear: false)
        }
    }

    func dismiss() {
        visible = false
        scanGeneration = UUID()
        detailGeneration = UUID()
        scanWorker?.cancel()
        detailWorker?.cancel()
        scanning = false
        loadingDetail = false
        player.stop()
    }

    func reload() {
        requiresScan = true
        guard visible, let root else { return }
        requiresScan = false
        scanWorker?.cancel()
        let current = UUID()
        scanGeneration = current
        scanning = true
        scanError = nil
        let worker = Task.detached(priority: .utility) { try RecordingLibrary.scan(root: root) }
        scanWorker = worker
        Task { @MainActor [weak self] in
            do {
                let entries = try await worker.value
                guard let self, self.scanGeneration == current, Self.same(self.root, root), self.visible else { return }
                self.sessions = entries.map(LibrarySession.init)
                self.scanning = false
                if let selected = self.selectedDirectory,
                   self.sessions.contains(where: { Self.same($0.directory, selected) }) {
                    self.loadDetail(clear: false)
                } else if let selected = self.selectedDirectory,
                          Self.same(self.explicitExternalDirectory, selected) {
                    // A user-picked folder outside this root is intentionally
                    // absent from scans. Keep it only if it still validates.
                    self.loadDetail(clear: false, selectFallbackOnFailure: true)
                } else {
                    // Deleting the selected recording should reveal the next
                    // valid row instead of leaving a stale selection behind.
                    self.select(self.sessions.first?.directory)
                }
            } catch {
                guard let self, self.scanGeneration == current, self.visible else { return }
                self.scanning = false
                if !(error is CancellationError) { self.scanError = error.localizedDescription }
            }
        }
    }

    func select(_ directory: URL?, force: Bool = false) {
        guard force || !Self.same(directory, selectedDirectory) else { return }
        if !Self.same(directory, explicitExternalDirectory) {
            let validatedExternal = directory.map { candidate in
                !Self.same(candidate.deletingLastPathComponent().deletingLastPathComponent(), root) &&
                    sessions.contains(where: { Self.same($0.directory, candidate) })
            } ?? false
            explicitExternalDirectory = validatedExternal ? directory : nil
        }
        player.stop()
        detailWorker?.cancel()
        detailGeneration = UUID()
        selectedDirectory = directory
        document = nil
        detailError = nil
        readingTab = .summary
        audioExpanded = false
        loadingDetail = false
        if directory != nil { loadDetail(clear: true) }
    }

    private func loadDetail(clear: Bool, selectFallbackOnFailure: Bool = false) {
        guard visible, let directory = selectedDirectory else { return }
        detailWorker?.cancel()
        let current = UUID()
        detailGeneration = current
        lastDetailLoad = Date()
        let previous = document.flatMap { Self.same($0.session.directory, directory) ? $0.session.catalogRecording : nil }
        if clear { document = nil; loadingDetail = true }
        detailError = nil
        let known = sessions.first { Self.same($0.directory, directory) }?.catalogRecording ?? previous
        let worker = Task.detached(priority: .utility) {
            let recording = try known ?? RecordingLibrary.recording(at: directory)
            return try RecordingLibrary.loadDetails(recording: recording)
        }
        detailWorker = worker
        Task { @MainActor [weak self] in
            do {
                let details = try await worker.value
                guard let self, self.detailGeneration == current, self.visible,
                      Self.same(self.selectedDirectory, directory), Self.same(details.recording.directory, directory) else { return }
                if let known, details.recording.id != known.id { return }
                let document = LibraryDocument(details)
                self.document = document
                self.loadingDetail = false
                if let index = self.sessions.firstIndex(where: { Self.same($0.directory, directory) }) {
                    self.sessions[index] = document.session
                } else {
                    // Explicitly selected folders outside the current root are
                    // visible only after the catalog has validated their identity.
                    self.sessions.append(document.session)
                    self.sessions.sort { $0.startedAt > $1.startedAt }
                }
            } catch {
                guard let self, self.detailGeneration == current,
                      Self.same(self.selectedDirectory, directory), self.visible else { return }
                self.loadingDetail = false
                if !(error is CancellationError) {
                    self.document = nil
                    self.detailError = error.localizedDescription
                    self.player.stop()
                    if selectFallbackOnFailure {
                        self.select(self.sessions.first?.directory)
                    }
                }
            }
        }
    }

    func status(for session: LibrarySession) -> String {
        if live.isRecording && Self.same(live.recordingDirectory, session.directory) {
            return L10n.string("library.status.recording")
        }
        if live.analysisBusy && Self.same(live.analysisDirectory, session.directory) {
            return L10n.string("library.status.processing")
        }
        switch session.recordingStatus {
        case "recording": return L10n.string("library.status.recording")
        case "interrupted": return L10n.string("library.status.interrupted")
        case "failed": return L10n.string("library.status.failed")
        default: break
        }
        switch session.reviewState {
        case .none: return L10n.string("library.status.none")
        case .transcript: return L10n.string("library.status.transcript")
        case .complete: return L10n.string("library.status.ready")
        case .unavailable: return L10n.string("library.status.unavailable")
        }
    }

    func toggleRecording() { player.stop(); actions.toggleRecording() }
    func analyzeSelection() {
        guard let selectedDirectory, canAnalyzeSelection else { return }
        player.stop()
        actions.analyze(selectedDirectory)
    }

    func play(_ line: LibraryTranscriptLine) {
        guard !live.isRecording, let clip = document?.clips.first(where: {
            $0.playable && $0.source == line.source && line.start >= $0.startOffset - 0.1 &&
                line.start < $0.startOffset + $0.duration
        }) else { return }
        audioExpanded = true
        player.play(clip, atSessionTime: line.start)
    }

    func clipAvailable(for line: LibraryTranscriptLine) -> Bool {
        !live.isRecording && document?.clips.contains(where: {
            $0.playable && $0.source == line.source && line.start >= $0.startOffset - 0.1 &&
                line.start < $0.startOffset + $0.duration
        }) == true
    }

    static func same(_ lhs: URL?, _ rhs: URL?) -> Bool {
        lhs?.standardizedFileURL.path == rhs?.standardizedFileURL.path
    }
}
