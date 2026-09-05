import Foundation

public enum RecordingSegmentLength: Int, CaseIterable {
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600
    case thirtyMinutes = 1_800
    case sixtyMinutes = 3_600

    public static let defaultValue = RecordingSegmentLength.tenMinutes
    public var duration: TimeInterval { TimeInterval(rawValue) }
    public var title: String {
        L10n.string(self == .oneMinute ? "duration.minute" : "duration.minutes", rawValue / 60)
    }
}

/// Preferences are snapshotted when starting a session, never applied mid-recording.
public final class RecordingPreferences {
    private let defaults: UserDefaults
    private let key = "recordingSegmentLengthSeconds"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var segmentLength: RecordingSegmentLength {
        get { RecordingSegmentLength(rawValue: defaults.integer(forKey: key)) ?? .defaultValue }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }
}
