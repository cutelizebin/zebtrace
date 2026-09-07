import AVFoundation
import Foundation
import XCTest
import ZebTraceCore
@testable import ZebTraceAnalysis

final class AudioNormalizerTests: XCTestCase {
    func testAACNormalizesToCompleteDecodableNonSilent16kHzMonoWAV() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTraceNormalizationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = mach_absolute_time()
        let writer = try SessionWriter(root: root, hostTimeOrigin: origin)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let samples = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<48_000 {
                samples[channel][frame] = Float(0.4 * sin(2 * .pi * 440 * Double(frame) / 48_000))
            }
        }
        try writer.append(buffer, source: .system, hostTime: origin)
        try writer.finish()
        let chunk = try XCTUnwrap(writer.manifest.chunks.first)
        let input = writer.directory.appendingPathComponent(chunk.file)
        let source = try AVAudioFile(forReading: input)
        let output = root.appendingPathComponent("normalized.wav")
        let duration = try AudioNormalizer.convert(input, to: output)
        let normalized = try AVAudioFile(forReading: output)

        XCTAssertEqual(normalized.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(normalized.processingFormat.channelCount, 1)
        XCTAssertEqual(normalized.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        XCTAssertEqual(Double(normalized.length), Double(source.length) / 3, accuracy: 2)
        XCTAssertEqual(duration, Double(normalized.length) / 16_000, accuracy: 0.000_001)
        let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: normalized.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(normalized.length)))
        try normalized.read(into: decoded)
        XCTAssertEqual(Int64(decoded.frameLength), normalized.length)
        let data = try XCTUnwrap(decoded.floatChannelData)[0]
        var energy: Double = 0
        for frame in 0..<Int(decoded.frameLength) { energy += Double(data[frame] * data[frame]) }
        XCTAssertGreaterThan(sqrt(energy / Double(decoded.frameLength)), 0.1)
    }
}
