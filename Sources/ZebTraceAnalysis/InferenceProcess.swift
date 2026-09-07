import Foundation
import ZebTraceCore

/// A private, one-shot child process. Cancellation waits for process exit before
/// returning, so a replacement job cannot accidentally overlap GPU allocations.
final class InferenceProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var cancelled = false

    func run(executable: URL, arguments: [String], workingDirectory: URL) async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                launch(executable: executable, arguments: arguments,
                       workingDirectory: workingDirectory, continuation: continuation)
            }
        } onCancel: { self.cancel() }
    }

    private func launch(executable: URL, arguments: [String], workingDirectory: URL,
                        continuation: CheckedContinuation<String, Error>) {
        let output = workingDirectory.appendingPathComponent(UUID().uuidString + ".stdout")
        let errors = workingDirectory.appendingPathComponent(UUID().uuidString + ".stderr")
        do {
            try AnalysisFiles.regularFile(executable)
            try AnalysisFiles.write(Data(), to: output)
            try AnalysisFiles.write(Data(), to: errors)
            let outHandle = try FileHandle(forWritingTo: output)
            let errHandle = try FileHandle(forWritingTo: errors)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outHandle
            process.standardError = errHandle
            // Engines only receive explicit local model/audio files. No ambient
            // credentials, model-download configuration or shell is inherited.
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
                                   "TMPDIR": NSTemporaryDirectory(), "LC_ALL": "en_US.UTF-8"]
            process.terminationHandler = { [self] completed in
                try? outHandle.close()
                try? errHandle.close()
                lock.lock()
                let wasCancelled = cancelled
                child = nil
                lock.unlock()
                defer {
                    try? FileManager.default.removeItem(at: output)
                    try? FileManager.default.removeItem(at: errors)
                }
                if wasCancelled { continuation.resume(throwing: CancellationError()); return }
                do {
                    if completed.terminationStatus != 0 {
                        let message = try Self.readTail(errors, limit: 4096)
                        throw AnalysisFailure(L10n.string("review.error.process", executable.lastPathComponent, completed.terminationStatus, message))
                    }
                    let response = try Self.readTail(output, limit: 2 * 1024 * 1024)
                    continuation.resume(returning: response)
                } catch { continuation.resume(throwing: error) }
            }
            lock.lock()
            if cancelled {
                lock.unlock()
                try? outHandle.close(); try? errHandle.close()
                try? FileManager.default.removeItem(at: output)
                try? FileManager.default.removeItem(at: errors)
                continuation.resume(throwing: CancellationError())
                return
            }
            do {
                try process.run()
                child = process
                lock.unlock()
            } catch {
                lock.unlock()
                try? outHandle.close(); try? errHandle.close()
                try? FileManager.default.removeItem(at: output)
                try? FileManager.default.removeItem(at: errors)
                continuation.resume(throwing: error)
            }
        } catch { continuation.resume(throwing: error) }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let process = child
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
        guard let process else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if child === process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private static func readTail(_ url: URL, limit: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: length > UInt64(limit) ? length - UInt64(limit) : 0)
        return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    }
}
