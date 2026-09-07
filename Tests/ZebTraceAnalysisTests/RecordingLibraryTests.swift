import Foundation
import XCTest
@testable import ZebTraceAnalysis

/// Synthetic manifests and text only: no capture, playback, downloads, or inference.
final class RecordingLibraryTests: XCTestCase {
    private var root: URL!
    private var fixtureCount = 0

    override func setUpWithError() throws {
        fixtureCount = 0
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTraceLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testSelectedSessionNeverUsesAnotherSessionsResults() throws {
        let first = try fixture(start: "2026-09-06T08:00:00Z")
        let second = try fixture(start: "2026-09-06T09:00:00Z")
        try publish(in: first, text: "First synthetic session.", summary: "First overview.")
        try publish(in: second, text: "Second synthetic session.", summary: "Second overview.")

        let firstDetails = try details(first)
        let secondDetails = try details(second)
        XCTAssertEqual(firstDetails.recording.id, first.id)
        XCTAssertEqual(firstDetails.transcript, "First synthetic session.")
        XCTAssertEqual(secondDetails.recording.id, second.id)
        XCTAssertEqual(secondDetails.transcript, "Second synthetic session.")
        XCTAssertFalse(try XCTUnwrap(firstDetails.summary).contains("Second"))

        // Copying a complete, internally consistent review from a different
        // session must not make it a valid result for this selected folder.
        for name in ["transcript.md", "transcript.json", "summary.md", "analysis.json", "transcription.json"] {
            let data = try Data(contentsOf: second.directory.appendingPathComponent(name))
            try data.write(to: first.directory.appendingPathComponent(name))
        }
        let copied = try details(first)
        XCTAssertEqual(copied.resultStatus, .unavailable)
        XCTAssertNil(copied.transcript)
        XCTAssertNil(copied.summary)
        XCTAssertTrue(copied.entries.isEmpty)
        XCTAssertTrue(copied.recording.summaryPreview.isEmpty)
    }

    func testReplacedManifestInvalidatesAnAlreadySelectedRecording() throws {
        let session = try fixture()
        let selected = try RecordingLibrary.recording(at: session.directory)
        var manifest = try json(session.directory.appendingPathComponent("session.json"))
        manifest["id"] = UUID().uuidString
        try writeJSON(manifest, to: session.directory.appendingPathComponent("session.json"))
        XCTAssertThrowsError(try RecordingLibrary.loadDetails(recording: selected))
    }

    func testChangedSourceManifestRejectsOtherwiseIntactResults() throws {
        let session = try fixture()
        try publish(in: session)
        var manifest = try json(session.directory.appendingPathComponent("session.json"))
        manifest["endReason"] = "changed-source-metadata"
        try writeJSON(manifest, to: session.directory.appendingPathComponent("session.json"))

        let changed = try details(session)
        XCTAssertEqual(changed.resultStatus, .unavailable)
        XCTAssertNil(changed.summary)
        XCTAssertNil(changed.transcript)
        XCTAssertTrue(changed.entries.isEmpty)
    }

    func testChangedTranscriptCannotBePairedWithAnOldSummary() throws {
        let session = try fixture()
        try publish(in: session)
        try Data("Unbound replacement transcript.".utf8)
            .write(to: session.directory.appendingPathComponent("transcript.md"))
        let changed = try details(session)
        XCTAssertEqual(changed.resultStatus, .unavailable)
        XCTAssertNil(changed.transcript)
        XCTAssertNil(changed.summary)
        XCTAssertTrue(changed.recording.summaryPreview.isEmpty)
    }

    func testChangedSummaryKeepsOnlyTheVerifiedTranscript() throws {
        let session = try fixture()
        try publish(in: session)
        try Data("Unbound replacement summary.".utf8)
            .write(to: session.directory.appendingPathComponent("summary.md"))
        let changed = try details(session)
        XCTAssertEqual(changed.resultStatus, .transcriptOnly)
        XCTAssertEqual(changed.transcript, "Synthetic transcript.")
        XCTAssertNil(changed.summary)
        XCTAssertTrue(changed.recording.summaryPreview.isEmpty)
    }

    func testVerifiedTranscriptIsReadableWhileSummaryIsIncomplete() throws {
        let session = try fixture()
        try publish(in: session, completionStatus: "summarizing")
        let pending = try details(session)
        XCTAssertEqual(pending.resultStatus, .transcriptOnly)
        XCTAssertEqual(pending.transcript, "Synthetic transcript.")
        XCTAssertEqual(pending.entries.map(\.text), ["Synthetic transcript."])
        XCTAssertNil(pending.summary)

        // The transcription checkpoint stands on its own before analysis.json
        // exists, including after the summary helper fails or is canceled.
        try FileManager.default.removeItem(at: session.directory.appendingPathComponent("analysis.json"))
        XCTAssertEqual(try details(session).resultStatus, .transcriptOnly)
    }

    func testLegacyResultsBindBySessionIDWithoutRequiringNewHashFields() throws {
        let session = try fixture(legacy: true)
        try publish(in: session, includeHashes: false)
        let legacy = try details(session)
        XCTAssertEqual(legacy.resultStatus, .ready)
        XCTAssertEqual(legacy.transcript, "Synthetic transcript.")
        XCTAssertNotNil(legacy.summary)

        try writeJSON(["sessionID": UUID().uuidString, "status": "completed"],
                      to: session.directory.appendingPathComponent("analysis.json"))
        try FileManager.default.removeItem(at: session.directory.appendingPathComponent("transcription.json"))
        XCTAssertEqual(try details(session).resultStatus, .unavailable)
    }

    func testLegacyAndTimestampFoldersSortByManifestStartTime() throws {
        let older = try fixture(start: "2026-09-06T06:00:00Z", leaf: "23-59-59-\(UUID().uuidString)", legacy: true)
        let newer = try fixture(start: "2026-09-06T09:00:00Z", leaf: "2026-09-06_09-00-00")
        let newest = try fixture(start: "2026-09-06T10:00:00Z", leaf: "2026-09-06_10-00-00_02")
        let scanned = try RecordingLibrary.scan(root: root)
        XCTAssertEqual(scanned.map(\.id), [newest.id, newer.id, older.id])
        XCTAssertEqual(scanned.map(\.directory.lastPathComponent),
                       [newest.directory.lastPathComponent, newer.directory.lastPathComponent, older.directory.lastPathComponent])
        XCTAssertEqual(try details(older).recording.id, older.id)
    }

    func testInvalidManifestDoesNotHideOtherValidSessions() throws {
        let valid = try fixture()
        let badSchema = try fixture()
        var schema = try json(badSchema.directory.appendingPathComponent("session.json"))
        schema["schemaVersion"] = 99
        try writeJSON(schema, to: badSchema.directory.appendingPathComponent("session.json"))
        let traversal = try fixture()
        var unsafe = try json(traversal.directory.appendingPathComponent("session.json"))
        var chunks = try XCTUnwrap(unsafe["chunks"] as? [[String: Any]])
        chunks[0]["file"] = "../outside.m4a"
        unsafe["chunks"] = chunks
        try writeJSON(unsafe, to: traversal.directory.appendingPathComponent("session.json"))
        let malformed = try fixture()
        try Data("not JSON".utf8).write(to: malformed.directory.appendingPathComponent("session.json"))

        XCTAssertEqual(try RecordingLibrary.scan(root: root).map(\.id), [valid.id])
        for session in [badSchema, traversal, malformed] {
            XCTAssertThrowsError(try RecordingLibrary.recording(at: session.directory))
        }
    }

    func testScanIgnoresModelFoldersAndSymlinkedSessions() throws {
        let valid = try fixture()
        let link = valid.directory.deletingLastPathComponent().appendingPathComponent("linked-session")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid.directory)
        let modelChild = root.appendingPathComponent("Models/2026-09-06_12-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: modelChild, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: valid.directory.appendingPathComponent("session.json"),
                                         to: modelChild.appendingPathComponent("session.json"))
        XCTAssertEqual(try RecordingLibrary.scan(root: root).map(\.id), [valid.id])
        XCTAssertThrowsError(try RecordingLibrary.recording(at: link))
    }

