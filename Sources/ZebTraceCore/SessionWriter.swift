import AVFoundation
import Foundation

/// Confined to one queue. Audio callbacks must never call this disk writer directly.
public final class SessionWriter {
    public static var defaultRecordingsURL: URL {
        RecordingLocation.defaultDirectory
    }

    public let directory: URL
    public private(set) var manifest: SessionManifest
    private let chunkDuration: Double
    private var tracks: [AudioSource: Track] = [:]
    private var lastCheckpoint: Double = 0
    private var closed = false
    private var finishError: Error?

    private final class Track {
        var file: AVAudioFile?
        let index: Int
        let format: AVAudioFormat
        var lastEndOffset: Double
        init(file: AVAudioFile, index: Int, format: AVAudioFormat, offset: Double) {
            self.file = file
            self.index = index
            self.format = format
            self.lastEndOffset = offset
        }
    }

    public init(root: URL = SessionWriter.defaultRecordingsURL,
                chunkDuration: Double = RecordingSegmentLength.defaultValue.duration,
                startedAt: Date = Date(),
                hostTimeOrigin: UInt64 = mach_absolute_time()) throws {
        guard chunkDuration.isFinite, chunkDuration > 0 else { throw RecordingError.invalidAudio }
        self.chunkDuration = chunkDuration
        let id = UUID()
        directory = try SessionDirectory.create(in: root, startedAt: startedAt)
        manifest = SessionManifest(id: id, startedAt: startedAt, updatedAt: startedAt,
                                   status: .recording, chunkDurationSeconds: chunkDuration,
                                   hostTimeOrigin: hostTimeOrigin,
                                   hostClockTicksPerSecond: 1 / AVAudioTime.seconds(forHostTime: 1), chunks: [],
                                   directoryName: directory.lastPathComponent)
        try checkpoint()
    }

    public func append(_ buffer: AVAudioPCMBuffer, source: AudioSource, hostTime: UInt64) throws {
        guard !closed else { throw RecordingError.closed }
        guard buffer.frameLength > 0 else { return }
        guard buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
              (1...2).contains(buffer.format.channelCount) else { throw RecordingError.invalidAudio }
        // A device can report a first buffer that began just before Start was clicked.
        let offset: Double
        if hostTime >= manifest.hostTimeOrigin {
            offset = AVAudioTime.seconds(forHostTime: hostTime - manifest.hostTimeOrigin)
        } else {
            let lead = AVAudioTime.seconds(forHostTime: manifest.hostTimeOrigin - hostTime)
            guard lead < 1 else { throw RecordingError.clockBeforeSession }
            offset = -lead
        }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        if let track = tracks[source] {
            let chunk = manifest.chunks[track.index]
            let formatChanged = !track.format.isEqual(buffer.format)
            let gap = abs(offset - track.lastEndOffset) > 0.1
            if formatChanged || gap || chunk.durationSeconds >= chunkDuration ||
                offset - chunk.startOffsetSeconds >= chunkDuration {
                closeTrack(source)
            }
        }
        if tracks[source] == nil {
            try openTrack(source, format: buffer.format, offset: offset)
        }
        guard let track = tracks[source], let file = track.file else { throw RecordingError.closed }
        try file.write(from: buffer)
        manifest.chunks[track.index].frameCount += UInt64(buffer.frameLength)
        manifest.chunks[track.index].durationSeconds = Double(manifest.chunks[track.index].frameCount) / buffer.format.sampleRate
        track.lastEndOffset = offset + duration
        manifest.updatedAt = max(manifest.updatedAt, manifest.startedAt.addingTimeInterval(max(0, offset + duration)))
        if offset - lastCheckpoint >= 5 {
            try checkpoint()
            lastCheckpoint = offset
        }
    }

