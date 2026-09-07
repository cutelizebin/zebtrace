import Darwin
import Foundation
import XCTest
import ZebTraceCore
@testable import ZebTraceAnalysis

final class ManagedStorageTests: XCTestCase {
    private var temporaryRoot: URL!
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ZebTraceManagedStorageTests-\(UUID().uuidString)", isDirectory: true)
        libraryRoot = temporaryRoot.appendingPathComponent("selected-root", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
        libraryRoot = nil
        temporaryRoot = nil
    }

    func testFinderMetadataDoesNotPreventRemovingARecognizedRecording() throws {
        let recording = try makeRecording()
        try write("Finder metadata", at: recording.directory.appendingPathComponent(".DS_Store"))
        XCTAssertNoThrow(try ManagedStorage.recordingURLForTrash(recording: recording, root: libraryRoot))
        XCTAssertFalse(try ManagedStorage.generatedURLsForTrash(recording: recording, root: libraryRoot)
            .contains { $0.lastPathComponent == ".DS_Store" })
    }

    func testInventoryCountsOnlyRecognizedRecordingModelAndGeneratedFiles() throws {
        let recording = try makeRecording()
        let manifest = recording.directory.appendingPathComponent("session.json")
        let manifestBytes = Int64(try Data(contentsOf: manifest).count)
        try write("audio", at: recording.directory.appendingPathComponent("system-0001.m4a"))
        try write("result", at: recording.directory.appendingPathComponent("transcript.md"))
        let cache = recording.directory.appendingPathComponent(".zebtrace-analysis")
        let cacheFile = cache.appendingPathComponent("asr-" + String(repeating: "a", count: 64) + ".json")
        try write("cache", at: cacheFile)
        try write("unrelated", at: cache.appendingPathComponent("personal-notes.txt"))
        try write("unrelated", at: libraryRoot.appendingPathComponent("holiday.mov"))
        let models = libraryRoot.appendingPathComponent("Models")
        let filename = LocalModelStore.models[0].filename
        let model = models.appendingPathComponent(filename)
        try write("model", at: model)
        try write("partial", at: models.appendingPathComponent(filename + ".partial"))
        try write("stamp", at: models.appendingPathComponent(filename + ".verified.json"))
        try write("unknown model", at: models.appendingPathComponent("my-model.gguf"))
        let external = temporaryRoot.appendingPathComponent("external")
        try write(String(repeating: "x", count: 1000), at: external)
        try FileManager.default.createSymbolicLink(at: models.appendingPathComponent(LocalModelStore.models[1].filename),
                                                  withDestinationURL: external)
        // scan accepts a readable manifest here; cleanup inventory must require
        // the actual app directory format and its manifest binding as well.
        try FileManager.default.copyItem(at: recording.directory,
            to: recording.directory.deletingLastPathComponent().appendingPathComponent("user-project"))

        let inventory = try ManagedStorage.inventory(root: libraryRoot)
        XCTAssertEqual(inventory.recordings.map(\.id), [recording.id])
        XCTAssertEqual(inventory.recordingCount, 1)
        XCTAssertEqual(inventory.recordingBytes, manifestBytes + 5)
        XCTAssertEqual(inventory.generatedBytes, 11)
        XCTAssertEqual(inventory.modelBytes, 17)
        XCTAssertEqual(Set(inventory.modelURLs.map(\.lastPathComponent)),
                       [filename, filename + ".partial", filename + ".verified.json"])
        XCTAssertEqual(try Data(contentsOf: external).count, 1000)
    }

