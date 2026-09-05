import AVFoundation
import Foundation

public struct SourceActivity {
    public var buffers: UInt64 = 0
    public var lastReceivedAt: Date?
    public var peak: Float = 0
}

/// Bounds pending audio and performs all encoding and metadata writes away from audio callbacks.
public final class RecordingPipeline {
    public let directory: URL
    private let queue = DispatchQueue(label: "org.zebtrace.recording-writer", qos: .utility)
    private let lock = NSLock()
    private let writer: SessionWriter
    private let onError: (Error) -> Void
    private var accepting = true
    private var pending = 0
    private var activities: [AudioSource: SourceActivity] = [:]
    private var writeError: Error?
    private var finishResult: Result<URL, Error>?
    private var errorReported = false
    private var lastDiskCheck = Date.distantPast
    private let maximumPendingBuffers: Int

    public init(root: URL = SessionWriter.defaultRecordingsURL,
                chunkDuration: Double = RecordingSegmentLength.defaultValue.duration,
                maximumPendingBuffers: Int = 256, onError: @escaping (Error) -> Void) throws {
        writer = try SessionWriter(root: root, chunkDuration: chunkDuration)
        directory = writer.directory
        self.maximumPendingBuffers = maximumPendingBuffers
        self.onError = onError
    }

    public func append(_ buffer: AVAudioPCMBuffer, source: AudioSource, hostTime: UInt64) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        guard pending < maximumPendingBuffers else {
            accepting = false
            queue.async { [self] in fail(RecordingError.overloaded) }
            lock.unlock()
            return
        }
        pending += 1
        // Enqueue under the lock so finish always follows every accepted buffer.
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            guard writeError == nil else { return }
            do {
                if Date().timeIntervalSince(lastDiskCheck) > 5 {
                    let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    if let remaining = values.volumeAvailableCapacityForImportantUsage, remaining < 500_000_000 {
                        throw RecordingError.insufficientDiskSpace
                    }
                    lastDiskCheck = Date()
                }
                try writer.append(buffer, source: source, hostTime: hostTime)
                let peak = Self.peak(of: buffer)
                lock.lock()
                var activity = activities[source] ?? SourceActivity()
                activity.buffers += 1
                activity.lastReceivedAt = Date()
                activity.peak = peak
                activities[source] = activity
                lock.unlock()
            } catch { fail(error) }
        }
        lock.unlock()
    }

    public func snapshot() -> [AudioSource: SourceActivity] {
        lock.lock(); defer { lock.unlock() }
        return activities
    }

    public func finish(status: SessionStatus = .completed, reason: String = "userPaused",
                       completion: @escaping (Result<URL, Error>) -> Void) {
        let endedAt = Date()
        lock.lock()
        accepting = false
        queue.async { [self] in
            if let finishResult {
                completion(finishResult)
                return
            }
            let result: Result<URL, Error>
            do {
                try writer.finish(status: writeError == nil ? status : .failed,
                                  reason: writeError == nil ? reason : "writeFailed", at: endedAt)
                if let writeError { result = .failure(writeError) }
                else { result = .success(directory) }
            } catch { result = .failure(error) }
            finishResult = result
            completion(result)
        }
        lock.unlock()
    }

    private func fail(_ error: Error) {
        writeError = writeError ?? error
        lock.lock(); accepting = false; lock.unlock()
        guard !errorReported else { return }
        errorReported = true
        onError(error)
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        var peak: Float = 0
        // Metering is deliberately inexpensive; sample a subset of each channel.
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = buffer.format.isInterleaved ? channels[0] + channel : channels[channel]
            for frame in Swift.stride(from: 0, to: count, by: 16) {
                peak = max(peak, abs(samples[frame * stride]))
            }
        }
        return peak
    }
}
