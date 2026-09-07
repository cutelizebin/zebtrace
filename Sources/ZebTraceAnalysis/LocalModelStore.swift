import Darwin
import Foundation
import ZebTraceCore

public struct LocalModelDescriptor: Sendable {
    public let name: String
    public let filename: String
    public let url: URL
    public let bytes: Int64
    public let sha256: String
    public let license: String
    public let role: String

    public init(name: String, filename: String, url: URL, bytes: Int64,
                sha256: String, license: String, role: String = "asr") {
        self.name = name; self.filename = filename; self.url = url; self.bytes = bytes
        self.sha256 = sha256; self.license = license; self.role = role
    }
}

public struct LocalModelStatus: Sendable {
    public let descriptor: LocalModelDescriptor
    public let fileURL: URL
    /// Complete weights, resumable bytes, and the validation stamp together.
    public let installedBytes: Int64
    /// Validated on disk, independent of whether an inference process is running.
    public let isReady: Bool
}

public struct ModelMigrationResult: Sendable {
    /// Filenames now available in the destination, including resumable partials.
    public let migrated: [String]
    /// Source entries still present after migration, including unknown files or
    /// failed cleanup. If enumeration fails, contains the source directory itself.
    public let retained: [URL]
}

/// The app owns downloads and validation. Providers never fetch weights implicitly.
/// A store belongs to one recording root; replace it after changing that root.
public final class LocalModelStore: @unchecked Sendable {
    public static let models: [LocalModelDescriptor] = [
        .init(name: "Whisper large-v3-turbo · Q5", filename: "ggml-large-v3-turbo-q5_0.bin",
              url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin")!,
              bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", license: "MIT", role: "asr"),
        .init(name: "Qwen3 4B · Q4", filename: "Qwen3-4B-Q4_K_M.gguf",
              url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf")!,
              bytes: 2_497_280_256, sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5", license: "Apache-2.0", role: "summary"),
        .init(name: "Silero v6.2.0", filename: "ggml-silero-v6.2.0.bin",
              url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin")!,
              bytes: 885_098, sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987", license: "MIT", role: "vad"),
        .init(name: "Whisper large-v3 · Q5", filename: "ggml-large-v3-q5_0.bin",
              url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-q5_0.bin")!,
              bytes: 1_081_140_203, sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1", license: "MIT", role: "asr"),
    ]
    private static var defaultDescriptors: [LocalModelDescriptor] {
        [models.first { $0.role == "asr" }, models.first { $0.role == "summary" }].compactMap { $0 }
            + models.filter { $0.role == "vad" }
    }
    public static var totalDownloadBytes: Int64 { defaultDescriptors.reduce(0) { $0 + $1.bytes } }
    public static var modelDescription: String {
        defaultDescriptors.filter { $0.role != "vad" }.map(\.name).joined(separator: " + ")
    }
    public static var defaultDirectory: URL {
        RecordingLocation().directory.appendingPathComponent("Models", isDirectory: true)
    }
    public static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZebTrace/Models", isDirectory: true)
    }

    public let directory: URL
    public let descriptors: [LocalModelDescriptor]
    private let lock = NSLock()
    private var preparing = false

    public init(directory: URL? = nil, descriptors: [LocalModelDescriptor] = LocalModelStore.models) {
        self.directory = directory ?? Self.defaultDirectory
        self.descriptors = descriptors
    }

    public var isReady: Bool { isReady(asrFilename: nil) }

    /// Readiness concerns the selected pipeline; unused alternatives may remain
    /// uninstalled without preventing transcription with the current model.
    public func isReady(asrFilename: String?) -> Bool {
        guard let required = try? requiredDescriptors(asrFilename: asrFilename) else { return false }
        return required.allSatisfy { model in
            (try? status(for: model.filename).isReady) == true
        }
    }

    /// Resolve one ASR model, the current summarizer, and its shared VAD assets.
    /// Nil retains the original default: the first ASR descriptor in the catalog.
    public func requiredDescriptors(asrFilename: String? = nil) throws -> [LocalModelDescriptor] {
        try validateDescriptors()
        let asr: LocalModelDescriptor
        if let asrFilename {
            guard let selected = descriptors.first(where: { $0.filename == asrFilename && $0.role == "asr" }) else {
                throw AnalysisFailure(L10n.string("modelStore.error.unknownModel", asrFilename))
            }
            asr = selected
        } else {
            guard let selected = descriptors.first(where: { $0.role == "asr" }) else {
                throw AnalysisFailure(L10n.string("modelStore.error.missingRoles"))
            }
            asr = selected
        }
        guard let summary = descriptors.first(where: { $0.role == "summary" }) else {
            throw AnalysisFailure(L10n.string("modelStore.error.missingRoles"))
        }
        return [asr, summary] + descriptors.filter { $0.role == "vad" }
    }

    public func statuses() throws -> [LocalModelStatus] {
        try validateDescriptors()
        return try descriptors.map { try status(for: $0.filename) }
    }

    public func status(for filename: String) throws -> LocalModelStatus {
        let model = try descriptor(for: filename)
        let url = directory.appendingPathComponent(model.filename)
        var total: Int64 = 0
        for file in ownedFiles(url) where Self.exists(file) {
            try AnalysisFiles.regularFile(file)
            let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            let (sum, overflow) = total.addingReportingOverflow(max(0, size))
            total = overflow ? Int64.max : sum
        }
        return .init(descriptor: model, fileURL: url, installedBytes: total,
                     isReady: (try? verifiedStamp(for: url, model: model)) == true)
    }

    public func prepare(asrFilename: String? = nil,
                        progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws -> LocalModelFiles {
        try beginPreparation()
        defer { endPreparation() }
        let required = try requiredDescriptors(asrFilename: asrFilename)
        let asr = required[0]
        let summary = required[1]
        try AnalysisFiles.directory(directory)
        let lease = try LocalModelLease(directory: directory, exclusive: true)
        defer { lease.close() }
        for model in required {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(model.filename)
            if (try? verifiedStamp(for: url, model: model)) == true { continue }
            if !Self.exists(url) {
                let partial = url.appendingPathExtension("partial")
                let existing = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let needed = max(0, model.bytes - Int64(existing)) + 512 * 1024 * 1024
                if let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage, available < needed {
                    throw AnalysisFailure(L10n.string("modelStore.error.diskSpace", model.name))
                }
                try await ModelTransfer(model: model, destination: partial).download { received in
                    progress(.init(modelName: model.name, downloadedBytes: received, totalBytes: model.bytes))
                }
                guard try AnalysisFiles.digest(file: partial) == model.sha256 else {
                    try? FileManager.default.removeItem(at: partial)
                    throw AnalysisFailure(L10n.string("modelStore.error.downloadHash"))
                }
                try Self.moveWithoutOverwriting(partial, to: url)
            } else {
                guard try AnalysisFiles.digest(file: url) == model.sha256 else {
                    throw AnalysisFailure(L10n.string("modelStore.error.damaged"))
                }
            }
            try AnalysisFiles.encode(try stamp(for: url, model: model), to: stampURL(url))
        }
        try Task.checkCancellation()
        return .init(asr: directory.appendingPathComponent(asr.filename),
                     summary: directory.appendingPathComponent(summary.filename))
    }

    public func removeModel(filename: String) throws {
        try beginPreparation()
        defer { endPreparation() }
        let model = try descriptor(for: filename)
        guard Self.exists(directory) else { return }
        let lease = try LocalModelLease(directory: directory, exclusive: true)
        defer { lease.close() }
        try removeFiles(for: [model])
    }

    public func removeModels() throws {
        try beginPreparation()
        defer { endPreparation() }
        try validateDescriptors()
        guard Self.exists(directory) else { return }
        let lease = try LocalModelLease(directory: directory, exclusive: true)
        defer { lease.close() }
        try removeFiles(for: descriptors)
    }

    /// Stages all known weights and partial downloads before committing. Full
    /// weights must match the catalog hash. Partials must fit the declared size
    /// and are copied byte-for-byte; prepare still validates the completed model.
    /// Different destination files are never replaced. Failure rolls back new
    /// destination files. Source cleanup is best effort after a full commit.
    @discardableResult
    public func migrateModels(from sourceDirectory: URL) throws -> ModelMigrationResult {
        try beginPreparation()
        defer { endPreparation() }
        try validateDescriptors()
        guard sourceDirectory.isFileURL else {
            throw AnalysisFailure(L10n.string("modelStore.error.sourceDirectory"))
        }
        guard sourceDirectory.standardizedFileURL.resolvingSymlinksInPath() !=
                directory.standardizedFileURL.resolvingSymlinksInPath() else { return .init(migrated: [], retained: []) }
        guard Self.exists(sourceDirectory) else { return .init(migrated: [], retained: []) }
        let sourceValues = try sourceDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
            throw AnalysisFailure(L10n.string("modelStore.error.sourceDirectory"))
        }
        try AnalysisFiles.directory(directory)
        // A fixed order also applies when two processes migrate opposite ways.
        let leases = try Self.exclusiveLeases(for: [sourceDirectory, directory])
        defer { leases.reversed().forEach { $0.close() } }
        var candidates: [(model: LocalModelDescriptor, source: URL, snapshot: FileSnapshot,
                          hash: String, complete: Bool, destinationExists: Bool)] = []
        for model in descriptors {
            for suffix in ["", ".partial"] {
                try Task.checkCancellation()
                let source = sourceDirectory.appendingPathComponent(model.filename + suffix)
                guard Self.exists(source) else { continue }
                let snapshot = try fileSnapshot(for: source)
                let complete = suffix.isEmpty
                guard snapshot.size >= 0, Int64(snapshot.size) <= model.bytes,
                      !complete || Int64(snapshot.size) == model.bytes else {
                    throw AnalysisFailure(L10n.string("modelStore.error.incompleteFile"))
                }
                let hash = try AnalysisFiles.digest(file: source)
                guard !complete || hash == model.sha256 else {
                    throw AnalysisFailure(L10n.string("modelStore.error.migrationHash", model.name))
                }
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                let destinationExists = Self.exists(destination)
                if destinationExists {
                    guard (try? fileSnapshot(for: destination).size) == snapshot.size,
                          (try? AnalysisFiles.digest(file: destination)) == hash else {
                        throw AnalysisFailure(L10n.string("modelStore.error.destinationConflict", source.lastPathComponent))
                    }
                }
                if complete, Self.exists(stampURL(destination)) { try AnalysisFiles.regularFile(stampURL(destination)) }
                candidates.append((model, source, snapshot, hash, complete, destinationExists))
            }
        }
        guard !candidates.isEmpty else {
            return .init(migrated: [], retained: Self.remainingContents(of: sourceDirectory))
        }
        try AnalysisFiles.directory(directory)
        let staging = directory.appendingPathComponent(".migration-" + UUID().uuidString, isDirectory: true)
        try AnalysisFiles.directory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        var created: [URL] = []
        var previousStamps: [URL: Data] = [:]
        var publishedStamps: [URL] = []
        do {
            for candidate in candidates where !candidate.destinationExists {
                try Task.checkCancellation()
                let copy = staging.appendingPathComponent(candidate.source.lastPathComponent)
                try FileManager.default.copyItem(at: candidate.source, to: copy)
                guard (try? fileSnapshot(for: copy).size) == candidate.snapshot.size,
                      try AnalysisFiles.digest(file: copy) == candidate.hash else {
                    throw AnalysisFailure(L10n.string("modelStore.error.migrationHash", candidate.model.name))
                }
            }
            for candidate in candidates {
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent(candidate.source.lastPathComponent)
                if !candidate.destinationExists {
                    try Self.moveWithoutOverwriting(staging.appendingPathComponent(candidate.source.lastPathComponent), to: destination)
                    created.append(destination)
                }
                if candidate.complete {
                    let validation = stampURL(destination)
                    if Self.exists(validation) {
                        try AnalysisFiles.regularFile(validation)
                        previousStamps[validation] = try Data(contentsOf: validation)
                    }
                    publishedStamps.append(validation)
                    try AnalysisFiles.encode(try stamp(for: destination, model: candidate.model), to: validation)
                }
            }
            try Task.checkCancellation()
        } catch {
            for validation in publishedStamps.reversed() {
                if let original = previousStamps[validation] { try? AnalysisFiles.write(original, to: validation) }
                else { try? FileManager.default.removeItem(at: validation) }
            }
            for file in created.reversed() { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        // Once committed, a cleanup failure must not prevent selecting the usable
        // destination. If the source changed meanwhile, preserve that source.
        for candidate in candidates {
            guard (try? fileSnapshot(for: candidate.source)) == candidate.snapshot else { continue }
            do {
                try FileManager.default.removeItem(at: candidate.source)
                if candidate.complete {
                    let oldStamp = stampURL(candidate.source)
                    if Self.exists(oldStamp), (try? AnalysisFiles.regularFile(oldStamp)) != nil {
                        try? FileManager.default.removeItem(at: oldStamp)
                    }
                }
            } catch { /* A verified destination is already committed; retain any remaining source. */ }
        }
        return .init(migrated: candidates.map { $0.source.lastPathComponent },
                     retained: Self.remainingContents(of: sourceDirectory))
    }

    @discardableResult
    public func migrateLegacyModels(from sourceDirectory: URL = LocalModelStore.legacyDirectory) throws -> ModelMigrationResult {
        try migrateModels(from: sourceDirectory)
    }

    private func removeFiles(for models: [LocalModelDescriptor]) throws {
        let leftovers = try migrationLeftovers(for: models)
        let files = models.flatMap { ownedFiles(directory.appendingPathComponent($0.filename)) }.filter(Self.exists)
            + leftovers.flatMap(\.files)
        // Preflight first so a symlink never results in deleting other entries first.
        for file in files { try AnalysisFiles.regularFile(file) }
        for file in files { try FileManager.default.removeItem(at: file) }
        for entry in leftovers where try FileManager.default.contentsOfDirectory(atPath: entry.directory.path).isEmpty {
            try FileManager.default.removeItem(at: entry.directory)
        }
    }

    /// Only the exact private staging layout created by migrateModels is owned.
    /// Unknown entries are preserved and reported before deleting any model files.
    private func migrationLeftovers(for selected: [LocalModelDescriptor]) throws -> [(directory: URL, files: [URL])] {
        guard Self.exists(directory) else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        let allowed = Set(descriptors.flatMap { [$0.filename, $0.filename + ".partial"] })
        let removable = Set(selected.flatMap { [$0.filename, $0.filename + ".partial"] })
        var result: [(directory: URL, files: [URL])] = []
        for entry in entries where entry.lastPathComponent.hasPrefix(".migration-") {
            let identifier = String(entry.lastPathComponent.dropFirst(".migration-".count))
            guard identifier.count == 36, UUID(uuidString: identifier) != nil else { continue }
            let values = try entry.resourceValues(forKeys: Set(keys))
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AnalysisFailure(L10n.string("modelStore.error.unsafeStaging"))
            }
            let files = try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)
            for file in files {
                guard allowed.contains(file.lastPathComponent), (try? AnalysisFiles.regularFile(file)) != nil else {
                    throw AnalysisFailure(L10n.string("modelStore.error.unsafeStaging"))
                }
            }
            result.append((entry, files.filter { removable.contains($0.lastPathComponent) }))
        }
        return result
    }

    private func descriptor(for filename: String) throws -> LocalModelDescriptor {
        try validateDescriptors()
        guard let model = descriptors.first(where: { $0.filename == filename }) else {
            throw AnalysisFailure(L10n.string("modelStore.error.unknownModel", filename))
        }
        return model
    }

    private func validateDescriptors() throws {
        guard directory.isFileURL else {
            throw AnalysisFailure(L10n.string("modelStore.error.invalidDescriptor"))
        }
        if Self.exists(directory) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AnalysisFailure(L10n.string("modelStore.error.modelDirectory"))
            }
        }
        var files = Set<String>()
        for model in descriptors {
            guard !model.filename.isEmpty, model.filename != ".", model.filename != "..",
                  !model.filename.contains("/"), !model.filename.contains("\\"),
                  !model.filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  model.bytes > 0, model.bytes < Int64.max - 512 * 1024 * 1024,
                  model.sha256.count == 64, model.sha256.allSatisfy({ $0.isHexDigit }),
                  ["https", "http"].contains(model.url.scheme?.lowercased() ?? "") else {
                throw AnalysisFailure(L10n.string("modelStore.error.invalidDescriptor"))
            }
            for filename in [model.filename, model.filename + ".partial", model.filename + ".verified.json"] {
                guard files.insert(filename).inserted else {
                    throw AnalysisFailure(L10n.string("modelStore.error.invalidDescriptor"))
                }
            }
        }
    }

    private func beginPreparation() throws {
        lock.lock(); defer { lock.unlock() }
        guard !preparing else { throw AnalysisFailure(L10n.string("modelStore.error.busy")) }
        preparing = true
    }

    private func endPreparation() { lock.lock(); preparing = false; lock.unlock() }
    private struct FileSnapshot: Equatable {
        let size: Int
        let modified: Date
    }
    private func fileSnapshot(for url: URL) throws -> FileSnapshot {
        try AnalysisFiles.regularFile(url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let date = values.contentModificationDate else {
            throw AnalysisFailure(L10n.string("modelStore.error.incompleteFile"))
        }
        return .init(size: size, modified: date)
    }
    private struct Stamp: Codable, Equatable {
        let hash: String
        let size: Int
        let modified: Date
    }
    private func stampURL(_ url: URL) -> URL { url.appendingPathExtension("verified.json") }
    private func ownedFiles(_ url: URL) -> [URL] { [url, url.appendingPathExtension("partial"), stampURL(url)] }
    private func stamp(for url: URL, model: LocalModelDescriptor) throws -> Stamp {
        try AnalysisFiles.regularFile(url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, Int64(size) == model.bytes,
              let date = values.contentModificationDate else { throw AnalysisFailure(L10n.string("modelStore.error.incompleteFile")) }
        return .init(hash: model.sha256, size: size, modified: date)
    }
    private func verifiedStamp(for url: URL, model: LocalModelDescriptor) throws -> Bool {
        guard Self.exists(url), Self.exists(stampURL(url)) else { return false }
        try AnalysisFiles.regularFile(stampURL(url))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(Stamp.self, from: Data(contentsOf: stampURL(url)))
        let current = try stamp(for: url, model: model)
        // ISO-8601 stamps compare whole seconds, matching JSON encoding.
        return stored.hash == current.hash && stored.size == current.size &&
            Int(stored.modified.timeIntervalSince1970) == Int(current.modified.timeIntervalSince1970)
    }
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    private static func remainingContents(of directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                         includingPropertiesForKeys: nil) else {
            return [directory]
        }
        // The normal zero-byte lock stays until the workspace removes an empty
        // Models directory at idle; unlinking a live lock would split its inode.
        return entries.filter { $0.lastPathComponent != LocalModelLease.filename }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private static func exclusiveLeases(for directories: [URL]) throws -> [LocalModelLease] {
        let ordered = directories.sorted {
            $0.standardizedFileURL.resolvingSymlinksInPath().path < $1.standardizedFileURL.resolvingSymlinksInPath().path
        }
        var leases: [LocalModelLease] = []
        do {
            for directory in ordered { leases.append(try LocalModelLease(directory: directory, exclusive: true)) }
            return leases
        } catch {
            leases.reversed().forEach { $0.close() }
            throw error
        }
    }
    private static func moveWithoutOverwriting(_ source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { errno = EINVAL; return Int32(-1) }
                return renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }
}

/// Range downloads stream directly to a private partial file. Cancellation and
/// network failure keep completed bytes; immutable URLs + SHA-256 verify resume.
final class ModelTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let model: LocalModelDescriptor
    private let destination: URL
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var output: FileHandle?
    private var received: Int64 = 0
    private var initialOffset: Int64 = 0
    private var failure: Error?
    private var progress: (@Sendable (Int64) -> Void)?
    private var lastProgress = Date.distantPast

    init(model: LocalModelDescriptor, destination: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.model = model; self.destination = destination; self.configuration = configuration
    }

    func download(progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try AnalysisFiles.regularFile(destination)
                    } else { try AnalysisFiles.write(Data(), to: destination) }
                    output = try FileHandle(forWritingTo: destination)
                    received = Int64(try output!.seekToEnd())
                    if received > model.bytes { try output!.truncate(atOffset: 0); received = 0 }
                    if received == model.bytes { try output?.close(); continuation.resume(); return }
                    initialOffset = received
                    self.progress = progress
                    var request = URLRequest(url: model.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                             timeoutInterval: 60)
                    if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
                    configuration.timeoutIntervalForResource = 24 * 60 * 60
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    let task = session.dataTask(with: request)
                    lock.lock()
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    let wasCancelled = cancelled
                    lock.unlock()
                    progress(received)
                    task.resume()
                    if wasCancelled { task.cancel() }
                } catch { try? output?.close(); continuation.resume(throwing: error) }
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
                throw AnalysisFailure(L10n.string("modelStore.error.http", (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            if http.statusCode == 200, initialOffset > 0 {
                try output?.truncate(atOffset: 0)
                try output?.seek(toOffset: 0)
                received = 0
            } else if http.statusCode == 206 {
                guard http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(initialOffset)-") == true else {
                    throw AnalysisFailure(L10n.string("modelStore.error.invalidPartial"))
                }
            }
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard received + Int64(data.count) <= model.bytes else {
                throw AnalysisFailure(L10n.string("modelStore.error.oversized"))
            }
            try output?.write(contentsOf: data)
            received += Int64(data.count)
            if Date().timeIntervalSince(lastProgress) > 0.2 {
                progress?(received); lastProgress = Date()
            }
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? output?.close()
        output = nil
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        let wasCancelled = cancelled
        lock.unlock()
        progress?(received)
        session.finishTasksAndInvalidate()
        self.session = nil
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let failure = failure ?? error { continuation?.resume(throwing: failure) }
        else if received != model.bytes { continuation?.resume(throwing: AnalysisFailure(L10n.string("modelStore.error.incompleteDownload"))) }
        else { continuation?.resume() }
    }
}
