import Foundation
import XCTest
@testable import ZebTraceAnalysis

final class RecordingTranscriptTests: XCTestCase {
    func testParagraphSectionsPreserveEveryParagraphInOrder() {
        let paragraphs = (0..<12).map { "Point \($0): Keep this entire recording observation." }
        let original = paragraphs.joined(separator: "\n\n")
        let sections = RecordingTranscript.sections(original, maximumCharacters: 110)
        XCTAssertGreaterThan(sections.count, 1)
        XCTAssertTrue(sections.allSatisfy { !$0.isEmpty && $0.count <= 110 })
        XCTAssertEqual(sections.joined(separator: "\n\n"), original)
    }

    func testLongUnicodeParagraphIsSplitWithoutTruncatingOrDuplicatingCharacters() {
        let original = String(repeating: "录音观点👨‍👩‍👧‍👦e\u{301}。", count: 40)
        let sections = RecordingTranscript.sections(original, maximumCharacters: 37)
        XCTAssertGreaterThan(sections.count, 1)
        XCTAssertTrue(sections.allSatisfy { !$0.isEmpty && $0.count <= 37 })
        XCTAssertEqual(sections.joined(), original)
    }

    func testDefaultUTF8BudgetBoundsMixedLanguageEvidenceWithoutLosingText() {
        let original = String(repeating: "录音总结 mixed-language evidence 🙂。", count: 300)
        let sections = RecordingTranscript.sections(original)
        XCTAssertGreaterThan(sections.count, 1)
        XCTAssertTrue(sections.allSatisfy { !$0.isEmpty && $0.utf8.count <= 5000 && $0.count <= 6000 })
        XCTAssertEqual(sections.joined(), original)
    }

    func testParagraphSeparatorBytesCountTowardTheBudget() {
        let first = String(repeating: "甲", count: 4)
        let second = String(repeating: "乙", count: 4)
        let original = first + "\n\n" + second
        XCTAssertEqual(original.utf8.count, 26)
        let split = RecordingTranscript.sections(original, maximumCharacters: 100, maximumUTF8Bytes: 25)
        XCTAssertEqual(split, [first, second])
        XCTAssertEqual(split.joined(separator: "\n\n"), original)
        XCTAssertEqual(RecordingTranscript.sections(original, maximumCharacters: 100, maximumUTF8Bytes: 26), [original])
    }

    func testExceptionallyLargeGraphemeSplitsAtScalarBoundariesWithoutLosingBytes() {
        let original = "a" + String(repeating: "\u{0301}", count: 3000)
        XCTAssertEqual(original.count, 1)
        let sections = RecordingTranscript.sections(original, maximumCharacters: 1, maximumUTF8Bytes: 31)
        XCTAssertGreaterThan(sections.count, 1)
        XCTAssertTrue(sections.allSatisfy { !$0.isEmpty && $0.count <= 1 && $0.utf8.count <= 31 })
        XCTAssertEqual(Array(sections.joined().utf8), Array(original.utf8))
        for section in sections {
            XCTAssertEqual(String(data: Data(section.utf8), encoding: .utf8), section)
        }
    }

    func testBothBudgetsApplyWhenEmojiAndCombiningCharactersAreMixed() {
        let original = String(repeating: "A🙂中e\u{301}", count: 80)
        let sections = RecordingTranscript.sections(original, maximumCharacters: 5, maximumUTF8Bytes: 23)
        XCTAssertGreaterThan(sections.count, 1)
        XCTAssertTrue(sections.allSatisfy { !$0.isEmpty && $0.count <= 5 && $0.utf8.count <= 23 })
        XCTAssertEqual(sections.joined(), original)
    }

    func testSubstantialOverlappingCrossTrackDuplicateIsAnnotatedWithoutDeletingEitherOriginal() {
        let system = entry("system", source: "system", start: 10, end: 20,
                           text: "We will ship the reviewed feature next Friday.")
        let microphone = entry("microphone", source: "microphone", start: 12, end: 18,
                               text: "WE WILL SHIP THE REVIEWED FEATURE NEXT FRIDAY!")
        let marked = RecordingTranscript.markPossibleDuplicates([microphone, system])
        XCTAssertEqual(marked.map(\.id), [system.id, microphone.id])
        XCTAssertEqual(marked.map(\.text), [system.text, microphone.text])
        XCTAssertNil(marked[0].possibleDuplicateOf)
        XCTAssertEqual(marked[1].possibleDuplicateOf, system.id)
        let evidence = RecordingTranscript.evidence(marked, language: .english)
        XCTAssertTrue(evidence.contains(system.text))
        XCTAssertTrue(evidence.contains(microphone.text))
        XCTAssertTrue(evidence.contains("possible duplicate capture"))
    }

    func testSameTrackShortRepliesAndNonoverlappingStatementsAreNeverMarkedDuplicates() {
        let text = "This detailed planning statement must remain in the transcript."
        let cases: [[TranscriptEntry]] = [
            [entry("a", source: "system", start: 0, end: 10, text: text),
             entry("b", source: "system", start: 1, end: 9, text: text)],
            [entry("a", source: "system", start: 0, end: 10, text: "Yes"),
             entry("b", source: "microphone", start: 1, end: 9, text: "Yes")],
            [entry("a", source: "system", start: 0, end: 10, text: text),
             entry("b", source: "microphone", start: 10, end: 20, text: text)],
            [entry("a", source: "system", start: 0, end: 10, text: text),
             entry("b", source: "microphone", start: 9, end: 19, text: text)],
        ]
        for entries in cases {
            let marked = RecordingTranscript.markPossibleDuplicates(entries)
            XCTAssertEqual(marked.count, entries.count)
            XCTAssertTrue(marked.allSatisfy { $0.possibleDuplicateOf == nil })
            XCTAssertEqual(marked.map(\.text), entries.map(\.text))
        }
    }

    private func entry(_ id: String, source: String, start: Double, end: Double, text: String) -> TranscriptEntry {
        .init(id: id, source: source, file: "\(source).m4a", start: start, end: end, text: text)
    }
}
