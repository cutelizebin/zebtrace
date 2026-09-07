import Darwin
import Foundation
import ZebTraceCore

public struct ManagedStorageInventory: Sendable {
    public let recordings: [LibraryRecording]
    /// Session manifests and declared audio chunks, excluding generated results.
    public let recordingBytes: Int64
    public let modelBytes: Int64
    public let generatedBytes: Int64
    public let modelURLs: [URL]
    public var recordingCount: Int { recordings.count }
}

/// Cleanup is restricted to recognized files below an explicitly selected root.
/// URL methods only prepare a preview. Perform the actual Trash operation inside
/// `withExclusiveAccess` and obtain fresh URLs there, while the analysis lock is held.
public enum ManagedStorage {
    private static let generatedNames: Set<String> = [
        "transcript.md", "transcript.json", "transcription.json", "summary.md", "analysis.json"
    ]

    public static func inventory(root: URL) throws -> ManagedStorageInventory {
        let root = try checkedRoot(root, allowMissing: true)
        guard try item(root) != nil else {
            return .init(recordings: [], recordingBytes: 0, modelBytes: 0, generatedBytes: 0, modelURLs: [])
        }
        var recordings: [LibraryRecording] = []
        var recordingBytes: Int64 = 0
        var generatedBytes: Int64 = 0
        for recording in try RecordingLibrary.scan(root: root) {
            guard let manifest = try? validated(recording, root: root, allowRecording: true) else { continue }
            recordings.append(recording)
            for name in Set(manifest.chunks.map(\.file)).union(["session.json"]) {
                recordingBytes += try regularSize(recording.directory.appendingPathComponent(name))
            }
            generatedBytes += try generatedFiles(in: recording.directory).files.reduce(Int64(0)) {
                try $0 + regularSize($1)
            }
        }
        let models = root.appendingPathComponent("Models", isDirectory: true)
        var modelURLs: [URL] = []
        if try item(models)?.kind == .directory {
            for model in LocalModelStore.models {
                for name in [model.filename, model.filename + ".partial", model.filename + ".verified.json"] {
                    let url = models.appendingPathComponent(name)
                    if try item(url)?.kind == .file { modelURLs.append(url) }
                }
            }
            let stagedNames = Set(LocalModelStore.models.flatMap { [$0.filename, $0.filename + ".partial"] })
            for staging in try children(models) {
                let name = staging.lastPathComponent
                guard name.hasPrefix(".migration-"),
                      String(name.dropFirst(".migration-".count)).count == 36,
                      UUID(uuidString: String(name.dropFirst(".migration-".count))) != nil,
                      try item(staging)?.kind == .directory else { continue }
                let files = try children(staging)
                // A crash can leave a complete second copy of the weights. Only
                // count a staging directory if its entire layout is recognized.
                if try files.allSatisfy({ try stagedNames.contains($0.lastPathComponent) && item($0)?.kind == .file }) {
                    modelURLs.append(contentsOf: files)
                }
            }
        }
        let modelBytes = try modelURLs.reduce(Int64(0)) { try $0 + regularSize($1) }
        return .init(recordings: recordings, recordingBytes: recordingBytes,
                     modelBytes: modelBytes, generatedBytes: generatedBytes, modelURLs: modelURLs)
    }

    /// Refuses the entire operation if the session contains an unknown file or
    /// any symlink, so a user's additions cannot be swept up with app data.
    public static func recordingURLForTrash(recording: LibraryRecording, root: URL) throws -> URL {
        let manifest = try validated(recording, root: root)
        let directory = recording.directory.standardizedFileURL
        let allowed = Set(manifest.chunks.map(\.file)).union(generatedNames).union(["session.json", ".DS_Store"])
        for child in try children(directory) {
            if child.lastPathComponent == ".zebtrace-analysis" {
                guard try item(child)?.kind == .directory,
                      try !generatedFiles(in: directory).hasUnknownContent else { throw failure("unknownContent") }
            } else {
                guard allowed.contains(child.lastPathComponent), try item(child)?.kind == .file else {
                    throw failure("unknownContent")
                }
            }
        }
        return directory
    }

