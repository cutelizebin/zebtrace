import AVFoundation
import Foundation
import XCTest
@testable import ZebTraceCore

final class SessionWriterTests: XCTestCase {
    private var temporaryRoot: URL!
    private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = AVAudioTime.hostTime(forSeconds: 120)

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTraceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
    }

    func testBothSourcesProduceDecodableNonSilentAAC() throws {
        let writer = try makeWriter()
        try writer.append(tone(channels: 2, interleaved: true), source: .system, hostTime: time(0))
        try writer.append(tone(frequency: 880), source: .microphone, hostTime: time(0.15))
        try writer.finish(at: startedAt.addingTimeInterval(1))

        let manifest = try readManifest(in: writer.directory)
        XCTAssertEqual(manifest.chunks.count, 2)
        XCTAssertEqual(Set(manifest.chunks.map(\.source)), Set(AudioSource.allCases))
        for chunk in manifest.chunks {
            XCTAssertTrue(chunk.finalized)
            XCTAssertEqual(chunk.frameCount, 9_600)
            XCTAssertEqual(chunk.durationSeconds, 0.2, accuracy: 0.000_001)
            try assertDecodableTone(chunk, in: writer.directory)
        }
    }

    func testRotationPreservesEveryFrameAndFinalizesEveryChunk() throws {
        let writer = try makeWriter(chunkDuration: 0.4)
        for index in 0..<5 {
            try writer.append(tone(), source: .system, hostTime: time(Double(index) * 0.2))
        }
        try writer.finish(at: startedAt.addingTimeInterval(1))

        let manifest = try readManifest(in: writer.directory)
        XCTAssertEqual(manifest.chunks.map(\.frameCount), [19_200, 19_200, 9_600])
        XCTAssertEqual(Set(manifest.chunks.map(\.file)).count, 3)
        XCTAssertEqual(manifest.chunks.map(\.frameCount).reduce(0, +), 48_000)
        for (chunk, expectedOffset) in zip(manifest.chunks, [0.0, 0.4, 0.8]) {
            XCTAssertEqual(chunk.startOffsetSeconds, expectedOffset, accuracy: 0.000_001)
            XCTAssertTrue(chunk.finalized)
            try assertDecodableTone(chunk, in: writer.directory)
        }
    }

    func testSourceOffsetsAndTimestampGapsSurvivePersistence() throws {
        let writer = try makeWriter()
        try writer.append(tone(), source: .system, hostTime: time(1.25))
        let latestUpdate = writer.manifest.updatedAt
        // The sources can arrive out of timestamp order on different callback queues.
        try writer.append(tone(), source: .microphone, hostTime: time(0.3))
        XCTAssertGreaterThanOrEqual(writer.manifest.updatedAt, latestUpdate)
        try writer.append(tone(), source: .system, hostTime: time(1.45))
        try writer.append(tone(), source: .microphone, hostTime: time(3))
        try writer.finish(at: startedAt.addingTimeInterval(4))

        let manifest = try readManifest(in: writer.directory)
        let system = manifest.chunks.filter { $0.source == .system }
        let microphone = manifest.chunks.filter { $0.source == .microphone }
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(microphone.count, 2)
        XCTAssertEqual(try XCTUnwrap(system.first).startOffsetSeconds, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(system.first).durationSeconds, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(microphone[0].startOffsetSeconds, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(microphone[1].startOffsetSeconds, 3, accuracy: 0.000_001)
        let preservedGap = microphone[1].startOffsetSeconds
            - microphone[0].startOffsetSeconds - microphone[0].durationSeconds
        XCTAssertEqual(preservedGap, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(microphone.map(\.durationSeconds).reduce(0, +), 0.4, accuracy: 0.000_001)
    }

    func testFormatChangeStartsASeparatelyDecodableFile() throws {
        let writer = try makeWriter()
        try writer.append(tone(), source: .system, hostTime: time(0))
        try writer.append(tone(sampleRate: 44_100, channels: 2), source: .system, hostTime: time(0.2))
        try writer.finish(at: startedAt.addingTimeInterval(1))

        let chunks = try readManifest(in: writer.directory).chunks
        XCTAssertEqual(chunks.map(\.sampleRate), [48_000, 44_100])
        XCTAssertEqual(chunks.map(\.channels), [1, 2])
        for chunk in chunks { try assertDecodableTone(chunk, in: writer.directory) }
    }

    func testFinishSealsFilesAndRejectsSubsequentWrites() throws {
        let writer = try makeWriter()
        try writer.append(tone(), source: .microphone, hostTime: time(0))
        let endedAt = startedAt.addingTimeInterval(1)
        try writer.finish(reason: "userPaused", at: endedAt)
        let manifestURL = writer.directory.appendingPathComponent("session.json")
        let sealedJSON = try Data(contentsOf: manifestURL)
        let chunk = try XCTUnwrap(writer.manifest.chunks.first)
        let audioURL = writer.directory.appendingPathComponent(chunk.file)
        let sealedAudio = try Data(contentsOf: audioURL)

        XCTAssertThrowsError(try writer.append(tone(), source: .system, hostTime: time(1))) { error in
            guard case RecordingError.closed = error else {
                return XCTFail("Expected a closed recording error, received \(error)")
            }
        }
        // Repeated shutdown requests must preserve the original result.
        try writer.finish(status: .failed, reason: "laterFailure", at: endedAt.addingTimeInterval(30))
        XCTAssertEqual(try Data(contentsOf: manifestURL), sealedJSON)
        XCTAssertEqual(try Data(contentsOf: audioURL), sealedAudio)
        XCTAssertEqual(writer.manifest.status, .completed)
        XCTAssertEqual(writer.manifest.endedAt, endedAt)
        try assertDecodableTone(chunk, in: writer.directory)
    }

    func testFailedFinalCheckpointRemainsAFailureOnRepeatedFinish() throws {
        let writer = try makeWriter()
        try writer.append(tone(), source: .microphone, hostTime: time(0))
        let manifestURL = writer.directory.appendingPathComponent("session.json")
        let savedCheckpoint = writer.directory.appendingPathComponent("previous-session.json")
        let originalData = try Data(contentsOf: manifestURL)
        try FileManager.default.moveItem(at: manifestURL, to: savedCheckpoint)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)

        var firstFailure: NSError?
        XCTAssertThrowsError(try writer.finish(at: startedAt.addingTimeInterval(1))) {
            firstFailure = $0 as NSError
        }
        let initialFailure = try XCTUnwrap(firstFailure)
        // Even if storage becomes writable again, a repeated finish must preserve its terminal result.
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.moveItem(at: savedCheckpoint, to: manifestURL)
        XCTAssertThrowsError(try writer.finish(at: startedAt.addingTimeInterval(2))) { error in
            XCTAssertEqual((error as NSError).domain, initialFailure.domain)
            XCTAssertEqual((error as NSError).code, initialFailure.code)
        }
        XCTAssertThrowsError(try writer.append(tone(), source: .system, hostTime: time(2))) { error in
            guard case RecordingError.closed = error else {
                return XCTFail("Expected a closed recording error, received \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalData)
        try assertDecodableTone(try XCTUnwrap(writer.manifest.chunks.first), in: writer.directory)
    }

    func testSmallPreStartOffsetIsPreservedAndInvalidClockIsRejected() throws {
        let writer = try makeWriter()
        try writer.append(tone(), source: .microphone,
                          hostTime: origin - AVAudioTime.hostTime(forSeconds: 0.05))
        XCTAssertEqual(try XCTUnwrap(writer.manifest.chunks.first).startOffsetSeconds,
                       -0.05, accuracy: 0.000_001)
        XCTAssertThrowsError(try writer.append(tone(), source: .system,
                                               hostTime: origin - AVAudioTime.hostTime(forSeconds: 2))) { error in
            guard case RecordingError.clockBeforeSession = error else {
                return XCTFail("Expected an invalid clock error, received \(error)")
            }
        }
        try writer.finish(at: startedAt.addingTimeInterval(1))
        XCTAssertEqual(writer.manifest.chunks.count, 1)
    }

    func testManifestJSONRoundTripPreservesPortableTimingAndChunkState() throws {
        let chunk = AudioChunk(source: .microphone, file: "microphone-00001.m4a",
                               startOffsetSeconds: -0.125, durationSeconds: 12.25,
                               sampleRate: 48_000, channels: 1, frameCount: 588_000, finalized: false)
        let original = SessionManifest(id: UUID(), startedAt: startedAt,
                                       updatedAt: startedAt.addingTimeInterval(12),
                                       endedAt: startedAt.addingTimeInterval(13), status: .interrupted,
                                       endReason: "appInterrupted", chunkDurationSeconds: 60,
                                       hostTimeOrigin: 18_014_398_509_481_985,
                                       hostClockTicksPerSecond: 24_000_000, chunks: [chunk])
        let data = try manifestEncoder().encode(original)
        let decoded = try manifestDecoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.startedAt, original.startedAt)
        XCTAssertEqual(decoded.updatedAt, original.updatedAt)
        XCTAssertEqual(decoded.endedAt, original.endedAt)
        XCTAssertEqual(decoded.status, .interrupted)
        XCTAssertEqual(decoded.endReason, "appInterrupted")
        XCTAssertEqual(decoded.chunkDurationSeconds, 60)
        XCTAssertEqual(decoded.hostTimeOrigin, original.hostTimeOrigin)
        XCTAssertEqual(decoded.hostClockTicksPerSecond, 24_000_000)
        let decodedChunk = try XCTUnwrap(decoded.chunks.first)
        XCTAssertEqual(decodedChunk.source, chunk.source)
        XCTAssertEqual(decodedChunk.file, chunk.file)
        XCTAssertEqual(decodedChunk.startOffsetSeconds, chunk.startOffsetSeconds)
        XCTAssertEqual(decodedChunk.durationSeconds, chunk.durationSeconds)
        XCTAssertEqual(decodedChunk.sampleRate, chunk.sampleRate)
        XCTAssertEqual(decodedChunk.channels, chunk.channels)
        XCTAssertEqual(decodedChunk.frameCount, chunk.frameCount)
        XCTAssertFalse(decodedChunk.finalized)
    }

    func testRecoveryPreservesCompletedSessionsAndUnfinalizedChunkMarkers() throws {
        let completed = try makeWriter()
        try completed.append(tone(), source: .system, hostTime: time(0))
        try completed.finish(at: startedAt.addingTimeInterval(1))
        let completedURL = completed.directory.appendingPathComponent("session.json")
        let originalCompletedData = try Data(contentsOf: completedURL)

        // Model a crash using a persisted checkpoint, without keeping an active writer open.
        var interrupted = completed.manifest
        interrupted.id = UUID()
        interrupted.status = .recording
        interrupted.endedAt = nil
        interrupted.endReason = nil
        interrupted.updatedAt = startedAt.addingTimeInterval(7)
        var unfinished = try XCTUnwrap(interrupted.chunks.first)
        unfinished.file = "system-00002.m4a"
        unfinished.startOffsetSeconds = 6
        unfinished.frameCount = 0
        unfinished.durationSeconds = 0
        unfinished.finalized = false
        interrupted.chunks.append(unfinished)
        let interruptedDirectory = try makeRecoveryDirectory(id: interrupted.id)
        try manifestEncoder().encode(interrupted)
            .write(to: interruptedDirectory.appendingPathComponent("session.json"))

        XCTAssertEqual(try SessionWriter.recoverInterruptedSessions(at: temporaryRoot), 1)
        XCTAssertEqual(try Data(contentsOf: completedURL), originalCompletedData)
        let recovered = try readManifest(in: interruptedDirectory)
        XCTAssertEqual(recovered.status, .interrupted)
        XCTAssertEqual(recovered.endReason, "appInterrupted")
        XCTAssertEqual(recovered.endedAt, interrupted.updatedAt)
        XCTAssertEqual(recovered.chunks.count, 2)
        XCTAssertTrue(recovered.chunks[0].finalized)
        XCTAssertFalse(recovered.chunks[1].finalized)
        XCTAssertEqual(recovered.chunks[1].file, "system-00002.m4a")
        XCTAssertEqual(recovered.chunks[1].startOffsetSeconds, 6)
        XCTAssertEqual(recovered.chunks[1].frameCount, 0)
        XCTAssertEqual(try SessionWriter.recoverInterruptedSessions(at: temporaryRoot), 0)
    }

    func testPipelineFinishDrainsEveryAcceptedBufferBeforeCompleting() throws {
        let completed = expectation(description: "All accepted audio is sealed")
        let pipeline = try RecordingPipeline(root: temporaryRoot, maximumPendingBuffers: 128) { error in
            XCTFail("Unexpected pipeline error: \(error)")
        }
        let initial = try readManifest(in: pipeline.directory)
        let perSourceBufferCount = 24
        let framesPerBuffer: AVAudioFrameCount = 2_400
        for index in 0..<perSourceBufferCount {
            for source in AudioSource.allCases {
                pipeline.append(try tone(frames: framesPerBuffer), source: source,
                                hostTime: initial.hostTimeOrigin + AVAudioTime.hostTime(forSeconds: Double(index) * 0.05))
            }
        }
        pipeline.finish { result in
            switch result {
            case let .success(directory): XCTAssertEqual(directory, pipeline.directory)
            case let .failure(error): XCTFail("Finishing audio failed: \(error)")
            }
            completed.fulfill()
        }
        // This buffer arrives after the finish boundary and must not enter the session.
        pipeline.append(try tone(), source: .system,
                        hostTime: initial.hostTimeOrigin + AVAudioTime.hostTime(forSeconds: 4))
        wait(for: [completed], timeout: 15)

        let manifest = try readManifest(in: pipeline.directory)
        XCTAssertEqual(manifest.status, .completed)
        XCTAssertEqual(manifest.chunks.count, 2)
        for source in AudioSource.allCases {
            let chunks = manifest.chunks.filter { $0.source == source }
            XCTAssertEqual(chunks.map(\.frameCount).reduce(0, +),
                           UInt64(perSourceBufferCount) * UInt64(framesPerBuffer))
            XCTAssertEqual(pipeline.snapshot()[source]?.buffers, UInt64(perSourceBufferCount))
            XCTAssertGreaterThan(pipeline.snapshot()[source]?.peak ?? 0, 0.1)
            for chunk in chunks {
                XCTAssertTrue(chunk.finalized)
                try assertDecodableTone(chunk, in: pipeline.directory)
            }
        }
    }

    func testCorruptManifestIsReportedWithoutPreventingOtherSessionRecovery() throws {
        var manifests: [URL] = []
        for _ in 0..<3 {
            let checkpoint = recoveryCheckpoint()
            let directory = try makeRecoveryDirectory(id: checkpoint.id)
            let file = directory.appendingPathComponent("session.json")
            try manifestEncoder().encode(checkpoint).write(to: file)
            manifests.append(file)
        }
        XCTAssertEqual(manifests.count, 3)
        let corruptURL = try XCTUnwrap(manifests.first)
        let corruptData = Data("{\"schemaVersion\": 1, \"status\": \"recording\"".utf8)
        try corruptData.write(to: corruptURL)

        XCTAssertThrowsError(try SessionWriter.recoverInterruptedSessions(at: temporaryRoot))
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptData,
                       "Recovery must retain damaged metadata for diagnosis")
        for url in manifests where url != corruptURL {
            let recovered = try manifestDecoder().decode(SessionManifest.self, from: Data(contentsOf: url))
            XCTAssertEqual(recovered.status, .interrupted)
            XCTAssertEqual(recovered.endReason, "appInterrupted")
        }
    }

    func testRecoveryIgnoresUnrelatedJSONAndDirectoriesOutsideTheSessionLayout() throws {
        let checkpoint = recoveryCheckpoint()
        let knownSession = try makeRecoveryDirectory(id: checkpoint.id)
        try manifestEncoder().encode(checkpoint).write(to: knownSession.appendingPathComponent("session.json"))
        let unrelatedPaths = [
            "session.json",
            "project/session.json",
            "project/2026-09-05/12-00-00-\(UUID().uuidString)/session.json",
            "Example.app/Contents/session.json",
            "2026-09-05/session.json",
            "2026-09-05/other-session/session.json",
            "2026-09-05/25-00-00-\(UUID().uuidString)/session.json",
            "2026-02-30/12-00-00-\(UUID().uuidString)/session.json",
            "2026-09-05/12-00-00-\(UUID().uuidString)/nested/session.json",
        ]
        let unrelatedData = Data("{This unrelated JSON must never be parsed or rewritten.".utf8)
        let files = try unrelatedPaths.map { path -> URL in
            let file = temporaryRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try unrelatedData.write(to: file)
            return file
        }

        XCTAssertEqual(try SessionWriter.recoverInterruptedSessions(at: temporaryRoot), 1)
        XCTAssertEqual(try readManifest(in: knownSession).status, .interrupted)
        for file in files { XCTAssertEqual(try Data(contentsOf: file), unrelatedData) }
    }

    func testRecoveryRequiresMatchingDirectoryIDAndSupportedSchema() throws {
        var future = recoveryCheckpoint()
        future.schemaVersion = 2
        let mismatched = recoveryCheckpoint()
        let mismatchedDirectory = try makeRecoveryDirectory(id: UUID())
        let futureDirectory = try makeRecoveryDirectory(id: future.id)
        let samples = [(mismatchedDirectory, mismatched), (futureDirectory, future)]
        var originals: [URL: Data] = [:]
        for (directory, manifest) in samples {
            let file = directory.appendingPathComponent("session.json")
            let data = try manifestEncoder().encode(manifest)
            try data.write(to: file)
            originals[file] = data
        }

        XCTAssertEqual(try SessionWriter.recoverInterruptedSessions(at: temporaryRoot), 0)
        for (file, data) in originals { XCTAssertEqual(try Data(contentsOf: file), data) }
    }

    func testRecoveryDoesNotFollowDaySessionOrManifestSymlinks() throws {
        let manager = FileManager.default
        let outsideRoot = temporaryRoot.appendingPathComponent("unrelated-recordings", isDirectory: true)
        var externalSessions: [URL] = []
        var originals: [URL: Data] = [:]
        for _ in 0..<3 {
            let checkpoint = recoveryCheckpoint()
            let directory = try makeRecoveryDirectory(id: checkpoint.id, root: outsideRoot)
            let file = directory.appendingPathComponent("session.json")
            let data = try manifestEncoder().encode(checkpoint)
            try data.write(to: file)
            externalSessions.append(directory)
            originals[file] = data
        }
        // An otherwise valid date directory must not lead recovery into another tree.
        try manager.createSymbolicLink(at: temporaryRoot.appendingPathComponent("2026-09-06"),
                                       withDestinationURL: externalSessions[0].deletingLastPathComponent())
        let localDay = temporaryRoot.appendingPathComponent("2026-09-05", isDirectory: true)
        try manager.createDirectory(at: localDay, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: localDay.appendingPathComponent(externalSessions[1].lastPathComponent),
                                       withDestinationURL: externalSessions[1])
        let localSession = localDay.appendingPathComponent(externalSessions[2].lastPathComponent, isDirectory: true)
        try manager.createDirectory(at: localSession, withIntermediateDirectories: true)
        let manifestLink = localSession.appendingPathComponent("session.json")
        try manager.createSymbolicLink(at: manifestLink,
                                       withDestinationURL: externalSessions[2].appendingPathComponent("session.json"))

        XCTAssertEqual(try SessionWriter.recoverInterruptedSessions(at: temporaryRoot), 0)
        for (file, data) in originals { XCTAssertEqual(try Data(contentsOf: file), data) }
        XCTAssertTrue(try manifestLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    private func recoveryCheckpoint() -> SessionManifest {
        SessionManifest(id: UUID(), startedAt: startedAt, updatedAt: startedAt,
                        status: .recording, chunkDurationSeconds: 60, hostTimeOrigin: origin,
                        hostClockTicksPerSecond: 24_000_000, chunks: [])
    }

    private func makeRecoveryDirectory(id: UUID, root: URL? = nil) throws -> URL {
        let directory = (root ?? temporaryRoot).appendingPathComponent("2026-09-05", isDirectory: true)
            .appendingPathComponent("12-00-00-\(id.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeWriter(chunkDuration: Double = 60) throws -> SessionWriter {
        try SessionWriter(root: temporaryRoot, chunkDuration: chunkDuration,
                          startedAt: startedAt, hostTimeOrigin: origin)
    }

    private func time(_ seconds: Double) -> UInt64 {
        origin + AVAudioTime.hostTime(forSeconds: seconds)
    }

    private func tone(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1,
                      interleaved: Bool = false, frames: AVAudioFrameCount? = nil,
                      frequency: Double = 440) throws -> AVAudioPCMBuffer {
        let frameCount = frames ?? AVAudioFrameCount(sampleRate * 0.2)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: sampleRate, channels: channels,
                                               interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            let samples = interleaved ? data[0] + channel : data[channel]
            let stride = interleaved ? Int(channels) : 1
            for frame in 0..<Int(frameCount) {
                samples[frame * stride] = Float(0.4 * sin(2 * .pi * frequency * Double(frame) / sampleRate))
            }
        }
        return buffer
    }

    private func assertDecodableTone(_ chunk: AudioChunk, in directory: URL,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let url = directory.appendingPathComponent(chunk.file)
        XCTAssertEqual(url.pathExtension, "m4a", file: file, line: line)
        let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mFormatID,
                       kAudioFormatMPEG4AAC, file: file, line: line)
        XCTAssertEqual(audio.processingFormat.sampleRate, chunk.sampleRate, file: file, line: line)
        XCTAssertEqual(audio.processingFormat.channelCount, chunk.channels, file: file, line: line)
        let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(audio.length)),
                                   file: file, line: line)
        try audio.read(into: decoded)
        // AAC can add encoder priming/padding; reject truncated audio, allowing one AAC frame.
        XCTAssertEqual(Double(decoded.frameLength), Double(chunk.frameCount), accuracy: 1_024,
                       file: file, line: line)
        XCTAssertGreaterThan(decoded.frameLength, 0, file: file, line: line)
        let samples = try XCTUnwrap(decoded.floatChannelData, file: file, line: line)
        for channel in 0..<Int(chunk.channels) {
            var energy: Double = 0
            for frame in 0..<Int(decoded.frameLength) {
                let sample = Double(samples[channel][frame])
                XCTAssertTrue(sample.isFinite, file: file, line: line)
                energy += sample * sample
            }
            let rms = sqrt(energy / Double(max(1, decoded.frameLength)))
            XCTAssertGreaterThan(rms, 0.15, "Decoded channel should contain the generated tone", file: file, line: line)
            XCTAssertLessThan(rms, 0.4, "Decoded channel should preserve the tone amplitude", file: file, line: line)
        }
    }

    private func readManifest(in directory: URL) throws -> SessionManifest {
        try manifestDecoder().decode(SessionManifest.self,
                                     from: Data(contentsOf: directory.appendingPathComponent("session.json")))
    }

    private func manifestEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func manifestDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
