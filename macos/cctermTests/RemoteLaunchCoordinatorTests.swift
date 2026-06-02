import AgentSDK
import XCTest

@testable import ccterm

/// `RemoteLaunchCoordinator` end-to-end through the real app code path, minus
/// real ssh: a `.useRemote(path:)` host with an explicit proxy does **no**
/// network (no provisioning, no credential, no probe), so the coordinator
/// deterministically turns a `remoteHostId` into the ssh `LaunchPlan`. The
/// `managed` path's real-ssh behavior is covered by `RemoteSmoke` on a live box.
@MainActor
final class RemoteLaunchCoordinatorTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let suite = "RemoteLaunchCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func coordinator(with host: RemoteHost) -> RemoteLaunchCoordinator {
        let store = RemoteHostStore(defaults: defaults)
        store.upsert(host)
        return RemoteLaunchCoordinator(hosts: store)
    }

    func testUnknownHostFails() async {
        let coord = RemoteLaunchCoordinator(hosts: RemoteHostStore(defaults: defaults))
        let outcome = await coord.resolveLaunch(hostId: "nope", sessionId: "s", claudeArguments: [])
        guard case .failed(let reason) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("not configured"))
    }

    func testUseRemoteProducesSSHLaunchPlanWithEgressAndNoCredential() async {
        let host = RemoteHost(
            alias: "dev", host: "devbox", remoteWorkdir: "/srv/app",
            claudePolicy: .useRemote(path: "/usr/bin/claude"),
            proxy: .useExisting(hostPort: "127.0.0.1:1081"))
        let outcome = await coordinator(with: host).resolveLaunch(
            hostId: host.id, sessionId: "sid-1", claudeArguments: ["--output-format", "stream-json"])

        guard case .resolved(let resolved) = outcome else { return XCTFail("expected resolved, got \(outcome)") }
        guard case .wrapped(let exe, let argv) = resolved.launchPlan else { return XCTFail("expected wrapped plan") }
        XCTAssertEqual(exe, "/usr/bin/ssh")
        XCTAssertEqual(argv[argv.count - 2], "devbox", "host token precedes the remote command")

        let remoteCommand = try! XCTUnwrap(argv.last)
        XCTAssertTrue(remoteCommand.contains("cd '/srv/app'"), "uses the host's remote workdir")
        XCTAssertTrue(remoteCommand.contains("'/usr/bin/claude'"), "uses the pinned remote claude path")
        XCTAssertTrue(remoteCommand.contains("'--output-format' 'stream-json'"), "embeds the claude argv")
        // useRemote forwards NO credential.
        XCTAssertFalse(remoteCommand.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        XCTAssertFalse(remoteCommand.contains("ANTHROPIC_API_KEY"))

        // Egress: a per-session -R → the explicit Mac proxy, HTTPS_PROXY forces it.
        guard let rIdx = argv.firstIndex(of: "-R") else { return XCTFail("missing -R egress") }
        let port = RemoteLaunchCoordinator.forwardPort(for: "sid-1")
        XCTAssertEqual(argv[rIdx + 1], "127.0.0.1:\(port):127.0.0.1:1081")
        XCTAssertTrue(remoteCommand.contains("HTTPS_PROXY='http://127.0.0.1:\(port)'"))
    }

    func testCCTermRunProxyModeIsNotWiredYet() async {
        let host = RemoteHost(
            alias: "dev", host: "devbox", claudePolicy: .useRemote(path: "/c"), proxy: .ccTermRunsOne)
        let outcome = await coordinator(with: host).resolveLaunch(hostId: host.id, sessionId: "s", claudeArguments: [])
        guard case .failed(let reason) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("existing local proxy"), "guides the user to the supported mode")
    }

    func testForwardPortStableAndInRange() {
        let p1 = RemoteLaunchCoordinator.forwardPort(for: "session-abc")
        let p2 = RemoteLaunchCoordinator.forwardPort(for: "session-abc")
        XCTAssertEqual(p1, p2, "deterministic per session id")
        XCTAssertTrue((18000..<19000).contains(p1))
    }
}
