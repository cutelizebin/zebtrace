import AVFoundation
import Foundation
import XCTest
@testable import ZebTraceCore

final class RecordingPipelineTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTracePipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
    }

    func testFailedFinalizationCannotBecomeSuccessOnRepeatedFinish() throws {
        let pipeline = try RecordingPipeline(root: temporaryRoot) { error in
            XCTFail("A finalization failure should arrive through completion: \(error)")
        }
        let manifestURL = pipeline.directory.appendingPathComponent("session.json")
        let savedCheckpoint = pipeline.directory.appendingPathComponent("previous-session.json")
        let originalData = try Data(contentsOf: manifestURL)
        try FileManager.default.moveItem(at: manifestURL, to: savedCheckpoint)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)

        let firstFailure = try failure(from: finish(pipeline)) as NSError
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.moveItem(at: savedCheckpoint, to: manifestURL)
        pipeline.append(try buffer(), source: .system, hostTime: mach_absolute_time())
        let secondFailure = try failure(from: finish(pipeline)) as NSError

        XCTAssertEqual(secondFailure.domain, firstFailure.domain)
        XCTAssertEqual(secondFailure.code, firstFailure.code)
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalData)
        XCTAssertTrue(pipeline.snapshot().isEmpty)
    }

    func testOverloadReportsOneErrorAndFinishesAsFailed() throws {
        var reportedErrors: [Error] = []
        // A zero-capacity queue deterministically rejects its first buffer without relying on scheduling.
        let pipeline = try RecordingPipeline(root: temporaryRoot, maximumPendingBuffers: 0) { error in
            reportedErrors.append(error)
        }
        for _ in 0..<3 {
            pipeline.append(try buffer(), source: .system, hostTime: mach_absolute_time())
        }
        let terminalError = try failure(from: finish(pipeline))
        guard case RecordingError.overloaded = terminalError else {
            return XCTFail("Expected overload failure, received \(terminalError)")
        }
        // The finish callback follows onError on the serial writer queue.
        XCTAssertEqual(reportedErrors.count, 1)
        guard case RecordingError.overloaded = try XCTUnwrap(reportedErrors.first) else {
            return XCTFail("Expected one overload notification")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SessionManifest.self, from: Data(contentsOf:
            pipeline.directory.appendingPathComponent("session.json")))
        XCTAssertEqual(manifest.status, .failed)
        XCTAssertEqual(manifest.endReason, "writeFailed")
        XCTAssertTrue(manifest.chunks.isEmpty)
        XCTAssertTrue(pipeline.snapshot().isEmpty)

        let repeatedError = try failure(from: finish(pipeline))
        guard case RecordingError.overloaded = repeatedError else {
            return XCTFail("Repeated finish should retain the overload error")
        }
        XCTAssertEqual(reportedErrors.count, 1)
    }

    private func finish(_ pipeline: RecordingPipeline) throws -> Result<URL, Error> {
        let completed = expectation(description: "Pipeline returns its terminal result")
        var result: Result<URL, Error>?
        pipeline.finish {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 10)
        return try XCTUnwrap(result)
    }

    private func failure(from result: Result<URL, Error>) throws -> Error {
        switch result {
        case let .failure(error): return error
        case .success:
            XCTFail("Expected terminal failure, received success")
            throw RecordingError.closed
        }
    }

    private func buffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<128 { samples[index] = 0.25 }
        return buffer
    }
}
