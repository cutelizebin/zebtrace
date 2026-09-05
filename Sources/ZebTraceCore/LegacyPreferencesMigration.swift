import Foundation

/// Imports the two recording preferences from MyContext once, without moving any files.
public enum LegacyPreferencesMigration {
    public static let legacyBundleIdentifier = "org.mycontext.app"
    private static let completionKey = "legacyMyContextPreferencesMigrationV1Completed"
    private static let directoryKey = "recordingsDirectoryPath"
    private static let segmentLengthKey = "recordingSegmentLengthSeconds"

    /// The app calls this explicitly after acquiring its instance lock.
    /// Tests should use migrate(into:source:) to avoid reading the user's old domain.
    @discardableResult
    public static func migrateFromLegacyDomain(into defaults: UserDefaults = .standard) -> Set<String> {
        guard !defaults.bool(forKey: completionKey) else { return [] }
        let source = UserDefaults.standard.persistentDomain(forName: legacyBundleIdentifier) ?? [:]
        return migrate(into: defaults, source: source)
    }

    /// Existing destination values win, including an explicitly selected custom directory.
    /// Missing external disks are not validated here: retain the user's choice for reconnection.
    @discardableResult
    public static func migrate(into defaults: UserDefaults, source: [String: Any]) -> Set<String> {
        guard !defaults.bool(forKey: completionKey) else { return [] }
        var migrated: Set<String> = []
        if defaults.object(forKey: directoryKey) == nil,
           let path = source[directoryKey] as? String,
           path.hasPrefix("/"), !path.contains("\0") {
            defaults.set(path, forKey: directoryKey)
            migrated.insert(directoryKey)
        }
        if defaults.object(forKey: segmentLengthKey) == nil,
           let seconds = source[segmentLengthKey] as? Int,
           RecordingSegmentLength(rawValue: seconds) != nil {
            defaults.set(seconds, forKey: segmentLengthKey)
            migrated.insert(segmentLengthKey)
        }
        defaults.set(true, forKey: completionKey)
        return migrated
    }
}
