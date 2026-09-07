import Foundation
import XCTest
@testable import ZebTraceCore

final class SessionDirectoryTests: XCTestCase {
    private var temporaryRoot: URL!
    private var startedAt: Date!
    private let dayName = "2026-09-05"
    private let baseName = "2026-09-05_23-04-05"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTraceSessionDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        startedAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 5, hour: 23, minute: 4, second: 5)))
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
        startedAt = nil
    }

    func testDirectoryUsesFullLocalDateAnd24HourTimeWhileUUIDStaysInManifest() throws {
        let writer = try SessionWriter(root: temporaryRoot, startedAt: startedAt)
        try writer.finish(at: startedAt.addingTimeInterval(1))

        XCTAssertEqual(writer.directory.deletingLastPathComponent().lastPathComponent, dayName)
        XCTAssertEqual(writer.directory.lastPathComponent, baseName)
        let persisted = try readManifest(in: writer.directory)
        XCTAssertEqual(persisted.directoryName, baseName)
        XCTAssertEqual(persisted.id, writer.manifest.id)
        XCTAssertFalse(writer.directory.lastPathComponent.contains(persisted.id.uuidString.lowercased()))
        XCTAssertEqual(persisted.startedAt, startedAt)
    }

    func testSameSecondRecordingsGetDistinctDirectoriesWithoutReplacingEarlierManifests() throws {
        var directories: [URL] = []
        var originalManifests: [Data] = []
        var ids: Set<UUID> = []
        for _ in 0..<3 {
            let writer = try SessionWriter(root: temporaryRoot, startedAt: startedAt)
            try writer.finish(at: startedAt.addingTimeInterval(1))
            directories.append(writer.directory)
            ids.insert(writer.manifest.id)
            originalManifests.append(try Data(contentsOf: writer.directory.appendingPathComponent("session.json")))
        }

        XCTAssertEqual(directories.map(\.lastPathComponent), [baseName, "\(baseName)_02", "\(baseName)_03"])
        XCTAssertEqual(ids.count, 3)
        for (directory, original) in zip(directories, originalManifests) {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("session.json")), original)
            let persisted = try readManifest(in: directory)
            XCTAssertTrue(ids.contains(persisted.id))
            XCTAssertEqual(persisted.directoryName, directory.lastPathComponent)
        }
    }

    func testFileDirectoryAndDanglingSymlinkCollisionsAreAllSkippedWithoutChangingThem() throws {
        let day = temporaryRoot.appendingPathComponent(dayName, isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let existingFile = day.appendingPathComponent(baseName)
        let existingDirectory = day.appendingPathComponent("\(baseName)_02", isDirectory: true)
        let danglingLink = day.appendingPathComponent("\(baseName)_03")
        let missingTarget = temporaryRoot.appendingPathComponent("missing-symlink-target", isDirectory: true)
        let originalFile = Data("An unrelated existing file must remain unchanged.".utf8)
        let originalSentinel = Data("An occupied directory must not be reused.".utf8)
        try originalFile.write(to: existingFile)
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: false)
        let sentinel = existingDirectory.appendingPathComponent("session.json")
        try originalSentinel.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: danglingLink, withDestinationURL: missingTarget)
        let originalLinkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: danglingLink.path)

        let writer = try SessionWriter(root: temporaryRoot, startedAt: startedAt)
        try writer.finish(at: startedAt.addingTimeInterval(1))

        XCTAssertEqual(writer.directory.lastPathComponent, "\(baseName)_04")
        XCTAssertEqual(try Data(contentsOf: existingFile), originalFile)
        XCTAssertEqual(try Data(contentsOf: sentinel), originalSentinel)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: danglingLink.path), originalLinkDestination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
        XCTAssertEqual(try readManifest(in: writer.directory).directoryName, "\(baseName)_04")
    }

    func testRecoveryRecognizesNewDirectoryNamesAndCollisionSuffixes() throws {
        var interruptedDirectories: [URL] = []
        var expectedIDs: [UUID] = []
        for suffix in ["", "_02", "_03"] {
            let directory = sessionDirectory("\(baseName)\(suffix)")
            let manifest = try recoveryManifest(directoryName: directory.lastPathComponent)
            try write(manifest, in: directory)
            interruptedDirectories.append(directory)
            expectedIDs.append(manifest.id)
        }
        let completed = try SessionWriter(root: temporaryRoot, startedAt: startedAt)
        try completed.finish(at: startedAt.addingTimeInterval(1))
        let completedURL = completed.directory.appendingPathComponent("session.json")
        let originalCompletedData = try Data(contentsOf: completedURL)

        XCTAssertEqual(try SessionWriter.recoverInterruptedSessions(at: temporaryRoot), 3)
        for (directory, id) in zip(interruptedDirectories, expectedIDs) {
            let recovered = try readManifest(in: directory)
            XCTAssertEqual(recovered.id, id)
            XCTAssertEqual(recovered.directoryName, directory.lastPathComponent)
            XCTAssertEqual(recovered.status, .interrupted)
            XCTAssertEqual(recovered.endReason, "appInterrupted")
            XCTAssertEqual(recovered.endedAt, recovered.updatedAt)
        }
        XCTAssertEqual(try Data(contentsOf: completedURL), originalCompletedData)
        XCTAssertEqual(try SessionWriter.recoverInterruptedSessions(at: temporaryRoot), 0)
    }

    func testRecoveryNeverParsesUnrelatedNamesWrongParentDatesOrInvalidSuffixes() throws {
        let validDirectory = sessionDirectory(baseName)
        try write(recoveryManifest(directoryName: baseName), in: validDirectory)
        let invalidPaths = [
            "notes/session.json",
            "\(dayName)/meeting/session.json",
            "2026-09-06/\(baseName)/session.json",
            "\(dayName)/2026-09-06_23-04-05/session.json",
            "2026-02-30/2026-02-30_23-04-05/session.json",
            "\(dayName)/2026-09-05_25-04-05/session.json",
            "\(dayName)/\(baseName)_00/session.json",
            "\(dayName)/\(baseName)_01/session.json",
            "\(dayName)/\(baseName)_1/session.json",
            "\(dayName)/\(baseName)_002/session.json",
            "\(dayName)/\(baseName)_abc/session.json",
            "\(dayName)/\(baseName)_02_more/session.json",
        ]
        let poison = Data("{ This unrelated document is intentionally invalid JSON.".utf8)
        let files = try invalidPaths.map { relative -> URL in
            let file = temporaryRoot.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try poison.write(to: file)
            return file
        }

        // A parse attempt would throw; recovery should inspect only the one recognized session.
        XCTAssertEqual(try SessionWriter.recoverInterruptedSessions(at: temporaryRoot), 1)
        XCTAssertEqual(try readManifest(in: validDirectory).status, .interrupted)
        for file in files { XCTAssertEqual(try Data(contentsOf: file), poison) }
    }

    func testRecoveryRequiresManifestBindingToMatchNewDirectoryName() throws {
        let bindings: [String?] = ["\(baseName)_99", nil, "../different-session"]
        var originals: [URL: Data] = [:]
        for (index, binding) in bindings.enumerated() {
            let name = index == 0 ? baseName : "\(baseName)_0\(index + 1)"
            let directory = sessionDirectory(name)
            let manifest = try recoveryManifest(directoryName: binding)
            try write(manifest, in: directory)
            let file = directory.appendingPathComponent("session.json")
            originals[file] = try Data(contentsOf: file)
        }

        XCTAssertEqual(try SessionWriter.recoverInterruptedSessions(at: temporaryRoot), 0)
        for (file, data) in originals { XCTAssertEqual(try Data(contentsOf: file), data) }
    }

    private func sessionDirectory(_ name: String) -> URL {
        temporaryRoot.appendingPathComponent(dayName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private func recoveryManifest(directoryName: String?) throws -> SessionManifest {
        // Build fixtures from the public writer API, leaving no live writer during recovery.
        let writer = try SessionWriter(root: temporaryRoot.appendingPathComponent("fixture-source", isDirectory: true),
                                       startedAt: startedAt)
        try writer.finish(at: startedAt.addingTimeInterval(20))
        var manifest = writer.manifest
        manifest.directoryName = directoryName
        manifest.status = .recording
        manifest.endedAt = nil
        manifest.endReason = nil
        return manifest
    }

    private func write(_ manifest: SessionManifest, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("session.json"))
    }

    private func readManifest(in directory: URL) throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionManifest.self,
                                  from: Data(contentsOf: directory.appendingPathComponent("session.json")))
    }
}
