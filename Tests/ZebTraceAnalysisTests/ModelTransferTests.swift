import CryptoKit
import Foundation
import XCTest
import ZebTraceCore
@testable import ZebTraceAnalysis

final class ModelTransferTests: XCTestCase {
    func testRangeResponseAppendsAtExistingOffset() async throws {
        let fixture = try TransferFixture(prefix: "ab", response: .init(
            status: 206, headers: ["Content-Range": "bytes 2-5/6"], body: "cdef"))
        defer { fixture.remove() }

        try await fixture.transfer().download { _ in }

        XCTAssertEqual(fixture.response.rangeHeader, "bytes=2-")
        XCTAssertEqual(try Data(contentsOf: fixture.partial), Data("abcdef".utf8))
    }

    func testRangeResponseWithWrongStartingOffsetPreservesPartial() async throws {
        let fixture = try TransferFixture(prefix: "ab", response: .init(
            status: 206, headers: ["Content-Range": "bytes 1-5/6"], body: "bcdef"))
        defer { fixture.remove() }

        do {
            try await fixture.transfer().download { _ in }
            XCTFail("A range starting before the existing file offset must fail.")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.string("modelStore.error.invalidPartial"))
        }

        XCTAssertEqual(fixture.response.rangeHeader, "bytes=2-")
        XCTAssertEqual(try Data(contentsOf: fixture.partial), Data("ab".utf8))
    }

    func testFullResponseToRangeRequestReplacesPartial() async throws {
        let fixture = try TransferFixture(prefix: "xx", response: .init(status: 200, body: "abcdef"))
        defer { fixture.remove() }

        try await fixture.transfer().download { _ in }

        XCTAssertEqual(fixture.response.rangeHeader, "bytes=2-")
        XCTAssertEqual(try Data(contentsOf: fixture.partial), Data("abcdef".utf8))
    }

    func testHTTPFailurePreservesPartial() async throws {
        let fixture = try TransferFixture(prefix: "ab", response: .init(status: 503, body: "unavailable"))
        defer { fixture.remove() }

        do {
            try await fixture.transfer().download { _ in }
            XCTFail("A server failure must not be accepted as model data.")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.string("modelStore.error.http", 503))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.partial), Data("ab".utf8))
    }

    func testOversizedDataIsRejectedBeforeAppending() async throws {
        let fixture = try TransferFixture(prefix: "ab", response: .init(
            status: 206, headers: ["Content-Range": "bytes 2-5/6"], body: "cdefg"))
        defer { fixture.remove() }

        do {
            try await fixture.transfer().download { _ in }
            XCTFail("A response exceeding the descriptor's size must fail.")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.string("modelStore.error.oversized"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.partial), Data("ab".utf8))
    }

    func testCancellationClosesWriterAndRetainsResumableBytesForImmediateRetry() async throws {
        let protocolStopped = expectation(description: "The URL protocol eventually stops loading")
        let fixture = try TransferFixture(prefix: "", response: .init(
            status: 200, body: "abc", finishes: false, onStop: { protocolStopped.fulfill() }))
        defer { fixture.remove() }
        let prefixWritten = expectation(description: "The first body bytes reached the partial file")
        prefixWritten.assertForOverFulfill = false
        let finished = expectation(description: "Cancellation completed")
        let outcome = TransferOutcome()
        let transfer = fixture.transfer()
        let task = Task {
            defer { finished.fulfill() }
            do {
                try await transfer.download { received in
                    if received == 3 { prefixWritten.fulfill() }
                }
                outcome.finish(cancelled: false)
            } catch {
                outcome.finish(cancelled: error is CancellationError)
            }
        }
        defer { task.cancel() }

        await fulfillment(of: [prefixWritten], timeout: 5)
        task.cancel()
        await fulfillment(of: [finished], timeout: 5)
        let cancelled = try XCTUnwrap(outcome.value)
        XCTAssertTrue(cancelled, "The caller must receive CancellationError.")
        XCTAssertEqual(try Data(contentsOf: fixture.partial), Data("abc".utf8))

        // URLSession acknowledges cancellation through didCompleteWithError.
        // URLProtocol.stopLoading can be observed later on another queue. Test
        // our actual ownership guarantee instead of imposing callback ordering:
        // even an injected late body callback cannot write through the old handle.
        let callbackSession = URLSession(configuration: .ephemeral)
        let callbackTask = callbackSession.dataTask(with: fixture.model.url)
        defer { callbackSession.invalidateAndCancel() }
        // This task is never resumed; calling the delegate directly uses no network.
        transfer.urlSession(callbackSession, dataTask: callbackTask, didReceive: Data("x".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.partial), Data("abc".utf8))

        // A replacement transfer can immediately take ownership of the same
        // partial file after cancellation has returned.
        let resumed = TransferResponse(status: 206,
            headers: ["Content-Range": "bytes 3-5/6"], body: "def")
        TransferURLProtocol.register(resumed, for: fixture.model.url)
        try await fixture.transfer().download { _ in }
        XCTAssertEqual(resumed.rangeHeader, "bytes=3-")
        transfer.urlSession(callbackSession, dataTask: callbackTask, didReceive: Data("y".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.partial), Data("abcdef".utf8))
        await fulfillment(of: [protocolStopped], timeout: 5)
    }
}

