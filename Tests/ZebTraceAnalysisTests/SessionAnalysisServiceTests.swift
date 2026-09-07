import AVFoundation
import Foundation
import XCTest
import ZebTraceCore
@testable import ZebTraceAnalysis

final class SessionAnalysisServiceTests: XCTestCase {
    private var temporaryRoot: URL!
    private var configuration: AnalysisConfiguration!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTraceAnalysisTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let runtime = temporaryRoot.appendingPathComponent("fake-runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("{\"fixture\":1}".utf8).write(to: runtime.appendingPathComponent("runtime-info.json"))
        let asr = temporaryRoot.appendingPathComponent("fake-asr.bin")
        let summary = temporaryRoot.appendingPathComponent("fake-summary.gguf")
        try Data("test speech model identity".utf8).write(to: asr)
        try Data("test summary model identity".utf8).write(to: summary)
        configuration = .init(runtimeDirectory: runtime, asrModelURL: asr, summaryModelURL: summary, language: "en")
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
        configuration = nil
    }

    func testDualTrackOffsetsNormalizedAudioOutputsAndCacheReuse() async throws {
        let fixture = try makeSession()
        let speech = FakeSpeech()
        let summary = FakeSummary()
        let service = SessionAnalysisService(speech: speech, summary: summary)
        let result = try await service.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }

