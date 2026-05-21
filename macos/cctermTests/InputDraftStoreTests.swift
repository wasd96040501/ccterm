import XCTest

@testable import ccterm

@MainActor
final class InputDraftStoreTests: XCTestCase {

    private var directory: URL!
    private var store: InputDraftStore!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-draft-tests-\(UUID().uuidString)", isDirectory: true)
        directory = base
        store = InputDraftStore(directory: base, debounceInterval: 0.05)
        addTeardownBlock { [base] in
            try? FileManager.default.removeItem(at: base)
        }
    }

    func testEmptyDraftReturnsNil() async {
        let draft = await store.load(sessionId: "missing")
        XCTAssertNil(draft)
    }

    func testSaveThenLoadRoundTrip() async {
        let sid = "round-trip"
        let original = InputDraft(
            text: "hello world", filePaths: ["/tmp/a.txt"], updatedAt: Date())
        store.save(original, for: sid)

        try? await waitForFile(at: fileURL(sid), exists: true)

        let loaded = await store.load(sessionId: sid)
        XCTAssertEqual(loaded?.text, original.text)
        XCTAssertEqual(loaded?.filePaths, original.filePaths)
    }

    func testDebounceCoalescesRapidWrites() async {
        let sid = "debounce"
        for i in 0..<5 {
            store.save(
                InputDraft(text: "v\(i)", filePaths: [], updatedAt: Date()),
                for: sid
            )
        }
        try? await waitForFile(at: fileURL(sid), exists: true)

        let loaded = await store.load(sessionId: sid)
        XCTAssertEqual(loaded?.text, "v4", "only the last save in the debounce window should hit disk")
    }

    func testEmptyDraftClearsExistingFile() async {
        let sid = "auto-clear"
        store.save(InputDraft(text: "x", filePaths: [], updatedAt: Date()), for: sid)
        try? await waitForFile(at: fileURL(sid), exists: true)

        store.save(InputDraft.empty, for: sid)
        try? await waitForFile(at: fileURL(sid), exists: false)

        let loaded = await store.load(sessionId: sid)
        XCTAssertNil(loaded)
    }

    func testClearCancelsPendingSave() async {
        let sid = "clear-cancel"
        store.save(InputDraft(text: "pending", filePaths: [], updatedAt: Date()), for: sid)
        // Cancel before debounce window elapses.
        store.clear(sid)

        // Give the (cancelled) work item more than enough time to NOT run.
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !FileManager.default.fileExists(atPath: self.fileURL(sid).path)
            },
            object: nil
        )
        await fulfillment(of: [exp], timeout: 2.0)

        let loaded = await store.load(sessionId: sid)
        XCTAssertNil(loaded)
    }

    func testLargePayloadRoundTrip() async {
        // ~5MB body — well past anything UserDefaults would tolerate.
        let big = String(repeating: "abcdefghij", count: 500_000)
        let sid = "large"
        store.save(InputDraft(text: big, filePaths: [], updatedAt: Date()), for: sid)
        try? await waitForFile(at: fileURL(sid), exists: true)

        let loaded = await store.load(sessionId: sid)
        XCTAssertEqual(loaded?.text.count, big.count)
    }

    // MARK: - Helpers

    private func fileURL(_ sid: String) -> URL {
        directory.appendingPathComponent("\(sid).json")
    }

    private func waitForFile(at url: URL, exists: Bool) async throws {
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: url.path) == exists
            },
            object: nil
        )
        await fulfillment(of: [exp], timeout: 5.0)
    }
}
