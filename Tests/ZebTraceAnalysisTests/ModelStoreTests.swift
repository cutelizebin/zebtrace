import CryptoKit
import Foundation
import XCTest
import ZebTraceCore
@testable import ZebTraceAnalysis

final class ModelStoreTests: XCTestCase {
    func testDefaultDirectoryFollowsTheSelectedRecordingRoot() {
        XCTAssertEqual(LocalModelStore.defaultDirectory,
                       RecordingLocation().directory.appendingPathComponent("Models", isDirectory: true))
        XCTAssertNotEqual(LocalModelStore.defaultDirectory, LocalModelStore.legacyDirectory)
    }

    func testCatalogOffersFullWhisperWithoutChangingDefaultDownloadEstimate() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let store = LocalModelStore(directory: fixture.destination)
        let required = try store.requiredDescriptors()
        XCTAssertEqual(required.map(\.filename), ["ggml-large-v3-turbo-q5_0.bin", "Qwen3-4B-Q4_K_M.gguf",
                                                 "ggml-silero-v6.2.0.bin"])
        XCTAssertEqual(LocalModelStore.totalDownloadBytes, 3_072_206_549)
        XCTAssertEqual(LocalModelStore.modelDescription, "Whisper large-v3-turbo · Q5 + Qwen3 4B · Q4")
        let alternative = try XCTUnwrap(store.descriptors.first { $0.filename == "ggml-large-v3-q5_0.bin" })
        XCTAssertEqual(alternative.role, "asr")
        XCTAssertEqual(alternative.bytes, 1_081_140_203)
        XCTAssertEqual(try store.requiredDescriptors(asrFilename: alternative.filename).map(\.filename),
                       [alternative.filename, required[1].filename, required[2].filename])
    }

    func testUninstalledAlternativeDoesNotBlockDefaultPreparationOrReadiness() async throws {
        let fixture = try ModelStoreFixture(includeAlternative: true)
        defer { fixture.remove() }
        for index in 0..<3 {
            try fixture.payloads[index].write(to: fixture.destination.appendingPathComponent(fixture.models[index].filename))
        }

        let files = try await fixture.store.prepare { _ in XCTFail("The default pipeline is already on disk.") }

        XCTAssertEqual(files.asr.lastPathComponent, fixture.models[0].filename)
        XCTAssertEqual(files.summary.lastPathComponent, fixture.models[1].filename)
        XCTAssertTrue(fixture.store.isReady)
        XCTAssertTrue(fixture.store.isReady(asrFilename: fixture.models[0].filename))
        XCTAssertFalse(fixture.store.isReady(asrFilename: fixture.models[3].filename))
        XCTAssertEqual(try fixture.store.statuses().count, 4, "Inventory must include the unused alternative.")
        XCTAssertEqual(try fixture.store.status(for: fixture.models[3].filename).installedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination
            .appendingPathComponent(fixture.models[3].filename + ".partial").path))
    }

    func testSelectedAlternativePreparesWithoutRequiringTheDefaultASR() async throws {
        let fixture = try ModelStoreFixture(includeAlternative: true)
        defer { fixture.remove() }
        for index in 1..<4 {
            try fixture.payloads[index].write(to: fixture.destination.appendingPathComponent(fixture.models[index].filename))
        }
        let selected = fixture.models[3].filename

        let files = try await fixture.store.prepare(asrFilename: selected) { _ in
            XCTFail("The selected pipeline is already on disk.")
        }

        XCTAssertEqual(files.asr.lastPathComponent, selected)
        XCTAssertEqual(files.summary.lastPathComponent, fixture.models[1].filename)
        XCTAssertTrue(fixture.store.isReady(asrFilename: selected))
        XCTAssertFalse(fixture.store.isReady)
        XCTAssertEqual(try fixture.store.status(for: fixture.models[0].filename).installedBytes, 0)

        // The VAD remains required for either ASR selection.
        try fixture.store.removeModel(filename: fixture.models[2].filename)
        XCTAssertFalse(fixture.store.isReady(asrFilename: selected))
        XCTAssertTrue(try fixture.store.status(for: selected).isReady)
    }

    func testInvalidAndNonASRSelectionsFailBeforeCreatingModelFiles() async throws {
        let fixture = try ModelStoreFixture(includeAlternative: true)
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.destination)
        for filename in ["unknown.bin", "../outside.bin", fixture.models[1].filename, fixture.models[2].filename] {
            XCTAssertThrowsError(try fixture.store.requiredDescriptors(asrFilename: filename)) { error in
                XCTAssertEqual(error.localizedDescription, L10n.string("modelStore.error.unknownModel", filename))
            }
            XCTAssertFalse(fixture.store.isReady(asrFilename: filename))
            do {
                _ = try await fixture.store.prepare(asrFilename: filename) { _ in XCTFail("Invalid selection must not download.") }
                XCTFail("Invalid or non-ASR selection must fail.")
            } catch {
                XCTAssertEqual(error.localizedDescription, L10n.string("modelStore.error.unknownModel", filename))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testAllAlternativesRemainOwnedForMigrationAndCleanupWhileUnknownFilesSurvive() throws {
        let fixture = try ModelStoreFixture(includeAlternative: true)
        defer { fixture.remove() }
        try fixture.writeCompleteModels(to: fixture.source)
        let unknown = fixture.destination.appendingPathComponent("personal-model.bin")
        try Data("keep".utf8).write(to: unknown)

        let migration = try fixture.store.migrateModels(from: fixture.source)

        XCTAssertEqual(Set(migration.migrated), Set(fixture.models.map(\.filename)))
        XCTAssertTrue(fixture.store.isReady)
        XCTAssertTrue(fixture.store.isReady(asrFilename: fixture.models[3].filename))
        try fixture.store.removeModel(filename: fixture.models[3].filename)
        XCTAssertTrue(fixture.store.isReady)
        XCTAssertFalse(fixture.store.isReady(asrFilename: fixture.models[3].filename))
        try fixture.store.removeModels()
        XCTAssertTrue(try fixture.store.statuses().allSatisfy { $0.installedBytes == 0 })
        XCTAssertEqual(try Data(contentsOf: unknown), Data("keep".utf8))
    }

    func testPerModelStatusCountsWeightsPartialAndStampWithoutLoadingModels() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        try fixture.writeCompleteModels(to: fixture.destination)
        let files = try await fixture.store.prepare { _ in }
        XCTAssertEqual(files.asr.lastPathComponent, fixture.models[0].filename)
        XCTAssertEqual(files.summary.lastPathComponent, fixture.models[1].filename)
        let full = fixture.destination.appendingPathComponent(fixture.models[0].filename)
        try Data("ab".utf8).write(to: full.appendingPathExtension("partial"))

        let status = try fixture.store.status(for: fixture.models[0].filename)
        let actualBytes = try [full, full.appendingPathExtension("partial"),
                              full.appendingPathExtension("verified.json")].reduce(Int64(0)) {
            $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertEqual(status.installedBytes, actualBytes)
        XCTAssertTrue(status.isReady)
        XCTAssertTrue(fixture.store.isReady)
        XCTAssertEqual(try fixture.store.statuses().map(\.descriptor.role), ["asr", "summary"])

        try FileManager.default.removeItem(at: full.appendingPathExtension("verified.json"))
        XCTAssertFalse(try fixture.store.status(for: fixture.models[0].filename).isReady)
        XCTAssertTrue(try fixture.store.status(for: fixture.models[1].filename).isReady)
    }

    func testRemovalDeletesOnlyTheNamedModelsOwnedFiles() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        try fixture.writeCompleteModels(to: fixture.destination)
        _ = try await fixture.store.prepare { _ in }
        let selected = fixture.destination.appendingPathComponent(fixture.models[0].filename)
        try Data("a".utf8).write(to: selected.appendingPathExtension("partial"))
        let unrelated = fixture.destination.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)

        try fixture.store.removeModel(filename: fixture.models[0].filename)

        XCTAssertEqual(try fixture.store.status(for: fixture.models[0].filename).installedBytes, 0)
        XCTAssertFalse(try fixture.store.status(for: fixture.models[0].filename).isReady)
        XCTAssertTrue(try fixture.store.status(for: fixture.models[1].filename).isReady)
        XCTAssertEqual(try String(contentsOf: unrelated), "keep")
        XCTAssertThrowsError(try fixture.store.removeModel(filename: "../notes.txt"))
        XCTAssertThrowsError(try fixture.store.removeModel(filename: "unknown.bin"))
    }

    func testMigrationMovesVerifiedWeightsAndResumablePartialBytes() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let fullName = fixture.models[0].filename
        let partialName = fixture.models[1].filename + ".partial"
        try fixture.payloads[0].write(to: fixture.source.appendingPathComponent(fullName))
        try Data("old stamp".utf8).write(to: fixture.source.appendingPathComponent(fullName + ".verified.json"))
        try Data(fixture.payloads[1].prefix(2)).write(to: fixture.source.appendingPathComponent(partialName))
        let unrelated = fixture.source.appendingPathComponent("personal.txt")
        try Data("keep".utf8).write(to: unrelated)

        let migration = try fixture.store.migrateModels(from: fixture.source)
        XCTAssertEqual(Set(migration.migrated), Set([fullName, partialName]))
        XCTAssertEqual(migration.retained.map { $0.standardizedFileURL.resolvingSymlinksInPath() },
                       [unrelated.standardizedFileURL.resolvingSymlinksInPath()])

        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent(fullName)), fixture.payloads[0])
        XCTAssertTrue(try fixture.store.status(for: fullName).isReady)
        XCTAssertEqual(try fixture.store.status(for: fixture.models[1].filename).installedBytes, 2)
        XCTAssertFalse(try fixture.store.status(for: fixture.models[1].filename).isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent(fullName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent(fullName + ".verified.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent(partialName).path))
        XCTAssertEqual(try String(contentsOf: unrelated), "keep")
        try fixture.assertNoStagingDirectories()
    }

    func testMigrationDeduplicatesOnlyAnIdenticalDestination() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        try fixture.writeCompleteModels(to: fixture.source)
        try fixture.writeCompleteModels(to: fixture.destination)
        let file = fixture.destination.appendingPathComponent(fixture.models[0].filename)
        let originalDate = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let migration = try fixture.store.migrateModels(from: fixture.source)
        XCTAssertEqual(migration.migrated.count, 2)
        XCTAssertTrue(migration.retained.isEmpty)

        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, originalDate)
        XCTAssertTrue(fixture.store.isReady)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.source.path).filter { $0 != LocalModelLease.filename }.isEmpty)
        try fixture.assertNoStagingDirectories()
    }

    func testConflictingDestinationPreservesEverySourceAndExistingDestination() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        try fixture.writeCompleteModels(to: fixture.source)
        let conflicting = fixture.destination.appendingPathComponent(fixture.models[1].filename)
        try Data("xxxxxx".utf8).write(to: conflicting)

        XCTAssertThrowsError(try fixture.store.migrateModels(from: fixture.source))

        for (model, payload) in zip(fixture.models, fixture.payloads) {
            XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent(model.filename)), payload)
        }
        XCTAssertEqual(try Data(contentsOf: conflicting), Data("xxxxxx".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent(fixture.models[0].filename).path))
        try fixture.assertNoStagingDirectories()
    }

    func testInvalidHashAndOversizedPartialNeverMigrate() throws {
        for usePartial in [false, true] {
            let fixture = try ModelStoreFixture()
            defer { fixture.remove() }
            try fixture.payloads[0].write(to: fixture.source.appendingPathComponent(fixture.models[0].filename))
            let invalid = fixture.source.appendingPathComponent(fixture.models[1].filename + (usePartial ? ".partial" : ""))
            let data = Data((usePartial ? "too many bytes" : "xxxxxx").utf8)
            try data.write(to: invalid)

            XCTAssertThrowsError(try fixture.store.migrateModels(from: fixture.source))

            XCTAssertEqual(try Data(contentsOf: invalid), data)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).filter { $0 != LocalModelLease.filename }.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent(fixture.models[0].filename).path))
        }
    }

    func testSymlinkIsRejectedWithoutFollowingOrDeletingItsTarget() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside.bin")
        try fixture.payloads[0].write(to: outside)
        let link = fixture.source.appendingPathComponent(fixture.models[0].filename)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try fixture.store.migrateModels(from: fixture.source))
        XCTAssertEqual(try Data(contentsOf: outside), fixture.payloads[0])
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        try fixture.assertNoStagingDirectories()
    }

    func testInvalidDescriptorCannotEscapeOrAliasAnotherModelsPartial() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let original = fixture.models[0]
        for filename in ["../outside.bin", original.filename + ".partial"] {
            let invalid = LocalModelDescriptor(name: "Invalid", filename: filename, url: original.url,
                                               bytes: original.bytes, sha256: original.sha256, license: "MIT")
            let store = LocalModelStore(directory: fixture.destination, descriptors: [original, invalid])
            XCTAssertThrowsError(try store.statuses())
            XCTAssertThrowsError(try store.removeModels())
            XCTAssertThrowsError(try store.migrateModels(from: fixture.source))
        }
    }

    func testModelDirectorySymlinkCannotExposeOrRemoveExternalModels() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        try fixture.writeCompleteModels(to: fixture.source)
        try FileManager.default.removeItem(at: fixture.destination)
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: fixture.source)

        XCTAssertThrowsError(try fixture.store.statuses())
        XCTAssertThrowsError(try fixture.store.removeModel(filename: fixture.models[0].filename))
        XCTAssertThrowsError(try fixture.store.removeModels())
        XCTAssertThrowsError(try fixture.store.migrateModels(from: fixture.source))

        for (model, payload) in zip(fixture.models, fixture.payloads) {
            XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent(model.filename)), payload)
        }
    }

    func testMigrationReportsUnrecognizedRetainedFilesEvenWithoutAnyWeights() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let unknown = fixture.source.appendingPathComponent("old-custom-model.bin")
        try Data("keep".utf8).write(to: unknown)

        let migration = try fixture.store.migrateModels(from: fixture.source)

        XCTAssertTrue(migration.migrated.isEmpty)
        XCTAssertEqual(migration.retained.map { $0.standardizedFileURL.resolvingSymlinksInPath() },
                       [unknown.standardizedFileURL.resolvingSymlinksInPath()])
        XCTAssertEqual(try Data(contentsOf: unknown), Data("keep".utf8))
    }

    func testRemoveAllModelsAlsoRemovesRecognizedInterruptedMigrationFiles() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        try fixture.writeCompleteModels(to: fixture.destination)
        let staging = fixture.destination.appendingPathComponent(".migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try fixture.payloads[0].write(to: staging.appendingPathComponent(fixture.models[0].filename))
        try Data("gh".utf8).write(to: staging.appendingPathComponent(fixture.models[1].filename + ".partial"))

        try fixture.store.removeModel(filename: fixture.models[0].filename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent(fixture.models[0].filename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent(fixture.models[1].filename + ".partial").path))
        try fixture.store.removeModels()

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).filter { $0 != LocalModelLease.filename }.isEmpty)
    }

    func testUnrecognizedStagingContentIsReportedBeforeDeletingAnyModels() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        try fixture.writeCompleteModels(to: fixture.destination)
        let staging = fixture.destination.appendingPathComponent(".migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let unknown = staging.appendingPathComponent("personal.txt")
        try Data("keep".utf8).write(to: unknown)

        XCTAssertThrowsError(try fixture.store.removeModels())

        XCTAssertEqual(try String(contentsOf: unknown), "keep")
        for (model, payload) in zip(fixture.models, fixture.payloads) {
            XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent(model.filename)), payload)
        }
    }

    func testSharedInferenceLeaseBlocksDeletionAndPreparationAcrossStoreInstances() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        try fixture.writeCompleteModels(to: fixture.destination)
        let reader = try LocalModelLease(directory: fixture.destination, exclusive: false)
        defer { reader.close() }
        let anotherStore = LocalModelStore(directory: fixture.destination, descriptors: fixture.models)

        XCTAssertThrowsError(try anotherStore.removeModel(filename: fixture.models[0].filename))
        XCTAssertThrowsError(try anotherStore.removeModels())
        do {
            _ = try await anotherStore.prepare { _ in }
            XCTFail("Preparation must not run while inference has a shared lease.")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.string("modelStore.error.busy"))
        }
        for (model, payload) in zip(fixture.models, fixture.payloads) {
            XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent(model.filename)), payload)
        }

        reader.close()
        reader.close() // Explicit cancellation and deinit can both release safely.
        try anotherStore.removeModels()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [LocalModelLease.filename])
    }

    func testSharedLeaseOnEitherMigrationDirectoryPreservesBothAndReleasesOtherLock() throws {
        for lockSource in [false, true] {
            let fixture = try ModelStoreFixture()
            defer { fixture.remove() }
            try fixture.writeCompleteModels(to: fixture.source)
            let busyDirectory = lockSource ? fixture.source : fixture.destination
            let otherDirectory = lockSource ? fixture.destination : fixture.source
            let reader = try LocalModelLease(directory: busyDirectory, exclusive: false)
            defer { reader.close() }

            XCTAssertThrowsError(try fixture.store.migrateModels(from: fixture.source))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent(fixture.models[0].filename).path))
            // A failed two-directory acquisition must not leak its first lock.
            let other = try LocalModelLease(directory: otherDirectory, exclusive: true)
            other.close()
            reader.close()

            let result = try fixture.store.migrateModels(from: fixture.source)
            XCTAssertEqual(result.migrated.count, 2)
            XCTAssertTrue(result.retained.isEmpty, "The owned zero-byte source lock is not a leftover model.")
        }
    }

    func testSharedLeasesCoexistAndExclusiveLeaseBecomesAvailableAfterEveryReaderCloses() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let first = try LocalModelLease(directory: fixture.destination, exclusive: false)
        let second = try LocalModelLease(directory: fixture.destination, exclusive: false)
        defer { first.close(); second.close() }

        XCTAssertThrowsError(try LocalModelLease(directory: fixture.destination, exclusive: true))
        first.close()
        XCTAssertThrowsError(try LocalModelLease(directory: fixture.destination, exclusive: true))
        second.close()
        let exclusive = try LocalModelLease(directory: fixture.destination, exclusive: true)
        exclusive.close()
    }

    func testModelLockRejectsSymlinkAndNonemptyFileWithoutChangingThem() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside-lock")
        try Data("keep".utf8).write(to: outside)
        let lock = fixture.destination.appendingPathComponent(LocalModelLease.filename)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outside)
        XCTAssertThrowsError(try LocalModelLease(directory: fixture.destination, exclusive: false))
        XCTAssertEqual(try String(contentsOf: outside), "keep")

        try FileManager.default.removeItem(at: lock)
        try Data("keep".utf8).write(to: lock)
        XCTAssertThrowsError(try LocalModelLease(directory: fixture.destination, exclusive: true))
        XCTAssertEqual(try String(contentsOf: lock), "keep")
    }

    func testRemovingMissingModelDirectoryDoesNotCreateItOrALock() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.destination)

        try fixture.store.removeModel(filename: fixture.models[0].filename)
        try fixture.store.removeModels()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }
}

