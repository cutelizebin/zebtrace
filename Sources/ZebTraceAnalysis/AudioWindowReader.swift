import AVFoundation
import Foundation
import ZebTraceCore

/// Independent short windows allow language detection to run again after a
/// speaker/language change. A low-energy boundary near 20 seconds reduces cuts
/// through words. Sample offsets always refer to the original normalized track.
final class AudioWindowReader {
    struct Window {
        let startFrame: AVAudioFramePosition
        let frames: AVAudioFrameCount
        let hasSignal: Bool
        var start: Double { Double(startFrame) / 16_000 }
        var duration: Double { Double(frames) / 16_000 }
    }
    private let source: AVAudioFile
    private var position: AVAudioFramePosition = 0

    init(_ audio: URL) throws { source = try AVAudioFile(forReading: audio) }

    func next(to output: URL) throws -> Window? {
        try Task.checkCancellation()
        let remaining = source.length - position
        guard remaining > 0 else { return nil }
        // Keep short tails with the preceding window instead of asking ASR to
        // decode a sub-second trailing fragment/noise floor on its own.
        let readFrames = min(remaining, remaining <= 24 * 16_000 ? remaining : 22 * 16_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                            frameCapacity: AVAudioFrameCount(readFrames)) else {
            throw AnalysisFailure(L10n.string("review.error.allocate"))
        }
        source.framePosition = position
        try source.read(into: buffer, frameCount: buffer.frameCapacity)
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { return nil }
        var frames = Int(buffer.frameLength)
        if remaining > 24 * 16_000 {
            var minimum = Double.greatestFiniteMagnitude
            var boundary = 20 * 16_000
            for candidate in stride(from: 17 * 16_000, to: min(frames - 320, 22 * 16_000), by: 320) {
                var energy = 0.0
                for frame in candidate..<(candidate + 320) { energy += Double(samples[frame] * samples[frame]) }
                // The small distance penalty selects near 20s during true silence.
                let score = energy / 320 + Double(abs(candidate - 20 * 16_000)) * 1e-14
                if score < minimum { minimum = score; boundary = candidate + 160 }
            }
            frames = boundary
        }
        let hasSignal = (0..<frames).contains { samples[$0] != 0 }
        buffer.frameLength = AVAudioFrameCount(frames)
        let file = try AVAudioFile(forWriting: output, settings: source.fileFormat.settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        try file.write(from: buffer)
        let window = Window(startFrame: position, frames: buffer.frameLength, hasSignal: hasSignal)
        position += AVAudioFramePosition(frames)
        return window
    }
}
