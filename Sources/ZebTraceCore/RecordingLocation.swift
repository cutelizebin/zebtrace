import Foundation

/// Stores the user's destination independently of any active recording session.
public final class RecordingLocation {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZebTrace", isDirectory: true)
    }

    private let defaults: UserDefaults
    private let fallbackDirectory: URL
    private let key = "recordingsDirectoryPath"

    public init(defaults: UserDefaults = .standard, defaultDirectory: URL = RecordingLocation.defaultDirectory) {
        self.defaults = defaults
        fallbackDirectory = defaultDirectory
    }

    public var hasCustomDirectory: Bool { defaults.string(forKey: key) != nil }

    public var directory: URL {
        guard let path = defaults.string(forKey: key) else { return fallbackDirectory }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Retain previous roots so data remains visible after changing destination.
    public var knownDirectories: [URL] {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let priorDefaults = [fallbackDirectory, downloads.appendingPathComponent("MyContext"),
                             support.appendingPathComponent("MyContext/Recordings"),
                             support.appendingPathComponent("ZebTrace/Recordings"),
                             support.appendingPathComponent("ZebTrace")]
            .filter { url in
                if url == support.appendingPathComponent("ZebTrace") {
                    let models = url.appendingPathComponent("Models")
                    return ((try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? []).isEmpty == false
                }
                return FileManager.default.fileExists(atPath: url.path)
            }.map(\.path)
        let paths = [directory.path] + (defaults.stringArray(forKey: "storage.previousRoots") ?? []) + priorDefaults
        var seen = Set<String>()
        return paths.compactMap { path in
            guard path.hasPrefix("/"), !path.contains("\0"), seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    public func validateSelection(_ directory: URL) throws { try validate(directory) }

    public func select(_ directory: URL) throws {
        try validate(directory)
        let history = knownDirectories.map(\.path)
        defaults.set(history, forKey: "storage.previousRoots")
        defaults.set(directory.standardizedFileURL.path, forKey: key)
    }

    public func prepareForRecording() throws -> URL {
        let destination = directory
        if !hasCustomDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        // An unavailable custom volume must never be silently recreated or replaced.
        try validate(destination)
        return destination
    }

    private func validate(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
              FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LocationError.unavailable(directory.path)
        }
        let probe = directory.appendingPathComponent(".zebtrace-write-check-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw LocationError.notWritable(directory.path, error)
        }
    }

    private enum LocationError: LocalizedError {
        case unavailable(String)
        case notWritable(String, Error)

        var errorDescription: String? {
            switch self {
            case .unavailable(let path):
                return L10n.string("location.error.unavailable", path)
            case .notWritable(let path, let error):
                return L10n.string("location.error.notWritable", path, error.localizedDescription)
            }
        }
    }
}
