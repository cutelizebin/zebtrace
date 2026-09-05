import AVFoundation
import Foundation
import XCTest
@testable import ZebTraceCore

final class RecordingLocationTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaultDirectory: URL!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTraceLocationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defaultDirectory = temporaryRoot.appendingPathComponent("default-recordings", isDirectory: true)
        defaultsSuite = "org.zebtrace.tests.recording-location.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    override func tearDownWithError() throws {
        if let defaultsSuite { defaults?.removePersistentDomain(forName: defaultsSuite) }
        defaults = nil
        defaultsSuite = nil
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
        defaultDirectory = nil
    }

    func testDefaultDirectoryIsCreatedOnlyWhenPreparingToRecord() throws {
        let location = makeLocation()
        XCTAssertFalse(location.hasCustomDirectory)
        assertSameDirectory(location.directory, defaultDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultDirectory.path))

        assertSameDirectory(try location.prepareForRecording(), defaultDirectory)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(location.hasCustomDirectory)
    }

    func testSelectedDirectoryPersistsAcrossNewInstances() throws {
        let selected = try createDirectory("selected-recordings")
        let location = makeLocation()
        try location.select(selected)
        XCTAssertTrue(location.hasCustomDirectory)
        assertSameDirectory(location.directory, selected)

        // Read through a separate defaults instance, as the next app launch would.
        let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let reloaded = RecordingLocation(defaults: reloadedDefaults, defaultDirectory: defaultDirectory)
        XCTAssertTrue(reloaded.hasCustomDirectory)
        assertSameDirectory(reloaded.directory, selected)
        assertSameDirectory(try reloaded.prepareForRecording(), selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultDirectory.path))
    }

    func testSessionWriterPersistsActualAudioInsideSelectedDirectory() throws {
        let selected = try createDirectory("selected-recordings")
        let location = makeLocation()
        try location.select(selected)
        let origin = mach_absolute_time()
        let writer = try SessionWriter(root: location.prepareForRecording(), hostTimeOrigin: origin)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600))
        buffer.frameLength = 9_600
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Float(0.4 * sin(2 * .pi * 440 * Double(frame) / 48_000))
        }
        try writer.append(buffer, source: .microphone, hostTime: origin)
        try writer.finish()

        assertSameDirectory(writer.directory.deletingLastPathComponent().deletingLastPathComponent(), selected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.directory.appendingPathComponent("session.json").path))
        let chunk = try XCTUnwrap(writer.manifest.chunks.first)
        let audio = try AVAudioFile(forReading: writer.directory.appendingPathComponent(chunk.file))
        XCTAssertGreaterThan(audio.length, 0)
        XCTAssertEqual(chunk.frameCount, 9_600)
        XCTAssertTrue(chunk.finalized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultDirectory.path))
    }

    func testInvalidSelectionLeavesPreviouslySelectedDirectoryPersisted() throws {
        let selected = try createDirectory("selected-recordings")
        let location = makeLocation()
        try location.select(selected)
        let missing = temporaryRoot.appendingPathComponent("missing-selection", isDirectory: true)
        let regularFile = temporaryRoot.appendingPathComponent("not-a-directory")
        let fileContents = Data("Keep this file unchanged.".utf8)
        try fileContents.write(to: regularFile)

        for invalid in [missing, regularFile] {
            XCTAssertThrowsError(try location.select(invalid))
            XCTAssertTrue(location.hasCustomDirectory)
            assertSameDirectory(location.directory, selected)
            assertSameDirectory(makeLocation().directory, selected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(try Data(contentsOf: regularFile), fileContents)
        assertSameDirectory(try location.prepareForRecording(), selected)
    }

    func testDeletedCustomDirectoryIsNotRecreatedOrReplacedWithDefault() throws {
        let selected = try createDirectory("selected-recordings")
        try makeLocation().select(selected)
        try FileManager.default.removeItem(at: selected)
        let reloaded = makeLocation()

        XCTAssertTrue(reloaded.hasCustomDirectory)
        assertSameDirectory(reloaded.directory, selected)
        XCTAssertThrowsError(try reloaded.prepareForRecording())
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultDirectory.path))
        assertSameDirectory(makeLocation().directory, selected)
    }

    func testUnwritableSelectionDoesNotReplacePreviousDirectory() throws {
        let selected = try createDirectory("selected-recordings")
        let unwritable = try createDirectory("read-only-recordings")
        let location = makeLocation()
        try location.select(selected)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unwritable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unwritable.path)
        }
        guard !FileManager.default.isWritableFile(atPath: unwritable.path) else {
            throw XCTSkip("This user can bypass POSIX write restrictions.")
        }

        XCTAssertThrowsError(try location.select(unwritable))
        assertSameDirectory(location.directory, selected)
        assertSameDirectory(makeLocation().directory, selected)
        assertSameDirectory(try location.prepareForRecording(), selected)
    }

    func testCustomDirectoryReplacedByFileIsNotOverwritten() throws {
        let selected = try createDirectory("selected-recordings")
        let location = makeLocation()
        try location.select(selected)
        try FileManager.default.removeItem(at: selected)
        let fileContents = Data("Unrelated file now occupies the chosen path.".utf8)
        try fileContents.write(to: selected)

        XCTAssertThrowsError(try location.prepareForRecording())
        XCTAssertEqual(try Data(contentsOf: selected), fileContents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultDirectory.path))
        XCTAssertTrue(location.hasCustomDirectory)
    }

    func testDefaultDirectoryOccupiedByFileFailsWithoutOverwritingIt() throws {
        let fileContents = Data("An existing document must survive.".utf8)
        try fileContents.write(to: defaultDirectory)
        let location = makeLocation()

        XCTAssertThrowsError(try location.prepareForRecording())
        XCTAssertEqual(try Data(contentsOf: defaultDirectory), fileContents)
        XCTAssertFalse(location.hasCustomDirectory)
    }

    private func makeLocation() -> RecordingLocation {
        RecordingLocation(defaults: defaults, defaultDirectory: defaultDirectory)
    }

    private func createDirectory(_ name: String) throws -> URL {
        let directory = temporaryRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertSameDirectory(_ actual: URL, _ expected: URL,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.standardizedFileURL.resolvingSymlinksInPath().path,
                       expected.standardizedFileURL.resolvingSymlinksInPath().path,
                       file: file, line: line)
    }
}