    func testGeneratedCleanupPreservesAudioUnknownFilesAndSymbolicLinks() throws {
        let recording = try makeRecording()
        let directory = recording.directory
        let audio = directory.appendingPathComponent("system-0001.m4a")
        let manifest = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        try write("audio", at: audio)
        let generated = ["transcript.md", "transcript.json", "transcription.json", "summary.md", "analysis.json"]
        for name in generated { try write(name, at: directory.appendingPathComponent(name)) }
        let cache = directory.appendingPathComponent(".zebtrace-analysis")
        let cacheJSON = cache.appendingPathComponent("window-" + String(repeating: "b", count: 64) + "-320000.json")
        let previous = cache.appendingPathComponent("previous-review/transcript.md")
        let scratch = cache.appendingPathComponent("work-\(UUID().uuidString)/chunk.wav")
        for file in [cacheJSON, previous, scratch] { try write("derived", at: file) }
        let notes = cache.appendingPathComponent("previous-review/my-notes.md")
        try write("keep me", at: notes)
        let external = temporaryRoot.appendingPathComponent("external-summary.txt")
        try write("external", at: external)
        let link = cache.appendingPathComponent("summary-" + String(repeating: "c", count: 64) + ".txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)

        XCTAssertThrowsError(try ManagedStorage.recordingURLForTrash(recording: recording, root: libraryRoot))
        try ManagedStorage.withExclusiveAccess(recording: recording, root: libraryRoot) { _ in
            let files = try ManagedStorage.generatedURLsForTrash(recording: recording, root: libraryRoot)
            XCTAssertEqual(files.count, 8)
            for file in files { try FileManager.default.removeItem(at: file) }
        }

        XCTAssertEqual(try String(contentsOf: audio, encoding: .utf8), "audio")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("session.json")), manifest)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "keep me")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), external.path)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "external")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("analysis.lock").path))
        XCTAssertTrue(try ManagedStorage.generatedURLsForTrash(recording: recording, root: libraryRoot).isEmpty)
    }

    func testInventoryIncludesOnlyFullyRecognizedCrashedModelMigrationDirectories() throws {
        let models = libraryRoot.appendingPathComponent("Models")
        let staging = models.appendingPathComponent(".migration-\(UUID().uuidString)")
        let name = LocalModelStore.models[0].filename
        let complete = staging.appendingPathComponent(name)
        let partial = staging.appendingPathComponent(name + ".partial")
        try write("staged", at: complete)
        try write("partial", at: partial)
        let unrelated = models.appendingPathComponent(".migration-personal/" + name)
        try write("my personal file", at: unrelated)
        let inventory = try ManagedStorage.inventory(root: libraryRoot)
        XCTAssertEqual(inventory.modelBytes, 13)
        XCTAssertEqual(Set(inventory.modelURLs.map { $0.resolvingSymlinksInPath().path }), Set([complete, partial].map { $0.resolvingSymlinksInPath().path }))

        let external = temporaryRoot.appendingPathComponent("outside-model")
        try write("outside", at: external)
        let link = staging.appendingPathComponent(LocalModelStore.models[1].filename)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        XCTAssertEqual(try ManagedStorage.inventory(root: libraryRoot).modelBytes, 0,
                       "An unrecognized staging layout must not be presented as wholly managed")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), external.path)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "my personal file")
    }

    func testTrashReturnsOnlyTheSelectedSessionAndAcceptsCollisionSuffixes() throws {
        let first = try makeRecording()
        let second = try makeRecording()
        XCTAssertTrue(second.directory.lastPathComponent.hasSuffix("_02"))
        let unrelated = libraryRoot.appendingPathComponent("notes.txt")
        try write("keep", at: unrelated)
        let destination = temporaryRoot.appendingPathComponent("simulated-trash")
        try ManagedStorage.withExclusiveAccess(recording: second, root: libraryRoot) { _ in
            let url = try ManagedStorage.recordingURLForTrash(recording: second, root: libraryRoot)
            XCTAssertEqual(url.path, second.directory.path)
            try FileManager.default.moveItem(at: url, to: destination)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryRoot.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("session.json").path))
    }

    func testCrashedInferenceScratchLogsAreRecognizedButUnrelatedLogsAreRetained() throws {
        let recording = try makeRecording()
        let work = recording.directory.appendingPathComponent(".zebtrace-analysis/work-\(UUID().uuidString)")
        let logs = [".stdout", ".stderr"].map { work.appendingPathComponent(UUID().uuidString + $0) }
        for url in logs { try write("generated inference output", at: url) }
        XCTAssertEqual(Set(try ManagedStorage.generatedURLsForTrash(recording: recording, root: libraryRoot).map { $0.resolvingSymlinksInPath().path }), Set(logs.map { $0.resolvingSymlinksInPath().path }))
        XCTAssertNoThrow(try ManagedStorage.recordingURLForTrash(recording: recording, root: libraryRoot))

        let unknown = work.appendingPathComponent("personal.stdout")
        try write("keep", at: unknown)
        XCTAssertThrowsError(try ManagedStorage.recordingURLForTrash(recording: recording, root: libraryRoot))
        XCTAssertFalse(try ManagedStorage.generatedURLsForTrash(recording: recording, root: libraryRoot).contains(unknown))
        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "keep")
    }

    func testCrossRootAndReplacedManifestAreRejectedBeforeOperation() throws {
        let recording = try makeRecording()
        let otherRoot = temporaryRoot.appendingPathComponent("other-root")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        var called = false
        XCTAssertThrowsError(try ManagedStorage.withExclusiveAccess(recording: recording, root: otherRoot) { _ in called = true })
        XCTAssertFalse(called)
        try mutateManifest(in: recording.directory) { $0["id"] = UUID().uuidString }
        XCTAssertThrowsError(try ManagedStorage.recordingURLForTrash(recording: recording, root: libraryRoot))
        XCTAssertThrowsError(try ManagedStorage.generatedURLsForTrash(recording: recording, root: libraryRoot))
        XCTAssertThrowsError(try ManagedStorage.withExclusiveAccess(recording: recording, root: libraryRoot) { _ in called = true })
        XCTAssertFalse(called)
    }

    func testWrongDirectoryBindingInvalidDatesAndUnknownSessionNamesAreNotManaged() throws {
        let recording = try makeRecording()
        let invalidDay = libraryRoot.appendingPathComponent("2026-02-30")
        try FileManager.default.createDirectory(at: invalidDay, withIntermediateDirectories: true)
        let impossible = invalidDay.appendingPathComponent("2026-02-30_10-20-30")
        try FileManager.default.copyItem(at: recording.directory, to: impossible)
        try mutateManifest(in: impossible) { $0["directoryName"] = impossible.lastPathComponent }
        let unknown = recording.directory.deletingLastPathComponent().appendingPathComponent("personal-project")
        try FileManager.default.copyItem(at: recording.directory, to: unknown)
        try mutateManifest(in: recording.directory) { $0["directoryName"] = "a-different-recording" }

        XCTAssertEqual(try ManagedStorage.inventory(root: libraryRoot).recordingCount, 0)
        for directory in [recording.directory, impossible, unknown] {
            let item = try RecordingLibrary.recording(at: directory)
            XCTAssertThrowsError(try ManagedStorage.recordingURLForTrash(recording: item, root: libraryRoot))
        }
    }

    func testLegacyDirectoryStillRequiresItsUUIDToMatchTheManifest() throws {
        let recording = try makeRecording()
        let parent = recording.directory.deletingLastPathComponent()
        let legacy = parent.appendingPathComponent("10-20-30-" + recording.id.uuidString)
        try FileManager.default.moveItem(at: recording.directory, to: legacy)
        try mutateManifest(in: legacy) { $0.removeValue(forKey: "directoryName") }
        let old = try RecordingLibrary.recording(at: legacy)
        XCTAssertEqual(try ManagedStorage.recordingURLForTrash(recording: old, root: libraryRoot).path, legacy.path)
        try mutateManifest(in: legacy) { $0["id"] = UUID().uuidString }
        let replaced = try RecordingLibrary.recording(at: legacy)
        XCTAssertThrowsError(try ManagedStorage.recordingURLForTrash(recording: replaced, root: libraryRoot))
    }

    func testSymlinkRootSessionAndManifestCannotAuthorizeCleanup() throws {
        let recording = try makeRecording()
        let rootLink = temporaryRoot.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: libraryRoot)
        XCTAssertThrowsError(try ManagedStorage.inventory(root: rootLink))
        XCTAssertThrowsError(try ManagedStorage.recordingURLForTrash(recording: recording, root: rootLink))
        let manifestURL = recording.directory.appendingPathComponent("session.json")
        let external = temporaryRoot.appendingPathComponent("external-manifest.json")
        try FileManager.default.moveItem(at: manifestURL, to: external)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: external)
        XCTAssertThrowsError(try ManagedStorage.generatedURLsForTrash(recording: recording, root: libraryRoot))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: manifestURL.path), external.path)
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.moveItem(at: external, to: manifestURL)
        let outside = temporaryRoot.appendingPathComponent("outside-session")
        try FileManager.default.moveItem(at: recording.directory, to: outside)
        try FileManager.default.createSymbolicLink(at: recording.directory, withDestinationURL: outside)
        XCTAssertThrowsError(try ManagedStorage.recordingURLForTrash(recording: recording, root: libraryRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("session.json").path))
    }

    func testActiveRecordingAndBusyAnalysisPreventCleanupAndLeaseSpansOperation() throws {
        let active = try SessionWriter(root: libraryRoot)
        let activeItem = try RecordingLibrary.recording(at: active.directory)
        XCTAssertThrowsError(try ManagedStorage.withExclusiveAccess(recording: activeItem, root: libraryRoot) { _ in
            XCTFail("An active recorder must never enter cleanup")
        })
        try active.finish()
        let recording = try makeRecording()
        let cache = recording.directory.appendingPathComponent(".zebtrace-analysis")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let lockURL = cache.appendingPathComponent("analysis.lock")
        let held = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(held, 0)
        defer { Darwin.close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try ManagedStorage.withExclusiveAccess(recording: recording, root: libraryRoot) { _ in
            XCTFail("A running CLI analysis must block cleanup")
        })
        XCTAssertEqual(flock(held, LOCK_UN), 0)

        try ManagedStorage.withExclusiveAccess(recording: recording, root: libraryRoot) { _ in
            XCTAssertNotEqual(flock(held, LOCK_EX | LOCK_NB), 0, "The lock must remain held inside the Trash callback")
        }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0, "The callback must release its lease")
        XCTAssertEqual(flock(held, LOCK_UN), 0)
    }

    func testCallbackFailureReleasesLeaseAndDanglingCacheLinkIsNeverFollowed() throws {
        let recording = try makeRecording()
        enum Deliberate: Error { case failure }
        XCTAssertThrowsError(try ManagedStorage.withExclusiveAccess(recording: recording, root: libraryRoot) { _ in
            throw Deliberate.failure
        })
        XCTAssertNoThrow(try ManagedStorage.withExclusiveAccess(recording: recording, root: libraryRoot) { _ in })
        let cache = recording.directory.appendingPathComponent(".zebtrace-analysis")
        try FileManager.default.removeItem(at: cache)
        let missing = temporaryRoot.appendingPathComponent("must-not-be-created")
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: missing)
        XCTAssertThrowsError(try ManagedStorage.withExclusiveAccess(recording: recording, root: libraryRoot) { _ in
            XCTFail("A dangling cache link must not be followed")
        })
        XCTAssertTrue(try ManagedStorage.generatedURLsForTrash(recording: recording, root: libraryRoot).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: cache.path), missing.path)
    }

    func testMissingRootHasEmptyInventoryWithoutCreatingIt() throws {
        let missing = temporaryRoot.appendingPathComponent("missing")
        XCTAssertEqual(try ManagedStorage.inventory(root: missing).recordingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testLibraryProvenanceRejectsCrossSessionAndChangedTranscriptResults() throws {
        let recording = try makeRecording()
        let transcript = Data("Meeting evidence".utf8)
        let summary = Data("## Overview\n\nMeeting summary".utf8)
        try transcript.write(to: recording.directory.appendingPathComponent("transcript.md"))
        try summary.write(to: recording.directory.appendingPathComponent("summary.md"))
        var metadata: [String: Any] = [
            "sessionID": UUID().uuidString, "status": "completed",
            "sourceManifestSHA256": AnalysisFiles.digest(try Data(contentsOf: recording.directory.appendingPathComponent("session.json"))),
            "transcriptContentSHA256": AnalysisFiles.digest(transcript),
            "summaryContentSHA256": AnalysisFiles.digest(summary)
        ]
        let metadataURL = recording.directory.appendingPathComponent("analysis.json")
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        var details = try RecordingLibrary.loadDetails(recording: recording)
        XCTAssertEqual(details.resultStatus, .unavailable)
        XCTAssertNil(details.summary)
        XCTAssertNil(details.transcript)

        metadata["sessionID"] = recording.id.uuidString
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        details = try RecordingLibrary.loadDetails(recording: recording)
        XCTAssertEqual(details.resultStatus, .ready)
        XCTAssertEqual(details.summary, String(data: summary, encoding: .utf8))

        try write("a different transcript", at: recording.directory.appendingPathComponent("transcript.md"))
        details = try RecordingLibrary.loadDetails(recording: recording)
        XCTAssertEqual(details.resultStatus, .unavailable)
        XCTAssertNil(details.summary, "A previous summary must not be paired with replaced evidence")
        XCTAssertNil(details.transcript)
    }

    private func makeRecording() throws -> LibraryRecording {
        let writer = try SessionWriter(root: libraryRoot, startedAt: Date(timeIntervalSince1970: 1_788_604_800))
        try writer.finish()
        try mutateManifest(in: writer.directory) {
            $0["chunks"] = [["source": "system", "file": "system-0001.m4a", "startOffsetSeconds": 0,
                             "durationSeconds": 1, "sampleRate": 16000, "channels": 1,
                             "frameCount": 16000, "finalized": true]]
        }
        return try RecordingLibrary.recording(at: writer.directory)
    }

    private func mutateManifest(in directory: URL, body: (inout [String: Any]) -> Void) throws {
        let url = directory.appendingPathComponent("session.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        body(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
    }

    private func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
