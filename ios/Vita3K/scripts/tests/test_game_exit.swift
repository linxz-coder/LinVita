import Foundation

@main
enum GameExitTests {
    @MainActor
    static func main() async {
        let coordinator = GameExitCoordinator()
        var stopCalls = 0
        var completions = 0
        var stopped = false
        var stoppedBeforeDismiss = false
        coordinator.stop(requestStop: { stopCalls += 1 },
                         isStopped: { stopped },
                         onSlowStop: { preconditionFailure("unexpected slow stop") },
                         onStopped: { stoppedBeforeDismiss = stopped; completions += 1 })
        // Both the stop and duplicate prevention are synchronous, even if
        // the main actor has not run the waiter yet.
        precondition(stopCalls == 1 && completions == 0)
        coordinator.stop(requestStop: { stopCalls += 1 },
                         isStopped: { true },
                         onSlowStop: {},
                         onStopped: { completions += 10 })
        try? await Task.sleep(for: .milliseconds(150))
        precondition(stopCalls == 1 && completions == 0)
        stopped = true
        try? await Task.sleep(for: .milliseconds(150))
        precondition(stoppedBeforeDismiss && completions == 1)
        // viewDidDisappear must not send another stop once the next game
        // can be launched. Completion also happens only once.
        coordinator.stop(requestStop: { stopCalls += 1 },
                         isStopped: { true }, onSlowStop: {},
                         onStopped: { completions += 10 })
        await Task.yield()
        precondition(stopCalls == 1 && completions == 1)
        let idle = GameExitCoordinator()
        idle.stop(requestStop: { stopCalls += 1 }, isStopped: { true },
                  onSlowStop: {}, onStopped: { completions += 1 })
        try? await Task.sleep(for: .milliseconds(20))
        precondition(stopCalls == 2 && completions == 2)
        print("PASS: exit waits for teardown, duplicate exits cannot stop a new game, idle exit completes")
    }
}
