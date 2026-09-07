import Darwin
import Foundation
import XCTest
@testable import ZebTraceAnalysis

final class InferenceProcessTests: XCTestCase {
    func testCancellationReturnsOnlyAfterTheStartedChildHasExited() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTraceProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("sleep-fixture")
        let pidFile = root.appendingPathComponent("child.pid")
        // exec preserves the shell PID and leaves no grandchild to outlive the test.
        let contents = "#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$1\"\nexec /bin/sleep 20\n"
        try contents.write(to: script, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let task = Task {
            try await InferenceProcess().run(executable: script, arguments: [pidFile.path], workingDirectory: root)
        }
        defer { task.cancel() }
        let pid = try await waitForPID(at: pidFile)
        XCTAssertEqual(kill(pid, 0), 0, "The process must have actually started before cancellation")

        let cancelledAt = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected CancellationError") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 5)
        let result = kill(pid, 0)
        let code = errno
        XCTAssertEqual(result, -1, "run must not return while its child is still alive")
        XCTAssertEqual(code, ESRCH)
    }

    private func waitForPID(at url: URL) async throws -> Int32 {
        for _ in 0..<250 {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                return pid
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The fixture did not report its PID")
        throw AnalysisFailure("The test child did not start")
    }
}
