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

    public func select(_ directory: URL) throws {
        try validate(directory)
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
