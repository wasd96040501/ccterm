import Foundation

/// Yields the main actor until `condition` holds or `attempts` run out, so
/// main-actor work the code under test enqueued — event delivery from a
/// `FakeCLIClient`, fire-and-forget CLI calls — gets to run. Callers assert
/// on the condition afterwards.
@MainActor
func yieldUntil(attempts: Int = 100, _ condition: () -> Bool) async {
    for _ in 0..<attempts where !condition() {
        await Task.yield()
    }
}
