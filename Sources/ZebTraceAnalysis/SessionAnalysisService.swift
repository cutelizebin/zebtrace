import Darwin
import Foundation
import ZebTraceCore

public struct SessionAnalysisService: Sendable {
    private let speechOverride: (any TranscriptionProvider)?
    private let summaryOverride: (any SummarizationProvider)?

    public init() { speechOverride = nil; summaryOverride = nil }

    init(speech: any TranscriptionProvider, summary: any SummarizationProvider) {
        speechOverride = speech; summaryOverride = summary
    }

    public func analyze(sessionDirectory: URL, configuration: AnalysisConfiguration,
                        progress: @escaping @Sendable (AnalysisProgress) -> Void) async throws -> AnalysisResult {
        try Task.checkCancellation()
        progress(.init(stage: .preparing))
        let manifestURL = sessionDirectory.appendingPathComponent("session.json")
        try AnalysisFiles.regularFile(manifestURL)
        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SessionManifest.self, from: manifestData)
        try Self.validate(manifest)
        let chunks = manifest.chunks.sorted { $0.startOffsetSeconds < $1.startOffsetSeconds }
        for chunk in chunks { try AnalysisFiles.regularFile(sessionDirectory.appendingPathComponent(chunk.file)) }
        if let capacity = try sessionDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, capacity < 512 * 1024 * 1024 {
            throw AnalysisFailure(L10n.string("review.error.freeSpace"))
        }
        let cacheDirectory = sessionDirectory.appendingPathComponent(".zebtrace-analysis", isDirectory: true)
        try AnalysisFiles.directory(cacheDirectory)
        let lease = try SessionAnalysisLease(directory: cacheDirectory)
        defer { lease.close() }
        guard try Data(contentsOf: manifestURL) == manifestData else {
            throw AnalysisFailure(L10n.string("review.error.analysisChanged"))
        }
        // The exclusive lease excludes running analysis. Only recognized crash
        // leftovers belong to us; preserve unknown content even inside the cache.
        for item in try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            if (try? ManagedStorage.isOwnedScratchDirectory(item)) == true {
                try? FileManager.default.removeItem(at: item)
            }
        }
        let work = cacheDirectory.appendingPathComponent("work-" + UUID().uuidString, isDirectory: true)
        try AnalysisFiles.directory(work)
        defer { try? FileManager.default.removeItem(at: work) }
        let speech: any TranscriptionProvider = speechOverride ?? WhisperProvider(
            executable: configuration.runtimeDirectory.appendingPathComponent("whisper-cli"), model: configuration.asrModelURL)
        let summary: any SummarizationProvider = summaryOverride ?? LlamaSummaryProvider(
            executable: configuration.runtimeDirectory.appendingPathComponent("llama-completion"), model: configuration.summaryModelURL)
        let modelDirectories = Set([configuration.asrModelURL.deletingLastPathComponent().standardizedFileURL,
                                    configuration.summaryModelURL.deletingLastPathComponent().standardizedFileURL])
        var modelLeases: [LocalModelLease] = []
        defer { modelLeases.forEach { $0.close() } }
        for directory in modelDirectories.sorted(by: { $0.path < $1.path }) {
            modelLeases.append(try LocalModelLease(directory: directory, exclusive: false))
        }
        let modelHash = try AnalysisFiles.digest(file: configuration.asrModelURL)
        let vadURL = configuration.asrModelURL.deletingLastPathComponent().appendingPathComponent("ggml-silero-v6.2.0.bin")
        let vadHash = (try? AnalysisFiles.digest(file: vadURL)) ?? "none"
        let runtimeInfoURL = configuration.runtimeDirectory.appendingPathComponent("runtime-info.json")
        let bundledRuntimeInfo = configuration.runtimeDirectory.deletingLastPathComponent()
            .appendingPathComponent("Resources/InferenceRuntime/runtime-info.json")
        let runtimeInfo = (try? Data(contentsOf: runtimeInfoURL)) ??
            (try? Data(contentsOf: bundledRuntimeInfo)) ?? Data("development-runtime".utf8)
        let runtimeHash = AnalysisFiles.digest(runtimeInfo)
        var entries: [TranscriptEntry] = []
        var audioHashes: [String: String] = [:]
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(.init(stage: .transcribing, completed: index, total: chunks.count))
            let audio = sessionDirectory.appendingPathComponent(chunk.file)
            let audioHash = try AnalysisFiles.digest(file: audio)
            audioHashes[chunk.file] = audioHash
            let key = AnalysisFiles.digest(Data("asr-v2-short-windows-vad|\(vadHash)|\(runtimeHash)|\(modelHash)|\(audioHash)|\(chunk.source.rawValue)|\(chunk.startOffsetSeconds)".utf8))
            let cached = cacheDirectory.appendingPathComponent("asr-\(key).json")
            let chunkEntries: [TranscriptEntry]
            if (try? AnalysisFiles.regularFile(cached)) != nil,
               let data = try? Data(contentsOf: cached),
               let saved = try? JSONDecoder().decode([TranscriptEntry].self, from: data),
               saved.allSatisfy({ $0.file == chunk.file && $0.source == chunk.source.rawValue &&
                   $0.start.isFinite && $0.end.isFinite && $0.start >= chunk.startOffsetSeconds &&
                   $0.end >= $0.start && $0.end <= chunk.startOffsetSeconds + chunk.durationSeconds + 2 }) {
                chunkEntries = saved
            } else {
                let wav = work.appendingPathComponent("chunk.wav")
                defer { try? FileManager.default.removeItem(at: wav) }
                _ = try AudioNormalizer.convert(audio, to: wav)
                let reader = try AudioWindowReader(wav)
                let windowURL = work.appendingPathComponent("window.wav")
                defer { try? FileManager.default.removeItem(at: windowURL) }
                var collected: [TranscriptEntry] = []
                while let window = try reader.next(to: windowURL) {
                    try Task.checkCancellation()
                    let windowCache = cacheDirectory.appendingPathComponent("window-\(key)-\(window.startFrame).json")
                    let segments: [SpeechSegment]
                    if (try? AnalysisFiles.regularFile(windowCache)) != nil,
                       let data = try? Data(contentsOf: windowCache),
                       let saved = try? JSONDecoder().decode([SpeechSegment].self, from: data),
                       saved.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 &&
                           $0.end >= $0.start && $0.end <= window.duration + 2 }) {
                        segments = saved
                    } else {
                        segments = window.hasSignal ? try await speech.transcribe(audio: windowURL, workDirectory: work) : []
                        guard segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 &&
                            $0.end >= $0.start && $0.start <= window.duration + 2 }) else {
                            throw AnalysisFailure(L10n.string("review.error.windowTimestamp"))
                        }
                        try Task.checkCancellation()
                        try AnalysisFiles.encode(segments, to: windowCache)
                    }
                    collected.append(contentsOf: segments.enumerated().map { number, segment in
                        .init(id: "\(chunk.file)-\(window.startFrame)-\(number)", source: chunk.source.rawValue, file: chunk.file,
                              start: chunk.startOffsetSeconds + window.start + min(segment.start, window.duration),
                              end: chunk.startOffsetSeconds + window.start + min(segment.end, window.duration), text: segment.text)
                    })
                }
                chunkEntries = collected
                try Task.checkCancellation()
                try AnalysisFiles.encode(chunkEntries, to: cached)
            }
            entries.append(contentsOf: chunkEntries)
            progress(.init(stage: .transcribing, completed: index + 1, total: chunks.count))
        }
        let ordered = RecordingTranscript.markPossibleDuplicates(entries)
        let language = AppLanguage.matching(configuration.language) ?? .english
        let evidence = RecordingTranscript.evidence(ordered, language: language)
        let result = AnalysisResult(directory: sessionDirectory)
        guard try Data(contentsOf: manifestURL) == manifestData else {
            throw AnalysisFailure(L10n.string("review.error.transcriptionChanged"))
        }
        // A failed re-summary must not pair a new transcript with an old summary
        // or a stale completed status. Keep the previous review privately.
        if FileManager.default.fileExists(atPath: result.summaryURL.path) {
            let previous = cacheDirectory.appendingPathComponent("previous-review", isDirectory: true)
            try AnalysisFiles.directory(previous)
            for name in ["transcript.md", "transcript.json", "transcription.json", "summary.md", "analysis.json"] {
                let existing = sessionDirectory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: existing.path) {
                    try AnalysisFiles.regularFile(existing)
                    try AnalysisFiles.write(Data(contentsOf: existing), to: previous.appendingPathComponent(name))
                }
            }
            try FileManager.default.removeItem(at: result.summaryURL)
        }
        let oldMetadata = sessionDirectory.appendingPathComponent("analysis.json")
        if FileManager.default.fileExists(atPath: oldMetadata.path) {
            try AnalysisFiles.regularFile(oldMetadata)
            try FileManager.default.removeItem(at: oldMetadata)
        }
        let title = L10n.string("review.transcript.title", language: language)
        let note = L10n.string("review.transcript.note", language: language)
        let body = evidence.isEmpty ? L10n.string("review.transcript.empty", language: language) : evidence
        try AnalysisFiles.write("\(title)\n\n\(note)\n\n\(body)\n", to: result.transcriptURL)
        try AnalysisFiles.encode(ordered, to: sessionDirectory.appendingPathComponent("transcript.json"))
        struct TranscriptionMetadata: Encodable {
            let schemaVersion = 1
            let sessionID: UUID
            let sourceManifestSHA256: String
            let transcriptContentSHA256: String
            let transcriptSegmentsSHA256: String
        }
        let sourceManifestHash = AnalysisFiles.digest(manifestData)
        let transcriptHash = try AnalysisFiles.digest(file: result.transcriptURL)
        let segmentsHash = try AnalysisFiles.digest(file: sessionDirectory.appendingPathComponent("transcript.json"))
        try AnalysisFiles.encode(TranscriptionMetadata(sessionID: manifest.id,
            sourceManifestSHA256: sourceManifestHash, transcriptContentSHA256: transcriptHash,
            transcriptSegmentsSHA256: segmentsHash), to: sessionDirectory.appendingPathComponent("transcription.json"))
        try Task.checkCancellation()
        let summaryHash = try AnalysisFiles.digest(file: configuration.summaryModelURL)
        var finishedSummary: String
        if evidence.isEmpty {
            finishedSummary = L10n.string("review.summary.empty", language: language)
        } else {
            var sections = RecordingTranscript.sections(evidence)
            var combining = false
            var round = 0
            while true {
                try Task.checkCancellation()
                var notes: [String] = []
                for (index, section) in sections.enumerated() {
                    progress(.init(stage: .summarizing, completed: index, total: sections.count))
                    let promptHash = AnalysisFiles.digest(Data(LlamaSummaryProvider.prompt(
                        text: "", language: configuration.language, combiningNotes: combining).utf8))
                    let key = AnalysisFiles.digest(Data("summary-v5-recording|\(promptHash)|\(runtimeHash)|\(summaryHash)|\(configuration.language)|\(combining)|\(section)".utf8))
                    let cached = cacheDirectory.appendingPathComponent("summary-\(key).txt")
                    let text: String
                    if (try? AnalysisFiles.regularFile(cached)) != nil,
                       let saved = try? String(contentsOf: cached, encoding: .utf8), !saved.isEmpty { text = saved }
                    else {
                        text = try await summary.summarize(text: section, language: configuration.language,
                                                           combiningNotes: combining, workDirectory: work)
                        try Task.checkCancellation()
                        try AnalysisFiles.write(text, to: cached)
                    }
                    notes.append(text)
                    progress(.init(stage: .summarizing, completed: index + 1, total: sections.count))
                }
                if notes.count == 1 { finishedSummary = notes[0]; break }
                let combined = notes.joined(separator: "\n\n---\n\n")
                let next = RecordingTranscript.sections(combined)
                round += 1
                guard round <= 12, next.count < sections.count || next.count == 1 else {
                    throw AnalysisFailure(L10n.string("review.error.condense"))
                }
                sections = next
                combining = true
            }
        }
        try Task.checkCancellation()
        // Do not publish results against a recording that changed during analysis.
        guard try Data(contentsOf: manifestURL) == manifestData else {
            throw AnalysisFailure(L10n.string("review.error.analysisChanged"))
        }
        progress(.init(stage: .saving))
        let heading = L10n.string("review.summary.title", language: language)
        let disclaimer = L10n.string("review.summary.note", language: language)
        let linkTitle = L10n.string("review.summary.transcriptLink", language: language)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: configuration.language)
        dateFormatter.dateStyle = .medium; dateFormatter.timeStyle = .medium
        let sessionTitle = dateFormatter.string(from: manifest.startedAt)
        let markdown = "\(heading)\n\n\(sessionTitle) · \(disclaimer)\n\n\(finishedSummary)\n\n---\n\n[\(linkTitle)](transcript.md)\n"
        try AnalysisFiles.write(markdown, to: result.summaryURL)
        struct Metadata: Encodable {
            let schemaVersion = 1
            let status = "completed"
            let sessionID: UUID
            let createdAt: Date
            let language: String
            let asrSHA256: String
            let vadSHA256: String
            let summarySHA256: String
            let runtimeSHA256: String
            let audioSHA256: [String: String]
            let sourceManifestSHA256: String
            let transcriptContentSHA256: String
            let transcriptSegmentsSHA256: String
            let summaryContentSHA256: String
        }
        try AnalysisFiles.encode(Metadata(sessionID: manifest.id, createdAt: Date(), language: configuration.language,
            asrSHA256: modelHash, vadSHA256: vadHash, summarySHA256: summaryHash, runtimeSHA256: runtimeHash, audioSHA256: audioHashes,
            sourceManifestSHA256: sourceManifestHash, transcriptContentSHA256: transcriptHash,
            transcriptSegmentsSHA256: segmentsHash, summaryContentSHA256: try AnalysisFiles.digest(file: result.summaryURL)),
            to: sessionDirectory.appendingPathComponent("analysis.json"))
        return result
    }

    static func validate(_ manifest: SessionManifest) throws {
        guard manifest.schemaVersion == 1, manifest.status == .completed, manifest.endedAt != nil else {
            throw AnalysisFailure(L10n.string("review.error.chooseCompleted"))
        }
        guard !manifest.chunks.isEmpty, manifest.chunks.allSatisfy({ chunk in
            chunk.finalized && !chunk.file.isEmpty && chunk.file == URL(fileURLWithPath: chunk.file).lastPathComponent &&
                !chunk.file.contains("/") && chunk.file.hasSuffix(".m4a") &&
                chunk.startOffsetSeconds.isFinite && chunk.startOffsetSeconds > -1 &&
                chunk.durationSeconds.isFinite && chunk.durationSeconds > 0
        }) else { throw AnalysisFailure(L10n.string("review.error.invalidChunks")) }
        guard Set(manifest.chunks.map(\.file)).count == manifest.chunks.count else {
            throw AnalysisFailure(L10n.string("review.error.duplicateChunks"))
        }
    }
}

private final class SessionAnalysisLease {
    private var descriptor: Int32
    init(directory: URL) throws {
        descriptor = Darwin.open(directory.appendingPathComponent("analysis.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AnalysisFailure(L10n.string("review.error.lock")) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1
            throw AnalysisFailure(L10n.string("review.error.locked"))
        }
    }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
}