        let observations = await speech.observations
        XCTAssertEqual(observations.count, 2)
        for observation in observations {
            XCTAssertEqual(observation.sampleRate, 16_000)
            XCTAssertEqual(observation.channels, 1)
            XCTAssertGreaterThan(observation.frames, 0)
        }
        let entries = try transcript(in: fixture.directory)
        XCTAssertEqual(entries.map(\.source), ["system", "microphone"])
        XCTAssertEqual(entries[0].start, 0.35, accuracy: 0.000_01)
        XCTAssertEqual(entries[0].end, 0.55, accuracy: 0.000_01)
        XCTAssertEqual(entries[1].start, 2.6, accuracy: 0.000_01)
        XCTAssertEqual(entries[1].end, 2.8, accuracy: 0.000_01)
        let transcriptText = try String(contentsOf: result.transcriptURL, encoding: .utf8)
        XCTAssertTrue(transcriptText.contains("[00:00:02] [\(L10n.string("source.microphone", language: .english))]"))
        XCTAssertTrue(transcriptText.contains(FakeSpeech.text))
        let summaryText = try String(contentsOf: result.summaryURL, encoding: .utf8)
        XCTAssertTrue(summaryText.contains("## Overview"))
        XCTAssertTrue(summaryText.contains("[Read transcript](transcript.md)"))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            fixture.directory.appendingPathComponent("analysis.json"))) as? [String: Any])
        XCTAssertEqual(metadata["status"] as? String, "completed")
        XCTAssertEqual(metadata["sessionID"] as? String, fixture.manifest.id.uuidString)
        XCTAssertEqual((metadata["audioSHA256"] as? [String: String])?.count, 2)

        _ = try await service.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }
        let cachedSpeechCalls = await speech.observations.count
        let cachedSummaryCalls = await summary.calls.count
        XCTAssertEqual(cachedSpeechCalls, 2)
        XCTAssertEqual(cachedSummaryCalls, 1)
        try assertNoScratchDirectories(in: fixture.directory)

        // Model identity changes must invalidate derived ASR, even when audio paths are unchanged.
        try Data("a different test speech model".utf8).write(to: configuration.asrModelURL)
        _ = try await service.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }
        let refreshedSpeechCalls = await speech.observations.count
        XCTAssertEqual(refreshedSpeechCalls, 4)
    }

    func testSmallNegativeRecordingOffsetIsPreserved() async throws {
        let fixture = try makeSession(systemOffset: -0.05)
        let service = SessionAnalysisService(speech: FakeSpeech(), summary: FakeSummary())
        _ = try await service.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }
        XCTAssertEqual(try transcript(in: fixture.directory)[0].start, 0.05, accuracy: 0.000_01)
    }

    func testCrashScratchCleanupPreservesUnknownContentAndSymbolicLinks() async throws {
        let fixture = try makeSession()
        let cache = fixture.directory.appendingPathComponent(".zebtrace-analysis")
        let manager = FileManager.default
        func folder(_ name: String) throws -> URL {
            let directory = cache.appendingPathComponent(name)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let owned = try folder("work-\(UUID().uuidString)")
        let ownedEmpty = try folder("work-\(UUID().uuidString)")
        for name in ["chunk.wav", "window.wav", "\(UUID().uuidString).json",
                     "\(UUID().uuidString).prompt.txt", "\(UUID().uuidString).stdout",
                     "\(UUID().uuidString).stderr"] {
            try Data("stale derived data".utf8).write(to: owned.appendingPathComponent(name))
        }

        let notes = try folder("work-notes")
        let unknown = try folder("work-\(UUID().uuidString)")
        let nested = try folder("work-\(UUID().uuidString)")
        try manager.createDirectory(at: nested.appendingPathComponent("chunk.wav"), withIntermediateDirectories: false)
        let namedFile = cache.appendingPathComponent("work-\(UUID().uuidString)")
        let external = temporaryRoot.appendingPathComponent("external-scratch-target")
        try manager.createDirectory(at: external, withIntermediateDirectories: false)
        let keptFiles = [notes.appendingPathComponent("chunk.wav"), unknown.appendingPathComponent("notes.txt"),
                         unknown.appendingPathComponent("window.wav"), nested.appendingPathComponent("chunk.wav/notes.txt"),
                         namedFile, external.appendingPathComponent("window.wav")]
        let keptBytes = Data("user-owned content must remain unchanged".utf8)
        for file in keptFiles { try keptBytes.write(to: file) }

        let linkedDirectory = cache.appendingPathComponent("work-\(UUID().uuidString)")
        let danglingDirectory = cache.appendingPathComponent("work-\(UUID().uuidString)")
        let innerLinkDirectory = try folder("work-\(UUID().uuidString)")
        let innerLink = innerLinkDirectory.appendingPathComponent("window.wav")
        let links = [(linkedDirectory, external),
                     (danglingDirectory, temporaryRoot.appendingPathComponent("missing-scratch-target")),
                     (innerLink, external.appendingPathComponent("window.wav"))]
        for (link, target) in links { try manager.createSymbolicLink(at: link, withDestinationURL: target) }
        let originalDestinations = try links.map { try manager.destinationOfSymbolicLink(atPath: $0.0.path) }

        let result = try await SessionAnalysisService(speech: FakeSpeech(), summary: FakeSummary())
            .analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }

        XCTAssertTrue(manager.fileExists(atPath: result.summaryURL.path), "Preserved unknown content must not block analysis")
        XCTAssertFalse(manager.fileExists(atPath: owned.path))
        XCTAssertFalse(manager.fileExists(atPath: ownedEmpty.path))
        for file in keptFiles { XCTAssertEqual(try Data(contentsOf: file), keptBytes, file.path) }
        for (index, pair) in links.enumerated() {
            XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: pair.0.path), originalDestinations[index])
        }
        let remainingWork = try manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("work-") }
        XCTAssertEqual(Set(remainingWork.map(\.lastPathComponent)),
                       Set([notes, unknown, nested, namedFile, linkedDirectory, danglingDirectory, innerLinkDirectory]
                        .map(\.lastPathComponent)))
    }

    func testNoRecognizedSpeechPreservesAudioAndTimingWithoutInvokingSummary() async throws {
        // A non-speech tone and digital silence are both valid recordings.
        // ASR returning no words must not erase their audio or timeline.
        for silent in [false, true] {
            for language in [AppLanguage.english, .chinese] {
                let fixture = try makeSession(silent: silent)
                let originals = try Dictionary(uniqueKeysWithValues:
                    (["session.json"] + fixture.manifest.chunks.map(\.file)).map { name in
                        (name, try Data(contentsOf: fixture.directory.appendingPathComponent(name)))
                    })
                let speech = EmptySpeech()
                let summary = FakeSummary()
                let configuration = AnalysisConfiguration(runtimeDirectory: self.configuration.runtimeDirectory,
                    asrModelURL: self.configuration.asrModelURL, summaryModelURL: self.configuration.summaryModelURL,
                    language: language == .english ? "en" : "zh")
                let result = try await SessionAnalysisService(speech: speech, summary: summary)
                    .analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }

                XCTAssertTrue(try transcript(in: fixture.directory).isEmpty)
                let speechCalls = await speech.calls
                let summaryCalls = await summary.calls.count
                XCTAssertEqual(speechCalls, silent ? 0 : 2)
                XCTAssertEqual(summaryCalls, 0, "Do not ask the summary model to invent content without recognized speech")
                let summaryText = try String(contentsOf: result.summaryURL, encoding: .utf8)
                XCTAssertTrue(summaryText.contains(L10n.string("review.summary.empty", language: language)))
                for (name, original) in originals {
                    XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent(name)), original,
                                   "No recognized speech must not change \(name)")
                }
                try assertNoScratchDirectories(in: fixture.directory)
            }
        }
    }

    func testSummaryFailurePreservesTranscriptAndRetryReusesCompletedTranscription() async throws {
        let fixture = try makeSession()
        let speech = FakeSpeech()
        let failing = SessionAnalysisService(speech: speech, summary: FakeSummary(shouldFail: true))
        do {
            _ = try await failing.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }
            XCTFail("Expected the fake summary failure")
        } catch let error as AnalysisFailure {
            XCTAssertEqual(error.message, "Deliberate summary failure")
        }
        let transcriptURL = fixture.directory.appendingPathComponent("transcript.md")
        let preservedTranscript = try Data(contentsOf: transcriptURL)
        XCTAssertEqual(try transcript(in: fixture.directory).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("summary.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("analysis.json").path))
        try assertNoScratchDirectories(in: fixture.directory)

        let summary = FakeSummary()
        let retry = SessionAnalysisService(speech: speech, summary: summary)
        _ = try await retry.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }
        let speechCalls = await speech.observations.count
        let summaryCalls = await summary.calls.count
        XCTAssertEqual(speechCalls, 2)
        XCTAssertEqual(summaryCalls, 1)
        XCTAssertEqual(try Data(contentsOf: transcriptURL), preservedTranscript)
    }

    func testFailedResummaryArchivesThePreviousReviewWithoutLeavingStalePublishedResults() async throws {
        let fixture = try makeSession()
        let speech = FakeSpeech()
        let initial = SessionAnalysisService(speech: speech, summary: FakeSummary())
        _ = try await initial.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }
        let summaryURL = fixture.directory.appendingPathComponent("summary.md")
        let metadataURL = fixture.directory.appendingPathComponent("analysis.json")
        let previousSummary = try Data(contentsOf: summaryURL)
        let previousMetadata = try Data(contentsOf: metadataURL)
        // A new summarizer identity ensures the failed retry cannot use cached notes.
        try Data("a different test summary model".utf8).write(to: configuration.summaryModelURL)
        let retry = SessionAnalysisService(speech: speech, summary: FakeSummary(shouldFail: true))
        do {
            _ = try await retry.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }
            XCTFail("Expected the resummary failure")
        } catch let error as AnalysisFailure {
            XCTAssertEqual(error.message, "Deliberate summary failure")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: summaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertEqual(try transcript(in: fixture.directory).count, 2)
        let archive = fixture.directory.appendingPathComponent(".zebtrace-analysis/previous-review")
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("summary.md")), previousSummary)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("analysis.json")), previousMetadata)
    }

    func testCancellationKeepsCompletedChunkCacheAndResumeOnlyTranscribesRemainingChunk() async throws {
        let fixture = try makeSession()
        let secondChunkEntered = expectation(description: "Second transcription is waiting")
        let speech = FakeSpeech(blockOnCall: 2) { secondChunkEntered.fulfill() }
        let summary = FakeSummary()
        let service = SessionAnalysisService(speech: speech, summary: summary)
        let config = try XCTUnwrap(configuration)
        let task = Task {
            try await service.analyze(sessionDirectory: fixture.directory, configuration: config) { _ in }
        }
        await fulfillment(of: [secondChunkEntered], timeout: 10)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected cancellation result: \(error)") }

        let cache = fixture.directory.appendingPathComponent(".zebtrace-analysis")
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        XCTAssertEqual(cacheFiles.filter { $0.lastPathComponent.hasPrefix("asr-") }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("summary.md").path))
        try assertNoScratchDirectories(in: fixture.directory)

        let remainingSpeech = FakeSpeech()
        let retry = SessionAnalysisService(speech: remainingSpeech, summary: summary)
        _ = try await retry.analyze(sessionDirectory: fixture.directory, configuration: config) { _ in }
        let resumedCalls = await remainingSpeech.observations.count
        let summaryCalls = await summary.calls.count
        XCTAssertEqual(resumedCalls, 1)
        XCTAssertEqual(summaryCalls, 1)
        XCTAssertEqual(try transcript(in: fixture.directory).count, 2)
    }

    func testInvalidCachedTimestampsAreDiscardedAndTranscribedAgain() async throws {
        let fixture = try makeSession()
        let speech = FakeSpeech()
        let service = SessionAnalysisService(speech: speech, summary: FakeSummary())
        _ = try await service.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }
        let cache = fixture.directory.appendingPathComponent(".zebtrace-analysis")
        let cached = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("asr-") })
        var corrupted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cached)) as? [[String: Any]])
        let start = try XCTUnwrap(corrupted[0]["start"] as? Double)
        corrupted[0]["end"] = start - 1
        try JSONSerialization.data(withJSONObject: corrupted).write(to: cached)
        // An intact window cache can legitimately rebuild a corrupt full-chunk cache.
        // Remove those derived windows to exercise a required provider retry here.
        for window in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
            where window.lastPathComponent.hasPrefix("window-") {
            try FileManager.default.removeItem(at: window)
        }

        _ = try await service.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }
        let callCount = await speech.observations.count
        XCTAssertEqual(callCount, 3, "Invalid cached timestamps must not bypass provider validation")
        XCTAssertTrue(try transcript(in: fixture.directory).allSatisfy { $0.end >= $0.start })
    }

    func testIncompleteSessionsAndTraversalFilenamesAreRejectedBeforeProvidersRun() async throws {
        let fixture = try makeSession()
        let speech = FakeSpeech()
        let summary = FakeSummary()
        let service = SessionAnalysisService(speech: speech, summary: summary)
        var invalid: [SessionManifest] = []
        for status in [SessionStatus.recording, .interrupted, .failed] {
            var manifest = fixture.manifest
            manifest.status = status
            invalid.append(manifest)
        }
        for path in ["../outside.m4a", "/tmp/outside.m4a", "nested/audio.m4a"] {
            var manifest = fixture.manifest
            manifest.chunks[0].file = path
            invalid.append(manifest)
        }
        var unfinalized = fixture.manifest
        unfinalized.chunks[0].finalized = false
        invalid.append(unfinalized)
        var noEnd = fixture.manifest
        noEnd.endedAt = nil
        invalid.append(noEnd)
        var duplicate = fixture.manifest
        duplicate.chunks[1].file = duplicate.chunks[0].file
        invalid.append(duplicate)
        for manifest in invalid {
            try write(manifest, in: fixture.directory)
            do {
                _ = try await service.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }
                XCTFail("Expected rejection of an invalid recording")
            } catch { XCTAssertTrue(error is AnalysisFailure) }
        }
        let speechCalls = await speech.observations.count
        let summaryCalls = await summary.calls.count
        XCTAssertEqual(speechCalls, 0)
        XCTAssertEqual(summaryCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(".zebtrace-analysis").path))
    }

    func testManifestAudioAndAnalysisDirectorySymlinksAreRejected() async throws {
        for kind in ["manifest", "audio", "cache"] {
            let fixture = try makeSession()
            let outside = temporaryRoot.appendingPathComponent("outside-\(UUID().uuidString)")
            let link: URL
            if kind == "cache" {
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
                link = fixture.directory.appendingPathComponent(".zebtrace-analysis")
            } else {
                link = fixture.directory.appendingPathComponent(kind == "manifest" ? "session.json" : fixture.manifest.chunks[0].file)
                try FileManager.default.moveItem(at: link, to: outside)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let originalDestination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            let speech = FakeSpeech()
            let service = SessionAnalysisService(speech: speech, summary: FakeSummary())
            do {
                _ = try await service.analyze(sessionDirectory: fixture.directory, configuration: configuration) { _ in }
                XCTFail("Expected rejection of \(kind) symlink")
            } catch { XCTAssertTrue(error is AnalysisFailure, "\(kind): \(error)") }
            let speechCalls = await speech.observations.count
            XCTAssertEqual(speechCalls, 0)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), originalDestination)
        }
    }

    private func makeSession(systemOffset: Double = 0.25, silent: Bool = false) throws -> (directory: URL, manifest: SessionManifest) {
        let origin = mach_absolute_time()
        let root = temporaryRoot.appendingPathComponent("recording-\(UUID().uuidString)", isDirectory: true)
        let writer = try SessionWriter(root: root, hostTimeOrigin: origin)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 19_200))
        buffer.frameLength = 19_200
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = silent ? 0 : Float(0.4 * sin(2 * .pi * 440 * Double(frame) / 48_000))
        }
        let systemTime = systemOffset >= 0 ? origin + AVAudioTime.hostTime(forSeconds: systemOffset)
            : origin - AVAudioTime.hostTime(forSeconds: -systemOffset)
        try writer.append(buffer, source: .system, hostTime: systemTime)
        try writer.append(buffer, source: .microphone, hostTime: origin + AVAudioTime.hostTime(forSeconds: 2.5))
        try writer.finish()
        return (writer.directory, writer.manifest)
    }

    private func transcript(in directory: URL) throws -> [TranscriptEntry] {
        try JSONDecoder().decode([TranscriptEntry].self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
    }

    private func write(_ manifest: SessionManifest, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("session.json"))
    }

    private func assertNoScratchDirectories(in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let cache = directory.appendingPathComponent(".zebtrace-analysis")
        let files = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasPrefix("work-") }, file: file, line: line)
    }
}