    func testSavedChunksKeepSourceOffsetsAndExcludeSymlinkedAudio() throws {
        let session = try fixture()
        let outside = root.appendingPathComponent("outside.m4a")
        try Data("fixture bytes".utf8).write(to: outside)
        let microphone = session.directory.appendingPathComponent("microphone-00001.m4a")
        try FileManager.default.removeItem(at: microphone)
        try FileManager.default.createSymbolicLink(at: microphone, withDestinationURL: outside)

        let chunks = try details(session).chunks
        XCTAssertEqual(chunks.map(\.source), ["system"])
        XCTAssertEqual(try XCTUnwrap(chunks.first).startOffsetSeconds, -0.05, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(chunks.first).durationSeconds, 2, accuracy: 0.000_001)
        XCTAssertTrue(try XCTUnwrap(chunks.first).finalized)
    }

    func testActiveRecordingNeverExposesCompletedResults() throws {
        let session = try fixture(status: "recording")
        try publish(in: session)
        let active = try details(session)
        XCTAssertEqual(active.resultStatus, .none)
        XCTAssertNil(active.summary)
        XCTAssertNil(active.transcript)
        XCTAssertTrue(active.entries.isEmpty)
    }

    private struct Fixture { let id: UUID; let directory: URL }

    private func fixture(start: String = "2026-09-06T08:00:00Z", leaf: String? = nil,
                         legacy: Bool = false, status: String = "completed") throws -> Fixture {
        fixtureCount += 1
        let legacyID = legacy ? leaf.flatMap { UUID(uuidString: String($0.suffix(36))) } : nil
        let id = legacyID ?? UUID()
        let suffix = fixtureCount == 1 ? "" : String(format: "_%02d", fixtureCount)
        let name = leaf ?? (legacy ? "08-00-00-\(id.uuidString)" : "2026-09-06_08-00-00" + suffix)
        let directory = root.appendingPathComponent("2026-09-06/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "schemaVersion": 1, "id": id.uuidString, "startedAt": start, "updatedAt": start,
            "endedAt": "2026-09-06T10:30:00Z", "status": status, "endReason": "userPaused",
            "chunkDurationSeconds": 600, "hostTimeOrigin": 10_000, "hostClockTicksPerSecond": 1_000_000_000,
            "chunks": [
                ["source": "system", "file": "system-00001.m4a", "startOffsetSeconds": -0.05,
                 "durationSeconds": 2, "sampleRate": 48_000, "channels": 2, "frameCount": 96_000, "finalized": true],
                ["source": "microphone", "file": "microphone-00001.m4a", "startOffsetSeconds": 2.5,
                 "durationSeconds": 1, "sampleRate": 48_000, "channels": 1, "frameCount": 48_000, "finalized": true]
            ]
        ]
        if !legacy { manifest["directoryName"] = name }
        try writeJSON(manifest, to: directory.appendingPathComponent("session.json"))
        for file in ["system-00001.m4a", "microphone-00001.m4a"] {
            // The catalog checks filesystem identity, not AAC decoding. Keep
            // these fixtures deliberately incapable of recording real sound.
            try Data("synthetic audio placeholder".utf8).write(to: directory.appendingPathComponent(file))
        }
        return Fixture(id: id, directory: directory)
    }

