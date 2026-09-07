import Foundation
import ZebTraceCore

struct TranscriptEntry: Codable, Sendable {
    let id: String
    let source: String
    let file: String
    let start: Double
    let end: Double
    let text: String
    var possibleDuplicateOf: String?
}

enum RecordingTranscript {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--:--" }
        let value = Int(min(Double(Int.max / 2), max(0, seconds)))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }

    /// Deliberately conservative: annotate exact substantial cross-track matches
    /// that overlap in time. Never erase either track or label all overlap echo.
    static func markPossibleDuplicates(_ input: [TranscriptEntry]) -> [TranscriptEntry] {
        var sorted = input.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        for index in sorted.indices {
            let current = sorted[index]
            let normalized = normalize(current.text)
            guard normalized.count >= 12 else { continue }
            for previous in (0..<index).reversed() {
                let candidate = sorted[previous]
                guard candidate.end >= current.start else { continue }
                guard candidate.source != current.source, normalize(candidate.text) == normalized else { continue }
                let overlap = min(current.end, candidate.end) - max(current.start, candidate.start)
                let shorter = min(current.end - current.start, candidate.end - candidate.start)
                guard shorter > 0, overlap / shorter >= 0.5 else { continue }
                sorted[index].possibleDuplicateOf = candidate.id
                break
            }
        }
        return sorted
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func evidence(_ entries: [TranscriptEntry], language: AppLanguage) -> String {
        entries.map { entry in
            let source = L10n.string("source." + entry.source, language: language)
            let duplicate = entry.possibleDuplicateOf == nil ? "" : L10n.string("review.transcript.duplicate", language: language)
            return "[\(time(entry.start))] [\(source)\(duplicate)] \(entry.text)"
        }.joined(separator: "\n\n")
    }

    /// Prefer paragraph boundaries while bounding both characters and UTF-8 bytes,
    /// including separators inside a section. A paragraph separator at a section
    /// boundary is represented by the boundary itself, as in the original API.
    static func sections(_ text: String, maximumCharacters: Int = 6000,
                         maximumUTF8Bytes: Int = 5000) -> [String] {
        precondition(maximumCharacters > 0)
        precondition(maximumUTF8Bytes >= 4, "The byte budget must accommodate any Unicode scalar.")
        var result: [String] = []
        var remaining = text
        while !remaining.isEmpty {
            var boundary = remaining.startIndex
            var characters = 0
            var bytes = 0
            while boundary < remaining.endIndex, characters < maximumCharacters {
                let next = remaining.index(after: boundary)
                let nextBytes = remaining[boundary..<next].utf8.count
                guard nextBytes <= maximumUTF8Bytes - bytes else { break }
                bytes += nextBytes
                characters += 1
                boundary = next
            }
            if boundary == remaining.endIndex {
                result.append(remaining)
                break
            }
            if boundary == remaining.startIndex {
                // One grapheme can contain thousands of combining scalars. Split
                // that exceptional case at scalar boundaries, never within UTF-8.
                let scalars = remaining.unicodeScalars
                var scalarBoundary = scalars.startIndex
                var fragment = ""
                bytes = 0
                while scalarBoundary < scalars.endIndex {
                    let scalar = scalars[scalarBoundary]
                    let scalarText = String(scalar)
                    guard scalarText.utf8.count <= maximumUTF8Bytes - bytes,
                          (fragment + scalarText).count <= maximumCharacters else { break }
                    fragment.unicodeScalars.append(scalar)
                    bytes += scalarText.utf8.count
                    scalarBoundary = scalars.index(after: scalarBoundary)
                }
                result.append(fragment)
                remaining = String(scalars[scalarBoundary...])
            } else if let separator = remaining.range(of: "\n\n", options: .backwards,
                                                       range: remaining.startIndex..<boundary),
                      separator.lowerBound != remaining.startIndex {
                result.append(String(remaining[..<separator.lowerBound]))
                remaining = String(remaining[separator.upperBound...])
            } else {
                result.append(String(remaining[..<boundary]))
                remaining = String(remaining[boundary...])
                if remaining.hasPrefix("\n\n") { remaining.removeFirst(2) }
            }
        }
        return result
    }
}
