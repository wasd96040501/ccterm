import Foundation
import Observation

/// Per-session input-bar draft store. File-backed so we can comfortably
/// host the occasional very large body (a 10MB paste serializes to one
/// JSON blob; atomic write hops to a background queue).
///
/// Public surface is `load` / `save` / `clear`. `save` coalesces rapid
/// edits behind a debounce window; the trailing write lands off-main.
@MainActor
@Observable
final class InputDraftStore {
    /// Stable key for the New Session compose tab, which has no real
    /// `sessionId` until the first message promotes the draft. Using a
    /// fixed slug means the unsent compose draft survives app restarts.
    static let newSessionKey = "__new_session__"

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let debounceInterval: TimeInterval
    @ObservationIgnored private let ioQueue =
        DispatchQueue(label: "ccterm.input-draft.io", qos: .utility)
    @ObservationIgnored private var pendingSaves: [String: DispatchWorkItem] = [:]

    init(directory: URL? = nil, debounceInterval: TimeInterval = 0.4) {
        self.directory = directory ?? Self.defaultDirectory()
        self.debounceInterval = debounceInterval

        let dir = self.directory
        ioQueue.async {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
    }

    /// Off-main read + decode. Returns nil on miss, decode failure, or
    /// when the on-disk draft is empty (which the bar treats as "no
    /// restore needed").
    func load(sessionId: String) async -> InputDraft? {
        let url = fileURL(for: sessionId)
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<InputDraft?, Never>) in
            ioQueue.async {
                guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let draft = try? JSONDecoder().decode(InputDraft.self, from: data)
                if let draft, !draft.isEmpty {
                    continuation.resume(returning: draft)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Schedule a save `debounceInterval` from now. Replaces any pending
    /// save for the same sessionId. An empty draft short-circuits to
    /// `clear` — we never leave an empty file on disk.
    func save(_ draft: InputDraft, for sessionId: String) {
        guard !draft.isEmpty else {
            clear(sessionId)
            return
        }
        pendingSaves[sessionId]?.cancel()
        let url = fileURL(for: sessionId)
        let queue = ioQueue
        let work = DispatchWorkItem {
            queue.async {
                guard let data = try? JSONEncoder().encode(draft) else { return }
                try? data.write(to: url, options: .atomic)
            }
        }
        pendingSaves[sessionId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Cancel any pending save and delete the on-disk file. Idempotent;
    /// missing files are silently OK.
    func clear(_ sessionId: String) {
        pendingSaves.removeValue(forKey: sessionId)?.cancel()
        let url = fileURL(for: sessionId)
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private

    private func fileURL(for sessionId: String) -> URL {
        directory.appendingPathComponent("\(sanitize(sessionId)).json")
    }

    /// sessionIds are UUID slugs and `newSessionKey` is ASCII-safe, but
    /// strip path separators defensively so a malformed id can't escape
    /// the drafts directory.
    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }

    private static func defaultDirectory() -> URL {
        let base =
            FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("CCTerm/Drafts", isDirectory: true)
    }
}
