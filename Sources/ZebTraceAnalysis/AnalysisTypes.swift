import Foundation

public enum AnalysisStage: String, Codable, Sendable {
    case preparing, transcribing, summarizing, saving
}

public struct AnalysisProgress: Sendable {
    public let stage: AnalysisStage
    public let completed: Int
    public let total: Int

    public init(stage: AnalysisStage, completed: Int = 0, total: Int = 1) {
        self.stage = stage
        self.completed = completed
        self.total = total
    }
}

public struct AnalysisConfiguration: Sendable {
    public let runtimeDirectory: URL
    public let asrModelURL: URL
    public let summaryModelURL: URL
    /// Output language only. Speech recognition always detects the spoken language.
    public let language: String

    public init(runtimeDirectory: URL, asrModelURL: URL, summaryModelURL: URL, language: String) {
        self.runtimeDirectory = runtimeDirectory
        self.asrModelURL = asrModelURL
        self.summaryModelURL = summaryModelURL
        self.language = language
    }
}

public struct AnalysisResult: Sendable {
    public let directory: URL
    public var transcriptURL: URL { directory.appendingPathComponent("transcript.md") }
    public var summaryURL: URL { directory.appendingPathComponent("summary.md") }

    public init(directory: URL) { self.directory = directory }
}

public struct ModelDownloadProgress: Sendable {
    public let modelName: String
    public let downloadedBytes: Int64
    public let totalBytes: Int64
    public init(modelName: String, downloadedBytes: Int64, totalBytes: Int64) {
        self.modelName = modelName
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }
}

public struct LocalModelFiles: Sendable {
    public let asr: URL
    public let summary: URL
    public init(asr: URL, summary: URL) { self.asr = asr; self.summary = summary }
}

public struct AnalysisFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