    /// Only known regular generated files are returned. The cache directory and
    /// analysis.lock are retained to keep the lock inode stable across cleanup.
    /// Unknown content and symlinks are never returned or followed.
    public static func generatedURLsForTrash(recording: LibraryRecording, root: URL) throws -> [URL] {
        _ = try validated(recording, root: root)
        return try generatedFiles(in: recording.directory).files
    }

    /// Uses the same nonblocking flock as CLI analysis. The caller must also stop
    /// its own recording/model tasks before cleanup; an active session is rejected.
    /// Do not retain or use prepared URLs after this synchronous operation ends.
    public static func withExclusiveAccess<T>(recording: LibraryRecording, root: URL,
                                             operation: (URL) throws -> T) throws -> T {
        _ = try validated(recording, root: root)
        let cache = recording.directory.appendingPathComponent(".zebtrace-analysis", isDirectory: true)
        if try item(cache) == nil {
            let result = Darwin.mkdir(cache.path, 0o700)
            guard result == 0 || errno == EEXIST else { throw failure("lock") }
        }
        guard try item(cache)?.kind == .directory else { throw failure("unsafePath") }
        let descriptor = Darwin.open(cache.appendingPathComponent("analysis.lock").path,
                                     O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw failure("lock") }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_nlink == 1 else { throw failure("lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw failure("busy") }
        // The path/manifest might have changed while acquiring the lock.
        _ = try validated(recording, root: root)
        return try operation(recording.directory.standardizedFileURL)
    }

    private static func validated(_ recording: LibraryRecording, root: URL,
                                  allowRecording: Bool = false) throws -> SessionManifest {
        let root = try checkedRoot(root)
        let directory = recording.directory.standardizedFileURL
        let day = directory.deletingLastPathComponent()
        guard recording.directory.isFileURL,
              day.deletingLastPathComponent().path == root.path,
              validDay(day.lastPathComponent),
              try item(day)?.kind == .directory, try item(directory)?.kind == .directory else {
            throw failure("unsafePath")
        }
        let manifestURL = directory.appendingPathComponent("session.json")
        guard let metadata = try item(manifestURL), metadata.kind == .file,
              metadata.bytes <= 16 * 1024 * 1024 else { throw failure("changed") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SessionManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1, manifest.id == recording.id,
              validName(directory.lastPathComponent, day: day.lastPathComponent, manifest: manifest),
              manifest.chunks.allSatisfy({ validAudioName($0.file) }) else { throw failure("changed") }
        guard allowRecording || manifest.status != .recording else { throw failure("recording") }
        return manifest
    }

    private struct GeneratedFiles {
        var files: [URL] = []
        var hasUnknownContent = false
    }

    private static func generatedFiles(in directory: URL) throws -> GeneratedFiles {
        var result = GeneratedFiles()
        for name in generatedNames.sorted() {
            let url = directory.appendingPathComponent(name)
            if try item(url)?.kind == .file { result.files.append(url) }
        }
        let cache = directory.appendingPathComponent(".zebtrace-analysis", isDirectory: true)
        guard let cacheItem = try item(cache) else { return result }
        guard cacheItem.kind == .directory else { result.hasUnknownContent = true; return result }
        for child in try children(cache) {
            let name = child.lastPathComponent
            let kind = try item(child)?.kind
            if name == "analysis.lock", kind == .file { continue }
            if kind == .file, matches(name, #"^(asr-[a-f0-9]{64}\.json|window-[a-f0-9]{64}-[0-9]+\.json|summary-[a-f0-9]{64}\.txt)$"#) {
                result.files.append(child)
            } else if kind == .directory,
                      name == "previous-review" || validWorkDirectory(name) {
                for nested in try children(child) {
                    let known = name == "previous-review" ? generatedNames.contains(nested.lastPathComponent)
                        : validScratchName(nested.lastPathComponent)
                    if known, try item(nested)?.kind == .file { result.files.append(nested) }
                    else { result.hasUnknownContent = true }
                }
            } else { result.hasUnknownContent = true }
        }
        return result
    }

    private static func validWorkDirectory(_ name: String) -> Bool {
        name.hasPrefix("work-") && UUID(uuidString: String(name.dropFirst(5))) != nil
    }

    /// Automatic crash recovery may remove a scratch directory only when its
    /// complete layout is owned. Keep unknown contents, nested directories, and
    /// symlinks intact, using the same rules as explicit generated-file cleanup.
    /// The caller must hold the session analysis lease while checking/removing it.
    static func isOwnedScratchDirectory(_ directory: URL) throws -> Bool {
        guard validWorkDirectory(directory.lastPathComponent),
              try item(directory)?.kind == .directory else { return false }
        return try children(directory).allSatisfy {
            try validScratchName($0.lastPathComponent) && item($0)?.kind == .file
        }
    }

    private static func validScratchName(_ name: String) -> Bool {
        if name == "chunk.wav" || name == "window.wav" { return true }
        for suffix in [".json", ".prompt.txt", ".stdout", ".stderr"] where name.hasSuffix(suffix) {
            if UUID(uuidString: String(name.dropLast(suffix.count))) != nil { return true }
        }
        return false
    }

    private static func validName(_ name: String, day: String, manifest: SessionManifest) -> Bool {
        if name.count == 45, validTime(String(name.prefix(8))),
           name[name.index(name.startIndex, offsetBy: 8)] == "-",
           UUID(uuidString: String(name.suffix(36))) == manifest.id { return true }
        guard manifest.directoryName == name else { return false }
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts[0] == day, validTime(String(parts[1])) else { return false }
        if parts.count == 3 {
            guard parts[2].utf8.allSatisfy({ (48...57).contains($0) }), let suffix = Int(parts[2]), suffix >= 2,
                  String(parts[2]) == (suffix < 10 ? "0\(suffix)" : "\(suffix)") else { return false }
        }
        return true
    }

    private static func validDay(_ value: String) -> Bool {
        guard matches(value, #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#) else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private static func validTime(_ value: String) -> Bool {
        matches(value, #"^([01][0-9]|2[0-3])-[0-5][0-9]-[0-5][0-9]$"#)
    }

    private static func validAudioName(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains("\0") && value.hasSuffix(".m4a")
    }

    private static func checkedRoot(_ root: URL, allowMissing: Bool = false) throws -> URL {
        guard root.isFileURL else { throw failure("unsafePath") }
        let root = root.standardizedFileURL
        guard let metadata = try item(root) else {
            if allowMissing { return root }
            throw failure("unsafePath")
        }
        guard metadata.kind == .directory else { throw failure("unsafePath") }
        return root
    }

    private enum Kind { case file, directory, other }
    private struct Item { let kind: Kind; let bytes: Int64 }

    /// lstat avoids following symlinks, including dangling links, and bypasses
    /// URL resource-value caches after a file has been replaced.
    private static func item(_ url: URL) throws -> Item? {
        var attributes = stat()
        guard Darwin.lstat(url.path, &attributes) == 0 else {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let mode = attributes.st_mode & S_IFMT
        return Item(kind: mode == S_IFREG ? .file : (mode == S_IFDIR ? .directory : .other),
                    bytes: max(0, Int64(attributes.st_size)))
    }

    private static func regularSize(_ url: URL) throws -> Int64 {
        guard let metadata = try item(url), metadata.kind == .file else { return 0 }
        return metadata.bytes
    }

    private static func children(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    private static func matches(_ value: String, _ expression: String) -> Bool {
        guard let range = value.range(of: expression, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }

    private static func failure(_ key: String) -> AnalysisFailure {
        AnalysisFailure(L10n.string("storageCore.error." + key))
    }
}