    private func publish(in session: Fixture, text: String = "Synthetic transcript.",
                         summary: String = "Synthetic overview.", completionStatus: String = "completed",
                         includeHashes: Bool = true) throws {
        let transcript = Data(text.utf8)
        let segments = try JSONSerialization.data(withJSONObject: [[
            "id": "fixture-line", "source": "microphone", "file": "microphone-00001.m4a",
            "start": 2.5, "end": 3.0, "text": text
        ]], options: [.sortedKeys])
        let summaryData = Data("# Recording review\n\n## Overview\n\n\(summary)\n".utf8)
        try transcript.write(to: session.directory.appendingPathComponent("transcript.md"))
        try segments.write(to: session.directory.appendingPathComponent("transcript.json"))
        try summaryData.write(to: session.directory.appendingPathComponent("summary.md"))
        var binding: [String: Any] = ["sessionID": session.id.uuidString, "status": completionStatus]
        if includeHashes {
            binding["sourceManifestSHA256"] = AnalysisFiles.digest(try Data(contentsOf: session.directory.appendingPathComponent("session.json")))
            binding["transcriptContentSHA256"] = AnalysisFiles.digest(transcript)
            binding["transcriptSegmentsSHA256"] = AnalysisFiles.digest(segments)
            binding["summaryContentSHA256"] = AnalysisFiles.digest(summaryData)
        }
        try writeJSON(binding, to: session.directory.appendingPathComponent("analysis.json"))
        binding["status"] = "transcribed"
        try writeJSON(binding, to: session.directory.appendingPathComponent("transcription.json"))
    }

    private func details(_ session: Fixture) throws -> LibraryRecordingDetails {
        try RecordingLibrary.loadDetails(recording: RecordingLibrary.recording(at: session.directory))
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func writeJSON(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }
}
