import Foundation

/// Lets exactly one of several racers win.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Checks a condition every `step` seconds until it holds or `seconds` pass.
@MainActor
func waitUntil(_ seconds: Double, step: Double = 0.1, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > end || Task.isCancelled { return condition() }
        try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
    }
    return true
}

/// Runs `op` and reports whether it finished within `seconds`. If not, it is
/// cancelled and abandoned, so a hanging toolkit call can't block the app.
@MainActor
func finishes(within seconds: Double, _ op: @escaping @MainActor () async -> Void) async -> Bool {
    let worker = Task { @MainActor in await op() }
    return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
        let once = Once()
        Task { await worker.value; if once.claim() { done.resume(returning: true) } }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { worker.cancel(); done.resume(returning: false) }
        }
    }
}

/// Waits.
func rest(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}
