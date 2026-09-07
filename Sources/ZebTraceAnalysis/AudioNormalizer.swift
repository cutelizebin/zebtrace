import AVFoundation
import Foundation
import ZebTraceCore

enum AudioNormalizer {
    /// Streaming conversion uses Apple's audio frameworks, with bounded buffers.
    /// The temporary WAV is removed after its chunk has been transcribed.
    static func convert(_ input: URL, to output: URL) throws -> Double {
        let source = try AVAudioFile(forReading: input)
        guard source.length > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source.processingFormat, to: format),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw AnalysisFailure(L10n.string("review.error.decode"))
        }
        let destination = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        var totalFrames: Int64 = 0
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, status in
                do {
                    // Some AAC readers throw a generic Foundation error when
                    // read is called again exactly at the declared end.
                    let remaining = source.length - source.framePosition
                    guard remaining > 0 else { status.pointee = .endOfStream; return nil }
                    let count = min(Int64(requested), Int64(inputBuffer.frameCapacity), remaining)
                    try source.read(into: inputBuffer, frameCount: AVAudioFrameCount(count))
                    status.pointee = inputBuffer.frameLength == 0 ? .endOfStream : .haveData
                    return inputBuffer.frameLength == 0 ? nil : inputBuffer
                } catch {
                    readError = error
                    status.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 {
                try destination.write(from: outputBuffer)
                totalFrames += Int64(outputBuffer.frameLength)
            }
            if status == .endOfStream { break }
            if status == .error { throw AnalysisFailure(L10n.string("review.error.convert")) }
        }
        return Double(totalFrames) / 16_000
    }
}