private struct TransferFixture {
    let directory: URL
    let partial: URL
    let model: LocalModelDescriptor
    let response: TransferResponse

    init(prefix: String, response: TransferResponse) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZebTrace-ModelTransferTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        partial = directory.appendingPathComponent("small-model.bin.partial")
        try Data(prefix.utf8).write(to: partial)
        let data = Data("abcdef".utf8)
        model = LocalModelDescriptor(name: "Small test fixture", filename: "small-model.bin",
            url: URL(string: "https://zebtrace-model-transfer-tests.invalid/" + UUID().uuidString)!,
            bytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            license: "MIT")
        self.response = response
        TransferURLProtocol.register(response, for: model.url)
    }

    func transfer() -> ModelTransfer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferURLProtocol.self]
        configuration.urlCache = nil
        return ModelTransfer(model: model, destination: partial, configuration: configuration)
    }

    func remove() {
        TransferURLProtocol.unregister(model.url)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class TransferResponse: @unchecked Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    let finishes: Bool
    private let lock = NSLock()
    private var receivedRange: String?
    private var didStop = false
    private let onStop: @Sendable () -> Void

    init(status: Int, headers: [String: String] = [:], body: String, finishes: Bool = true,
         onStop: @escaping @Sendable () -> Void = {}) {
        self.status = status
        var responseHeaders = headers
        // The cancellation fixture deliberately leaves its tiny body open.
        // Declare binary content so MIME sniffing does not delay those bytes.
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            responseHeaders["Content-Type"] = "application/octet-stream"
        }
        self.headers = responseHeaders
        self.body = Data(body.utf8); self.finishes = finishes
        self.onStop = onStop
    }

    var rangeHeader: String? { lock.lock(); defer { lock.unlock() }; return receivedRange }

    func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        receivedRange = request.value(forHTTPHeaderField: "Range")
    }

    func stop() {
        lock.lock()
        let alreadyStopped = didStop
        didStop = true
        lock.unlock()
        if !alreadyStopped { onStop() }
    }
}

private final class TransferOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: Bool?

    var value: Bool? {
        lock.lock(); defer { lock.unlock() }; return completion
    }

    func finish(cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        completion = cancelled
    }
}

private final class TransferURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var responses: [URL: TransferResponse] = [:]
    private let stateLock = NSLock()
    private var activeResponse: TransferResponse?
    private var didStop = false

    static func register(_ response: TransferResponse, for url: URL) {
        registryLock.lock(); defer { registryLock.unlock() }
        responses[url] = response
    }

    static func unregister(_ url: URL) {
        registryLock.lock(); defer { registryLock.unlock() }
        responses.removeValue(forKey: url)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        // Intercept every URL used by these fixtures even if a registration is
        // missing, so a broken test can never fall through to a real network.
        request.url?.host == "zebtrace-model-transfer-tests.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.registryLock.lock()
        let response = Self.responses[url]
        Self.registryLock.unlock()
        guard let response,
              let http = HTTPURLResponse(url: url, statusCode: response.status,
                                         httpVersion: "HTTP/1.1", headerFields: response.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        stateLock.lock()
        activeResponse = response
        let stopped = didStop
        stateLock.unlock()
        if stopped { response.stop(); return }
        response.record(request)
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty { client?.urlProtocol(self, didLoad: response.body) }
        if response.finishes { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        stateLock.lock()
        didStop = true
        let response = activeResponse
        stateLock.unlock()
        response?.stop()
    }
}
