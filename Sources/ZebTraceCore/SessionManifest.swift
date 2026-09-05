import Foundation

public enum SessionStatus: String, Codable {
    case recording, completed, interrupted, failed
}

public struct AudioChunk: Codable {
    public var source: AudioSource
    public var file: String
    public var startOffsetSeconds: Double
    public var durationSeconds: Double
    public var sampleRate: Double
    public var channels: UInt32
    public var frameCount: UInt64
    public var finalized: Bool
}

/// Versioned, portable metadata. Offsets preserve gaps instead of concatenating time away.
public struct SessionManifest: Codable {
    public var schemaVersion = 1
    public var id: UUID
    public var startedAt: Date
    public var updatedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var endReason: String?
    public var chunkDurationSeconds: Double
    public var hostTimeOrigin: UInt64
    public var hostClockTicksPerSecond: Double
    public var chunks: [AudioChunk]
}

public enum RecordingError: LocalizedError {
    case closed
    case invalidAudio
    case clockBeforeSession
    case overloaded
    case insufficientDiskSpace

    public var errorDescription: String? {
        switch self {
        case .closed: return L10n.string("recording.error.closed")
        case .invalidAudio: return L10n.string("recording.error.invalidAudio")
        case .clockBeforeSession: return L10n.string("recording.error.clockBeforeSession")
        case .overloaded: return L10n.string("recording.error.overloaded")
        case .insufficientDiskSpace: return L10n.string("recording.error.insufficientDiskSpace")
        }
    }
}
