import Foundation
import XCTest
@testable import ZebTraceAnalysis

final class WhisperProviderTests: XCTestCase {
    func testWhisperMillisecondOffsetsAreConvertedToSeconds() throws {
        let json = #"{"transcription":[{"offsets":{"from":1250.5,"to":2875},"text":"  Review on Friday. \n"}]}"#
        let segments = try WhisperProvider.parse(Data(json.utf8))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 1.2505, accuracy: 0.000_001)
        XCTAssertEqual(segments[0].end, 2.875, accuracy: 0.000_001)
        XCTAssertEqual(segments[0].text, "Review on Friday.")
    }

    func testNonSpeechMarkersAreFilteredWhileActualSpeechIsRetained() throws {
        let texts = ["  ", "[BLANK_AUDIO]", "[MUSIC]", "(Music)", "[Silence]", " Actual speech. "]
        let data = try JSONSerialization.data(withJSONObject: ["transcription": texts.map {
            ["offsets": ["from": 0, "to": 1000], "text": $0] as [String: Any]
        }])
        let segments = try WhisperProvider.parse(data)
        XCTAssertEqual(segments.map(\.text), ["Actual speech."])
    }

    func testNegativeReversedNonfiniteAndMalformedOffsetsAreRejected() {
        let offsets = [
            #"{"from":-1,"to":1000}"#,
            #"{"from":1000,"to":999}"#,
            #"{"from":0,"to":1e309}"#,
            #"{"from":"NaN","to":1000}"#,
            #"{"from":null,"to":1000}"#,
            #"{"to":1000}"#,
        ]
        for value in offsets {
            let json = "{\"transcription\":[{\"offsets\":\(value),\"text\":\"speech\"}]}"
            XCTAssertThrowsError(try WhisperProvider.parse(Data(json.utf8)), value)
        }
    }
}