private actor EmptySpeech: TranscriptionProvider {
    private(set) var calls = 0

    func transcribe(audio: URL, workDirectory: URL) async throws -> [SpeechSegment] {
        calls += 1
        return []
    }
}

private actor FakeSpeech: TranscriptionProvider {
    struct Observation: Sendable {
        let sampleRate: Double
        let channels: UInt32
        let frames: Int64
    }
    static let text = "We agreed to review the implementation next Friday."
    private(set) var observations: [Observation] = []
    private let blockOnCall: Int?
    private let onBlocked: @Sendable () -> Void

    init(blockOnCall: Int? = nil, onBlocked: @escaping @Sendable () -> Void = {}) {
        self.blockOnCall = blockOnCall
        self.onBlocked = onBlocked
    }

    func transcribe(audio: URL, workDirectory: URL) async throws -> [SpeechSegment] {
        let file = try AVAudioFile(forReading: audio)
        observations.append(.init(sampleRate: file.processingFormat.sampleRate,
                                  channels: file.processingFormat.channelCount, frames: file.length))
        if observations.count == blockOnCall {
            onBlocked()
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        return [.init(start: 0.1, end: 0.3, text: Self.text)]
    }
}

private actor FakeSummary: SummarizationProvider {
    struct Call: Sendable { let text: String; let language: String; let combining: Bool }
    private(set) var calls: [Call] = []
    private let shouldFail: Bool

    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }

    func summarize(text: String, language: String, combiningNotes: Bool, workDirectory: URL) async throws -> String {
        calls.append(.init(text: text, language: language, combining: combiningNotes))
        if shouldFail { throw AnalysisFailure("Deliberate summary failure") }
        return "## Overview\n\nThe team agreed to review the implementation. [00:00:02]"
    }
}
