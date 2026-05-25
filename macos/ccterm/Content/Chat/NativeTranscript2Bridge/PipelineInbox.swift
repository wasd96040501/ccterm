import Foundation

/// Thread-safe hand-off buffer between the off-main backfill **producer** and
/// the main-actor **drain**. Replaces the old per-page
/// `await MainActor.run { deposit }`: the producer no longer hops to (or blocks
/// on) the main actor for every page — it builds at full speed, `push`es under
/// a lock, and the pipeline posts one coalesced, fire-and-forget drain signal.
/// Throughput is then bounded by `max(build rate, apply rate)` instead of being
/// serialized through a main-actor round-trip per page.
///
/// **Backpressure is async, not blocking.** When the buffer reaches `capacity`
/// the producer `await`s `waitForCapacity()` — it suspends the producer *task*
/// (off-main, no thread blocked, no `DispatchSemaphore` deinit trap) until the
/// drain pops a page and resumes it. So at most `capacity` pre-built pages
/// (blocks + typeset layouts) are ever resident, capping the memory the
/// decoupling could otherwise let the producer run away with.
///
/// Single producer + single (serial, main) consumer; `@unchecked Sendable`
/// documents that all shared state is guarded by `lock`.
final class PipelineInbox: @unchecked Sendable {

    private let lock = NSLock()
    private var pages: [TranscriptBackfillPipeline.PendingPage] = []
    private var finished = false
    /// Coalescing flag: true while a drain is posted-but-not-yet-started.
    private var drainScheduled = false
    /// Row width future pages typeset at (read off-main per page, written on
    /// main at live-resize end). Guarded so the cross-thread read is safe.
    private var typesetWidth: CGFloat
    private let capacity: Int
    /// The single parked producer, if it's waiting on a full buffer. Resumed by
    /// the drain (or `cancelWaiter` on teardown). Exactly one producer exists.
    private var producerWaiter: CheckedContinuation<Void, Never>?

    init(width: CGFloat, capacity: Int) {
        precondition(capacity >= 1, "capacity must allow at least one in-flight page")
        typesetWidth = width
        self.capacity = capacity
    }

    // MARK: Typeset width

    var width: CGFloat {
        lock.lock()
        defer { lock.unlock() }
        return typesetWidth
    }

    func setWidth(_ w: CGFloat) {
        lock.lock()
        typesetWidth = w
        lock.unlock()
    }

    // MARK: Producer side

    /// Append a built page. The producer should follow with `waitForCapacity()`
    /// so it parks rather than racing ahead once `capacity` pages are resident.
    func push(_ page: TranscriptBackfillPipeline.PendingPage) {
        lock.lock()
        pages.append(page)
        lock.unlock()
    }

    /// Cheap pre-check so the producer only allocates a continuation when the
    /// buffer is actually full. `waitForCapacity` re-checks under the lock, so
    /// this racing stale is harmless.
    var isAtCapacity: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pages.count >= capacity
    }

    /// Suspend the producer until the buffer drops below `capacity`. Returns
    /// immediately if there's already room. The drain resumes the parked
    /// producer when it pops a page below the cap.
    func waitForCapacity() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if pages.count < capacity {
                lock.unlock()
                cont.resume()
                return
            }
            producerWaiter = cont
            lock.unlock()
        }
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    // MARK: Consumer (drain) side

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pages.isEmpty
    }

    /// The front page's typeset width without removing it — lets the drain run
    /// its width-gated budget check before deciding to pop.
    func peekFirstWidth() -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return pages.first?.width
    }

    /// Remove and return the front page; if that drops the buffer below
    /// `capacity`, resume a parked producer. Returns `nil` when empty.
    func popFirst() -> TranscriptBackfillPipeline.PendingPage? {
        lock.lock()
        guard !pages.isEmpty else {
            lock.unlock()
            return nil
        }
        let page = pages.removeFirst()
        var waiter: CheckedContinuation<Void, Never>?
        if pages.count < capacity {
            waiter = producerWaiter
            producerWaiter = nil
        }
        lock.unlock()
        waiter?.resume()
        return page
    }

    /// Returns `true` iff this call flipped `drainScheduled` false→true, meaning
    /// the caller should post the drain. Coalesces concurrent signals so only
    /// one drain is ever outstanding.
    func acquireDrainSlot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if drainScheduled { return false }
        drainScheduled = true
        return true
    }

    func releaseDrainSlot() {
        lock.lock()
        drainScheduled = false
        lock.unlock()
    }

    // MARK: Teardown

    /// Resume a parked producer so a torn-down pipeline doesn't strand it on a
    /// never-resumed continuation. Used by `cancel()`.
    func cancelWaiter() {
        lock.lock()
        let waiter = producerWaiter
        producerWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}
