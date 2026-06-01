import XCTest

@testable import ccterm

/// `RemoteHostStore` persistence + `RemoteHost`/`SessionConfig` codable round-trip
/// (design `remote-execution.md` §3b/§3c). Each test injects a private
/// `UserDefaults` suite so nothing touches `.standard` (parallel-safety rule).
@MainActor
final class RemoteHostStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        suiteName = "RemoteHostStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        addTeardownBlock { [suiteName] in
            UserDefaults.standard.removePersistentDomain(forName: suiteName!)
        }
    }

    func testUpsertAppendsThenReplacesInPlace() {
        let store = RemoteHostStore(defaults: defaults)
        let a = RemoteHost(alias: "A", host: "a.example")
        let b = RemoteHost(alias: "B", host: "b.example")
        store.upsert(a)
        store.upsert(b)
        XCTAssertEqual(store.hosts.map(\.id), [a.id, b.id], "insertion order preserved")

        var aRenamed = a
        aRenamed.alias = "A-prime"
        store.upsert(aRenamed)
        XCTAssertEqual(store.hosts.map(\.id), [a.id, b.id], "same id replaces in place, no reorder")
        XCTAssertEqual(store.host(id: a.id)?.alias, "A-prime")
    }

    func testRemoveAndLookup() {
        let store = RemoteHostStore(defaults: defaults)
        let h = RemoteHost(alias: "dev", host: "devbox")
        store.upsert(h)
        XCTAssertNotNil(store.host(id: h.id))
        store.remove(id: h.id)
        XCTAssertNil(store.host(id: h.id))
        XCTAssertTrue(store.hosts.isEmpty)
    }

    func testPersistsAcrossStoreInstances() {
        let h = RemoteHost(
            alias: "dev", host: "devbox", user: "u", port: 2222, identityFile: "/k/id",
            remoteWorkdir: "/srv", claudePolicy: .useRemote(path: "/usr/bin/claude"),
            proxy: .useExisting(hostPort: "127.0.0.1:1081"))
        RemoteHostStore(defaults: defaults).upsert(h)

        // A fresh store sharing the same defaults must decode the same host
        // (full Codable round-trip incl. the enum associated values).
        let reloaded = RemoteHostStore(defaults: defaults).host(id: h.id)
        XCTAssertEqual(reloaded, h)
    }

    func testRemoteClaudePolicyCodableVariants() throws {
        for policy in [RemoteClaudePolicy.managed, .useRemote(path: nil), .useRemote(path: "/x")] {
            let data = try JSONEncoder().encode(policy)
            XCTAssertEqual(try JSONDecoder().decode(RemoteClaudePolicy.self, from: data), policy)
        }
    }

    func testSessionConfigRoundTripsRemoteHostIdThroughRecord() {
        var config = SessionConfig(cwd: "/tmp", remoteHostId: "host-123")
        let record = config.toSessionRecord(sessionId: "sid", title: "t")
        XCTAssertEqual(record.extra.remoteHostId, "host-123", "remoteHostId persisted into the extra blob")

        let hydrated = SessionConfig(from: record)
        XCTAssertEqual(hydrated.remoteHostId, "host-123", "and restored on resume")

        // Default is nil (local) and a record without it hydrates to nil.
        config = SessionConfig(cwd: "/tmp")
        XCTAssertNil(SessionConfig(from: config.toSessionRecord(sessionId: "s2", title: "t")).remoteHostId)
    }
}
