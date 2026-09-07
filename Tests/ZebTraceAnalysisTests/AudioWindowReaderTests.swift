import AVFoundation
import Foundation
import XCTest
@testable import ZebTraceAnalysis

final class AudioWindowReaderTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTraceAudioWindowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
    }

    func testWindowsCoverEveryFrameContiguouslyAndPreserveTheirAudioSamples() throws {
        let frameCount = 45 * 16_000 + 137
        let input = try writeFixture(frames: frameCount, silent: false)
        let reader = try AudioWindowReader(input)
        var consumed: Int64 = 0
        var windowCount = 0
        while true {
            let output = temporaryRoot.appendingPathComponent("window-\(windowCount).wav")
            guard let window = try reader.next(to: output) else { break }
            XCTAssertEqual(window.startFrame, consumed)
            XCTAssertGreaterThan(window.frames, 0)
            XCTAssertLessThanOrEqual(window.frames, 24 * 16_000)
            XCTAssertTrue(window.hasSignal)
            let audio = try AVAudioFile(forReading: output)
            XCTAssertEqual(audio.length, Int64(window.frames))
            let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                                       frameCapacity: window.frames))
            try audio.read(into: decoded)
            let samples = try XCTUnwrap(decoded.floatChannelData)[0]
            for frame in [0, Int(window.frames) / 2, Int(window.frames) - 1] {
                let globalFrame = Int(window.startFrame) + frame
                XCTAssertEqual(samples[frame], expectedSample(at: globalFrame), accuracy: 2.0 / 32_768)
            }
            consumed += Int64(window.frames)
            windowCount += 1
        }
        XCTAssertGreaterThan(windowCount, 1)
        XCTAssertEqual(consumed, Int64(frameCount))
    }

    func testDigitalSilenceIsIdentifiedWithoutDiscardingItsTimelineDuration() throws {
        let input = try writeFixture(frames: 2_137, silent: true)
        let reader = try AudioWindowReader(input)
        let window = try XCTUnwrap(reader.next(to: temporaryRoot.appendingPathComponent("silent-window.wav")))
        XCTAssertEqual(window.startFrame, 0)
        XCTAssertEqual(window.frames, 2_137)
        XCTAssertEqual(window.duration, 2_137.0 / 16_000, accuracy: 0.000_001)
        XCTAssertFalse(window.hasSignal)
        XCTAssertNil(try reader.next(to: temporaryRoot.appendingPathComponent("after-end.wav")))
    }

    private func writeFixture(frames: Int, silent: Bool) throws -> URL {
        let input = temporaryRoot.appendingPathComponent("input.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<frames { samples[frame] = silent ? 0 : expectedSample(at: frame) }
        let file = try AVAudioFile(forWriting: input, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return input
    }

    private func expectedSample(at frame: Int) -> Float {
        Float(frame % 257 - 128) / 512
    }
}
