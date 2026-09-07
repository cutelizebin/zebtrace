import Foundation
import ZebTraceCore

public enum LibraryResultStatus: String, Sendable {
    case none, transcriptOnly, ready, unavailable
}

public struct LibraryRecording: Identifiable, Sendable {
    public let id: UUID
    public let directory: URL
    public let startedAt: Date
    public let durationSeconds: Double
    public let recordingStatus: String
    public let resultStatus: LibraryResultStatus
    public let summaryPreview: String
    public let hasMicrophone: Bool
    public let hasSystemAudio: Bool
}

public struct LibraryAudioChunk: Identifiable, Sendable {
    public var id: String { url.lastPathComponent }
    public let url: URL
    public let source: String
    public let startOffsetSeconds: Double
    public let durationSeconds: Double
    public let finalized: Bool
}

public struct LibraryTranscriptLine: Identifiable, Sendable {
    public let id: String
    public let source: String
    public let start: Double
    public let end: Double
    public let text: String
    public let possibleDuplicateOf: String?
}

public struct LibraryRecordingDetails: Sendable {
    public let recording: LibraryRecording
    public let summary: String?
    public let transcript: String?
    public let entries: [LibraryTranscriptLine]
    public let chunks: [LibraryAudioChunk]
    public let resultStatus: LibraryResultStatus
    public let warning: String?
}

/// Results are resolved from the selected session, never from a global latest-
/// result preference. Loading requires a matching session identifier; generated
/// content from a different or replaced session is never displayed as current.
public enum RecordingLibrary {
    public static func scan(root: URL) throws -> [LibraryRecording] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let days = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var records: [LibraryRecording] = []
        for day in days {
            try Task.checkCancellation()
            guard day.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  isDirectory(day) else { continue }
            for directory in (try? FileManager.default.contentsOfDirectory(at: day, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [] {
                try Task.checkCancellation()
                guard isDirectory(directory), let manifest = try? readManifest(directory) else { continue }
                let contents = readResults(directory, manifest: manifest)
                records.append(item(directory, manifest: manifest, contents: contents))
            }
        }
        return records.sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString > $1.id.uuidString : $0.startedAt > $1.startedAt }
    }

    public static func loadDetails(recording: LibraryRecording) throws -> LibraryRecordingDetails {
        let manifest = try readManifest(recording.directory)
        guard manifest.id == recording.id else { throw AnalysisFailure(L10n.string("review.error.selectedChanged")) }
        let results = readResults(recording.directory, manifest: manifest, loadEntries: true)
        let chunks = manifest.chunks.compactMap { chunk -> LibraryAudioChunk? in
            guard validChunkName(chunk.file), chunk.startOffsetSeconds.isFinite, chunk.durationSeconds.isFinite,
                  chunk.durationSeconds > 0 else { return nil }
            let url = recording.directory.appendingPathComponent(chunk.file)
            guard (try? AnalysisFiles.regularFile(url)) != nil else { return nil }
            return .init(url: url, source: chunk.source.rawValue, startOffsetSeconds: chunk.startOffsetSeconds,
                         durationSeconds: chunk.durationSeconds, finalized: chunk.finalized)
        }.sorted { $0.startOffsetSeconds < $1.startOffsetSeconds }
        return .init(recording: item(recording.directory, manifest: manifest, contents: results),
                     summary: results.summary, transcript: results.transcript, entries: results.entries,
                     chunks: chunks, resultStatus: results.status, warning: results.warning)
    }

    /// Useful after a user selects a folder outside the current library root.
    public static func recording(at directory: URL) throws -> LibraryRecording {
        let manifest = try readManifest(directory)
        return item(directory, manifest: manifest, contents: readResults(directory, manifest: manifest))
    }

    private struct Results {
        var status: LibraryResultStatus = .none
        var summary: String?
        var transcript: String?
        var entries: [LibraryTranscriptLine] = []
        var warning: String?
    }

    private struct ResultBinding: Decodable {
        let sessionID: UUID
        let status: String?
        let sourceManifestSHA256: String?
        let transcriptContentSHA256: String?
        let transcriptSegmentsSHA256: String?
        let summaryContentSHA256: String?
    }

