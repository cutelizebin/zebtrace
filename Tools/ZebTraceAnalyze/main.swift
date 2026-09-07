import Foundation
import ZebTraceAnalysis

/// Developer smoke harness. The installed app invokes the same service directly.
@main
struct ZebTraceAnalyze {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard (4...5).contains(arguments.count) else {
            FileHandle.standardError.write(Data("Usage: ZebTraceAnalyze SESSION_DIRECTORY RUNTIME_DIRECTORY MODEL_DIRECTORY zh|en [ASR_FILENAME]\n".utf8))
            exit(2)
        }
        do {
            let began = Date()
            let models = LocalModelStore(directory: URL(fileURLWithPath: arguments[2], isDirectory: true))
            let files = try await models.prepare(asrFilename: arguments.count == 5 ? arguments[4] : nil) { update in
                print("Model: \(update.modelName) \(update.downloadedBytes)/\(update.totalBytes)")
            }
            let configuration = AnalysisConfiguration(runtimeDirectory: URL(fileURLWithPath: arguments[1]),
                asrModelURL: files.asr, summaryModelURL: files.summary, language: arguments[3])
            let result = try await SessionAnalysisService().analyze(sessionDirectory: URL(fileURLWithPath: arguments[0]),
                configuration: configuration) { update in
                print("\(update.stage.rawValue): \(update.completed)/\(update.total)")
            }
            print("Saved review: \(result.summaryURL.path)")
            print(String(format: "Elapsed: %.2f seconds", Date().timeIntervalSince(began)))
        } catch {
            FileHandle.standardError.write(Data("Analysis failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
