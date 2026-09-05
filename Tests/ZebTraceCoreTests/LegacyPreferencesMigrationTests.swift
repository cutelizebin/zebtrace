import Foundation
import XCTest
@testable import ZebTraceCore

final class LegacyPreferencesMigrationTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private let directoryKey = "recordingsDirectoryPath"
    private let durationKey = "recordingSegmentLengthSeconds"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTraceMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defaultsSuite = "org.zebtrace.tests.legacy-migration.\(UUID().uuidString)"
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

    func testImportsOnlyKnownPreferencesWithoutMovingRecordings() throws {
        let selected = temporaryRoot.appendingPathComponent("MyContext custom folder", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let recording = selected.appendingPathComponent("existing-recording.m4a")
        let originalData = Data("Existing recording bytes must remain untouched.".utf8)
        try originalData.write(to: recording)
        let source: [String: Any] = [directoryKey: selected.path, durationKey: 1_800,
                                     "unrelatedPreference": "do not import"]

        XCTAssertEqual(LegacyPreferencesMigration.migrate(into: defaults, source: source),
                       [directoryKey, durationKey])
        XCTAssertEqual(defaults.string(forKey: directoryKey), selected.path)
        XCTAssertNil(defaults.object(forKey: "unrelatedPreference"))
        XCTAssertEqual(RecordingPreferences(defaults: defaults).segmentLength, .thirtyMinutes)
        let newDefault = temporaryRoot.appendingPathComponent("ZebTrace", isDirectory: true)
        let location = RecordingLocation(defaults: defaults, defaultDirectory: newDefault)
        XCTAssertTrue(location.hasCustomDirectory)
        XCTAssertEqual(location.directory.path, selected.path)
        XCTAssertEqual(try Data(contentsOf: recording), originalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDefault.path))
        XCTAssertEqual(source[directoryKey] as? String, selected.path)
    }

    func testUnavailableCustomDirectoryIsRememberedWithoutRecreatingIt() throws {
        let unavailable = temporaryRoot.appendingPathComponent("unmounted-external-recordings", isDirectory: true)
        let newDefault = temporaryRoot.appendingPathComponent("ZebTrace", isDirectory: true)

        XCTAssertEqual(LegacyPreferencesMigration.migrate(into: defaults, source: [directoryKey: unavailable.path]),
                       [directoryKey])
        let location = RecordingLocation(defaults: defaults, defaultDirectory: newDefault)
        XCTAssertTrue(location.hasCustomDirectory)
        XCTAssertEqual(location.directory.path, unavailable.path)
        XCTAssertThrowsError(try location.prepareForRecording())
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDefault.path))
    }

    func testExistingNewPreferencesAreNeverOverwritten() {
        let selected = temporaryRoot.appendingPathComponent("new-custom-recordings").path
        defaults.set(selected, forKey: directoryKey)
        defaults.set(300, forKey: durationKey)

        XCTAssertTrue(LegacyPreferencesMigration.migrate(
            into: defaults, source: [directoryKey: "/old/custom/recordings", durationKey: 3_600]).isEmpty)
        XCTAssertEqual(defaults.string(forKey: directoryKey), selected)
        XCTAssertEqual(RecordingPreferences(defaults: defaults).segmentLength, .fiveMinutes)
    }

    func testOnlyMissingPreferenceIsImported() {
        let selected = temporaryRoot.appendingPathComponent("new-custom-recordings").path
        defaults.set(selected, forKey: directoryKey)

        XCTAssertEqual(LegacyPreferencesMigration.migrate(
            into: defaults, source: [directoryKey: "/old/custom/recordings", durationKey: 3_600]), [durationKey])
        XCTAssertEqual(defaults.string(forKey: directoryKey), selected)
        XCTAssertEqual(RecordingPreferences(defaults: defaults).segmentLength, .sixtyMinutes)
    }

    func testMigrationDoesNotRunAgainAfterUserRemovesAnImportedPreference() throws {
        XCTAssertEqual(LegacyPreferencesMigration.migrate(into: defaults, source: [durationKey: 60]), [durationKey])
        defaults.removeObject(forKey: durationKey)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))

        XCTAssertTrue(LegacyPreferencesMigration.migrate(into: reloaded, source: [durationKey: 300]).isEmpty)
        XCTAssertNil(reloaded.object(forKey: durationKey))
        XCTAssertEqual(RecordingPreferences(defaults: reloaded).segmentLength, .tenMinutes)
    }

    func testEmptySourceCompletesTheOneTimeMigration() {
        XCTAssertTrue(LegacyPreferencesMigration.migrate(into: defaults, source: [:]).isEmpty)
        XCTAssertTrue(LegacyPreferencesMigration.migrate(into: defaults, source: [durationKey: 60]).isEmpty)
        XCTAssertNil(defaults.object(forKey: durationKey))
    }

    func testInvalidLegacyDurationsAreNotPersisted() {
        let invalidValues: [Any] = [0, -60, 59, 601, 600.5, "600", true]
        for value in invalidValues {
            defaults.removePersistentDomain(forName: defaultsSuite)
            XCTAssertTrue(LegacyPreferencesMigration.migrate(into: defaults, source: [durationKey: value]).isEmpty,
                          "Unexpectedly imported invalid duration: \(value)")
            XCTAssertNil(defaults.object(forKey: durationKey))
            XCTAssertEqual(RecordingPreferences(defaults: defaults).segmentLength, .tenMinutes)
        }
    }

    func testAllSupportedDurationsCanBeMigrated() {
        for duration in RecordingSegmentLength.allCases {
            defaults.removePersistentDomain(forName: defaultsSuite)
            XCTAssertEqual(LegacyPreferencesMigration.migrate(into: defaults, source: [durationKey: duration.rawValue]),
                           [durationKey])
            XCTAssertEqual(RecordingPreferences(defaults: defaults).segmentLength, duration)
        }
    }

    func testMalformedLegacyPathsDoNotCreateCustomDirectoryPreference() {
        let invalidPaths: [Any] = [42, "", "relative/recordings", "~/recordings",
                                   "file:///tmp/recordings", "/tmp/invalid\0path"]
        for path in invalidPaths {
            defaults.removePersistentDomain(forName: defaultsSuite)
            XCTAssertTrue(LegacyPreferencesMigration.migrate(into: defaults, source: [directoryKey: path]).isEmpty)
            XCTAssertNil(defaults.object(forKey: directoryKey))
        }
    }
}