    private static func readResults(_ directory: URL, manifest: SessionManifest, loadEntries: Bool = false) -> Results {
        var result = Results()
        let hasFiles = ["summary.md", "transcript.md", "transcript.json"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard hasFiles else { return result }
        // No completed content can belong to a still-recording session.
        guard manifest.status != .recording else { return result }
        let completed = binding(directory.appendingPathComponent("analysis.json"), manifest: manifest, directory: directory)
        let transcribed = binding(directory.appendingPathComponent("transcription.json"), manifest: manifest, directory: directory)
        guard let provenance = transcribed ?? completed else {
            result.status = .unavailable
            result.warning = L10n.string("review.error.mismatchedResult")
            return result
        }
        let transcriptData = try? readData(directory.appendingPathComponent("transcript.md"))
        let segmentData = loadEntries ? try? readData(directory.appendingPathComponent("transcript.json")) : nil
        if let transcriptData, matches(transcriptData, expected: provenance.transcriptContentSHA256) {
            result.transcript = String(data: transcriptData, encoding: .utf8)
        }
        if let segmentData, matches(segmentData, expected: provenance.transcriptSegmentsSHA256),
           let segments = try? JSONDecoder().decode([TranscriptEntry].self, from: segmentData),
           segments.allSatisfy({ entry in
               manifest.chunks.contains { $0.file == entry.file && $0.source.rawValue == entry.source } &&
                   entry.start.isFinite && entry.end.isFinite && entry.start > -1 && entry.end >= entry.start
           }) {
            result.entries = segments.map { .init(id: $0.id, source: $0.source, start: $0.start, end: $0.end,
                                                  text: $0.text, possibleDuplicateOf: $0.possibleDuplicateOf) }
        }
        if let completed, completed.status == "completed",
           let data = try? readData(directory.appendingPathComponent("summary.md")),
           matches(data, expected: completed.summaryContentSHA256),
           let transcriptData, matches(transcriptData, expected: completed.transcriptContentSHA256) {
            result.summary = String(data: data, encoding: .utf8)
        }
        if result.summary != nil { result.status = .ready }
        else if result.transcript != nil { result.status = .transcriptOnly }
        else { result.status = .unavailable; result.warning = L10n.string("review.error.changedResult") }
        return result
    }

    private static func binding(_ url: URL, manifest: SessionManifest, directory: URL) -> ResultBinding? {
        guard let data = try? readData(url), let binding = try? JSONDecoder().decode(ResultBinding.self, from: data),
              binding.sessionID == manifest.id else { return nil }
        if let expected = binding.sourceManifestSHA256 {
            guard let current = try? readData(directory.appendingPathComponent("session.json")),
                  AnalysisFiles.digest(current) == expected else { return nil }
        }
        return binding
    }

    private static func matches(_ data: Data, expected: String?) -> Bool {
        // Legacy v0.3 results bind by sessionID; newer results additionally bind
        // the exact content hashes and source manifest without hashing all audio
        // on every library refresh.
        expected.map { AnalysisFiles.digest(data) == $0 } ?? true
    }

    private static func readManifest(_ directory: URL) throws -> SessionManifest {
        guard isDirectory(directory) else { throw AnalysisFailure(L10n.string("review.error.chooseFolder")) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SessionManifest.self, from: readData(directory.appendingPathComponent("session.json")))
        guard manifest.schemaVersion == 1, manifest.chunks.allSatisfy({ validChunkName($0.file) }) else {
            throw AnalysisFailure(L10n.string("review.error.format"))
        }
        return manifest
    }

    private static func validChunkName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".." && name.hasSuffix(".m4a")
    }

    private static func readData(_ url: URL) throws -> Data {
        try AnalysisFiles.regularFile(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw AnalysisFailure(L10n.string("review.error.previewSize")) }
        return try Data(contentsOf: url)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func item(_ directory: URL, manifest: SessionManifest, contents: Results) -> LibraryRecording {
        let duration = manifest.endedAt.map { max(0, $0.timeIntervalSince(manifest.startedAt)) }
            ?? manifest.chunks.map { max(0, $0.startOffsetSeconds + $0.durationSeconds) }.filter(\.isFinite).max() ?? 0
        let preview = contents.summary.map { markdown in
            let lines = markdown.components(separatedBy: .newlines)
            var afterOverview = false
            for line in lines {
                if line.hasPrefix("## ") {
                    if afterOverview { break }
                    afterOverview = true
                    continue
                }
                if afterOverview, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    return String(line.replacingOccurrences(of: #"\[\d{2,}:\d{2}:\d{2}\]"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces).prefix(140))
                }
            }
            return ""
        } ?? ""
        return .init(id: manifest.id, directory: directory, startedAt: manifest.startedAt, durationSeconds: duration,
                     recordingStatus: manifest.status.rawValue, resultStatus: contents.status, summaryPreview: preview,
                     hasMicrophone: manifest.chunks.contains { $0.source == .microphone },
                     hasSystemAudio: manifest.chunks.contains { $0.source == .system })
    }
}
