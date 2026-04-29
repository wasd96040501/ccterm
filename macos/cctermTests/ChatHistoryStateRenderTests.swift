import XCTest
@testable import ccterm

/// `ChatHistoryRenderCase.classify` 纯函数测试：确保 5 个 HistoryLoadState 都
/// 映射到正确分支。两段式的 4 个非失败状态必须一律进 `.transcript` 分支——
/// 不允许任何一个走 spinner / error。
final class ChatHistoryStateRenderTests: XCTestCase {

    func testNotLoadedMapsToTranscript() {
        XCTAssertEqual(
            ChatHistoryRenderCase.classify(.notLoaded),
            .transcript)
    }

    func testLoadingTailMapsToTranscript() {
        XCTAssertEqual(
            ChatHistoryRenderCase.classify(.loadingTail),
            .transcript)
    }

    func testTailLoadedMapsToTranscript() {
        XCTAssertEqual(
            ChatHistoryRenderCase.classify(.tailLoaded(count: 42)),
            .transcript)
    }

    func testLoadedMapsToTranscript() {
        XCTAssertEqual(
            ChatHistoryRenderCase.classify(.loaded),
            .transcript)
    }

    func testFailedMapsToError() {
        XCTAssertEqual(
            ChatHistoryRenderCase.classify(.failed("I/O error")),
            .error("I/O error"))
    }

    /// 不同 reason 也进同一 case，reason 透传。
    func testFailedReasonPropagates() {
        let cases = [
            "network unreachable",
            "corrupt JSONL",
            "",
        ]
        for reason in cases {
            XCTAssertEqual(
                ChatHistoryRenderCase.classify(.failed(reason)),
                .error(reason))
        }
    }
}
