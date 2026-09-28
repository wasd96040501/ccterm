import XCTest

/// A branch stream followed on the main actor: what it has yielded, whether it
/// has ended, and a wait for the value it yields next.
@MainActor
final class BranchRecorder {
    private(set) var values: [String?] = []
    private(set) var hasFinished = false
    private var task: Task<Void, Never>?
    private var awaited: (branch: String?, expectation: XCTestExpectation)?
    private var ended: XCTestExpectation?

    init(_ stream: AsyncStream<String?>) {
        task = Task { [weak self] in
            for await branch in stream { self?.receive(branch) }
            self?.finish()
        }
    }

    func stop() { task?.cancel() }

    private func receive(_ branch: String?) {
        values.append(branch)
        if let awaited, awaited.branch == branch { awaited.expectation.fulfill() }
    }

    private func finish() {
        hasFinished = true
        ended?.fulfill()
    }

    /// Returns once the latest value is `branch`.
    func wait(for branch: String?, timeout: TimeInterval = 5) async {
        guard values.last != .some(branch) else { return }
        let expectation = XCTestExpectation(description: "branch becomes \(branch ?? "nil"); saw \(values)")
        awaited = (branch, expectation)
        defer { awaited = nil }
        let result = await XCTWaiter().fulfillment(of: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "never became \(branch ?? "nil"); saw \(values)")
    }

    /// Returns once the stream has ended.
    func waitForEnd(timeout: TimeInterval = 5) async {
        guard !hasFinished else { return }
        let expectation = XCTestExpectation(description: "stream ends; saw \(values)")
        ended = expectation
        defer { ended = nil }
        let result = await XCTWaiter().fulfillment(of: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "never ended; saw \(values)")
    }
}