private struct ModelStoreFixture {
    let root: URL
    let source: URL
    let destination: URL
    let payloads: [Data]
    let models: [LocalModelDescriptor]
    let store: LocalModelStore

    init(includeAlternative: Bool = false) throws {
        payloads = (includeAlternative ? ["abcdef", "ghijkl", "mnopqr", "stuvwx"] : ["abcdef", "ghijkl"])
            .map { Data($0.utf8) }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ZebTrace-ModelStoreTests-" + UUID().uuidString)
        source = root.appendingPathComponent("old/Models", isDirectory: true)
        destination = root.appendingPathComponent("recordings/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        models = payloads.enumerated().map { index, data in
            LocalModelDescriptor(name: "Small fixture \(index)", filename: "model-\(index).bin",
                                 url: URL(string: "https://zebtrace-model-store-tests.invalid/\(index)")!,
                                 bytes: Int64(data.count),
                                 sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                 license: "MIT", role: ["asr", "summary", "vad", "asr"][index])
        }
        store = LocalModelStore(directory: destination, descriptors: models)
    }

    func writeCompleteModels(to directory: URL) throws {
        for (model, payload) in zip(models, payloads) { try payload.write(to: directory.appendingPathComponent(model.filename)) }
    }

    func assertNoStagingDirectories(file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".migration-") }, file: file, line: line)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
