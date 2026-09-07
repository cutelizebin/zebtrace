import Foundation
import ZebTraceCore

public struct SpeechSegment: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

/// Providers only see normalized audio or text. Session paths, dual-track
/// timelines, caching and result persistence belong to the coordinator.
public protocol TranscriptionProvider: Sendable {
    func transcribe(audio: URL, workDirectory: URL) async throws -> [SpeechSegment]
}

public protocol SummarizationProvider: Sendable {
    func summarize(text: String, language: String, combiningNotes: Bool, workDirectory: URL) async throws -> String
}

struct WhisperProvider: TranscriptionProvider {
    let executable: URL
    let model: URL

    func transcribe(audio: URL, workDirectory: URL) async throws -> [SpeechSegment] {
        let prefix = workDirectory.appendingPathComponent(UUID().uuidString)
        let output = prefix.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: output) }
        let vad = model.deletingLastPathComponent().appendingPathComponent("ggml-silero-v6.2.0.bin")
        try AnalysisFiles.regularFile(vad)
        _ = try await InferenceProcess().run(executable: executable, arguments: [
            "-m", model.path, "-f", audio.path, "-l", "auto", "-oj", "-of", prefix.path,
            "-t", "4", "-np", "--vad", "-vm", vad.path, "-vsd", "500", "-vp", "200",
        ], workingDirectory: workDirectory)
        try Task.checkCancellation()
        return try Self.parse(Data(contentsOf: output))
    }

    static func parse(_ data: Data) throws -> [SpeechSegment] {
        struct Response: Decodable {
            struct Entry: Decodable {
                struct Offsets: Decodable { let from: Double; let to: Double }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Entry]
        }
        return try JSONDecoder().decode(Response.self, from: data).transcription.compactMap { entry in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard entry.offsets.from.isFinite, entry.offsets.to.isFinite,
                  entry.offsets.from >= 0, entry.offsets.to >= entry.offsets.from else {
                throw AnalysisFailure(L10n.string("review.error.timestamp"))
            }
            guard !text.isEmpty, !["[BLANK_AUDIO]", "[MUSIC]", "(Music)", "[Silence]"].contains(text) else { return nil }
            return .init(start: entry.offsets.from / 1000, end: entry.offsets.to / 1000, text: text)
        }
    }
}

struct LlamaSummaryProvider: SummarizationProvider {
    let executable: URL
    let model: URL

    func summarize(text: String, language: String, combiningNotes: Bool, workDirectory: URL) async throws -> String {
        let prompt = workDirectory.appendingPathComponent(UUID().uuidString + ".prompt.txt")
        defer { try? FileManager.default.removeItem(at: prompt) }
        try AnalysisFiles.write(Self.prompt(text: text, language: language, combiningNotes: combiningNotes), to: prompt)
        let raw = try await InferenceProcess().run(executable: executable, arguments: [
            "-m", model.path, "-f", prompt.path, "--no-conversation", "--no-display-prompt",
            "--simple-io", "--color", "off", "--no-perf", "-c", "8192", "-n", "1600",
            "--temp", "0.1", "--seed", "42", "-ngl", "99", "-t", "4",
        ], workingDirectory: workDirectory)
        try Task.checkCancellation()
        let answer = Self.clean(raw)
        guard !answer.isEmpty else { throw AnalysisFailure(L10n.string("review.error.emptySummary")) }
        return answer
    }

    static func prompt(text: String, language: String, combiningNotes: Bool) -> String {
        let outputLanguage = AppLanguage.matching(language) ?? .english
        let system = L10n.string("review.prompt.system", language: outputLanguage)
        let task = L10n.string(combiningNotes ? "review.prompt.combine" : "review.prompt.transcript", language: outputLanguage)
        // Explicit non-thinking ChatML works with the pinned Qwen3 model. This
        // template is provider-owned and does not leak into the session format.
        return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(task)\n<evidence>\n\(text)\n</evidence><|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    static func clean(_ raw: String) -> String {
        var text = raw
        if let end = text.range(of: "</think>", options: .backwards) { text = String(text[end.upperBound...]) }
        for marker in ["<|im_end|>", "<|endoftext|>", "[end of text]"] { text = text.replacingOccurrences(of: marker, with: "") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
