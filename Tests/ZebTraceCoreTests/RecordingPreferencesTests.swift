import Foundation
import XCTest
@testable import ZebTraceCore

final class RecordingPreferencesTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTracePreferencesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defaultsSuite = "org.zebtrace.tests.recording-preferences.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    override func tearDownWithError() throws {
        if let defaultsSuite { defaults?.removePersistentDomain(forName: defaultsSuite) }
        defaults = nil
        defaultsSuite = nil
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
    }

    func testNewPreferencesDefaultToTenMinutes() {
        let preferences = RecordingPreferences(defaults: defaults)
        XCTAssertEqual(preferences.segmentLength, .tenMinutes)
        XCTAssertEqual(preferences.segmentLength.rawValue, 600)
    }

    func testSupportedDurationsPersistAcrossNewInstances() throws {
        XCTAssertEqual(Set(RecordingSegmentLength.allCases.map(\.rawValue)), [60, 300, 600, 1_800, 3_600])
        let preferences = RecordingPreferences(defaults: defaults)
        for length in RecordingSegmentLength.allCases {
            preferences.segmentLength = length
            let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
            let reloaded = RecordingPreferences(defaults: reloadedDefaults)
            XCTAssertEqual(reloaded.segmentLength, length)
        }
    }

    func testSessionWriterUsesTenMinuteChunksByDefault() throws {
        let writer = try SessionWriter(root: temporaryRoot)
        XCTAssertEqual(writer.manifest.chunkDurationSeconds, 600)
        try writer.finish()

        let manifest = try readManifest(in: writer.directory)
        XCTAssertEqual(manifest.chunkDurationSeconds, 600)
        XCTAssertEqual(manifest.status, .completed)
    }

    func testRecordingPipelinePersistsTenMinuteDefault() throws {
        let finished = expectation(description: "Default pipeline finishes")
        let pipeline = try RecordingPipeline(root: temporaryRoot) { error in
            XCTFail("Unexpected pipeline error: \(error)")
        }
        XCTAssertEqual(try readManifest(in: pipeline.directory).chunkDurationSeconds, 600)
        pipeline.finish { result in
            if case let .failure(error) = result { XCTFail("Finishing pipeline failed: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)

        let manifest = try readManifest(in: pipeline.directory)
        XCTAssertEqual(manifest.chunkDurationSeconds, 600)
        XCTAssertEqual(manifest.status, .completed)
    }

    private func readManifest(in directory: URL) throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionManifest.self,
                                  from: Data(contentsOf: directory.appendingPathComponent("session.json")))
    }
}