    public func finish(status: SessionStatus = .completed, reason: String = "userPaused", at: Date = Date()) throws {
        guard !closed else {
            if let finishError { throw finishError }
            return
        }
        closed = true
        for source in AudioSource.allCases { closeTrack(source) }
        manifest.status = status
        manifest.endReason = reason
        manifest.endedAt = at
        manifest.updatedAt = at
        do { try checkpoint() }
        catch {
            // Closing the audio files is irreversible even if the final manifest cannot be saved.
            finishError = error
            throw error
        }
    }

    private func openTrack(_ source: AudioSource, format: AVAudioFormat, offset: Double) throws {
        let sequence = manifest.chunks.filter { $0.source == source }.count + 1
        let name = String(format: "%@-%05d.m4a", source.rawValue, sequence)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: format.channelCount == 1 ? 64_000 : 128_000,
        ]
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        let index = manifest.chunks.count
        manifest.chunks.append(AudioChunk(source: source, file: name, startOffsetSeconds: offset,
                                         durationSeconds: 0, sampleRate: format.sampleRate,
                                         channels: format.channelCount, frameCount: 0, finalized: false))
        tracks[source] = Track(file: file, index: index, format: format, offset: offset)
        try checkpoint()
    }

    private func closeTrack(_ source: AudioSource) {
        guard let track = tracks.removeValue(forKey: source) else { return }
        // AVAudioFile finalizes the AAC container when its last reference is released.
        track.file = nil
        manifest.chunks[track.index].finalized = true
    }

    private func checkpoint() throws {
        let encoder = Self.encoder()
        let url = directory.appendingPathComponent("session.json")
        try encoder.encode(manifest).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Call only after acquiring the app's single-instance lock, before starting capture.
    /// Finalized chunks remain usable; an in-flight AAC file may need to be discarded.
    @discardableResult
    public static func recoverInterruptedSessions(at root: URL = defaultRecordingsURL) throws -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return 0 }
        let directoryKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let days = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: directoryKeys,
                                                   options: [.skipsHiddenFiles])
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.isLenient = false
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var recovered = 0
        var recoveryError: Error?

        // A user-selected root may also contain documents and other applications.
        // Only inspect the two directory levels created by SessionWriter; never
        // recurse into arbitrary descendants or follow links out of that layout.
        for day in days {
            let dayName = day.lastPathComponent
            guard dayName.count == 10, let date = dateFormatter.date(from: dayName),
                  dateFormatter.string(from: date) == dayName else { continue }
            do {
                guard try isRecoveryDirectory(day) else { continue }
                let sessions = try manager.contentsOfDirectory(at: day, includingPropertiesForKeys: directoryKeys,
                                                               options: [.skipsHiddenFiles])
                for session in sessions {
                    let name = session.lastPathComponent
                    let legacyID = SessionDirectory.legacyID(from: name)
                    guard legacyID != nil || SessionDirectory.isTimestampName(name, day: dayName) else { continue }
                    do {
                        guard try isRecoveryDirectory(session) else { continue }
                        let file = session.appendingPathComponent("session.json")
                        guard manager.fileExists(atPath: file.path) else { continue }
                        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                        var manifest = try decoder.decode(SessionManifest.self, from: Data(contentsOf: file))
                        guard manifest.schemaVersion == 1, manifest.status == .recording else { continue }
                        if let legacyID {
                            guard manifest.id == legacyID else { continue }
                        } else {
                            guard manifest.directoryName == name else { continue }
                        }
                        manifest.status = .interrupted
                        manifest.endedAt = manifest.updatedAt
                        manifest.endReason = "appInterrupted"
                        try encoder().encode(manifest).write(to: file, options: .atomic)
                        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                        recovered += 1
                    } catch {
                        // Preserve damaged metadata, continue with every other
                        // recognized session, and report the first failure afterward.
                        recoveryError = recoveryError ?? error
                    }
                }
            } catch {
                recoveryError = recoveryError ?? error
            }
        }
        if let recoveryError { throw recoveryError }
        return recovered
    }

    private static func isRecoveryDirectory(_ directory: URL) throws -> Bool {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        return values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true
    }

}
