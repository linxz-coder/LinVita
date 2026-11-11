import Foundation

/// Owns one stop request for one presented game. Keep the surface on screen
/// until the native facade reports that all teardown has completed.
@MainActor
final class GameExitCoordinator {
    private(set) var started = false
    private var task: Task<Void, Never>?

    func stop(requestStop: () -> Void,
              isStopped: @escaping () -> Bool,
              onSlowStop: @escaping () -> Void,
              onStopped: @escaping () -> Void) {
        guard !started else { return }
        started = true
        // The native function enqueues teardown; it does not join threads.
        // Issue it now so a delayed task cannot stop a subsequent game.
        requestStop()
        task = Task { @MainActor in
            let slowDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            var reportedSlow = false
            while !isStopped() {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                if !reportedSlow && ContinuousClock.now >= slowDeadline {
                    reportedSlow = true
                    onSlowStop()
                }
            }
            onStopped()
            self.task = nil
        }
    }
}
