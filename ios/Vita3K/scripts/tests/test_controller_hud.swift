import Foundation

@main
enum HUDTests {
    static func main() {
        var state = ControllerHUDState()
        state.configure(active: true, controllerConnected: false, keepVisible: false, now: 0)
        precondition(state.isVisible(at: 1_000))
        precondition(state.timeUntilHide(at: 1_000) == nil)
        state.configure(active: true, controllerConnected: true, keepVisible: false, now: 1_000)
        precondition(state.isVisible(at: 1_009.99))
        precondition(!state.isVisible(at: 1_010))
        // Periodic polling and controller input do not reset the deadline.
        state.configure(active: true, controllerConnected: true, keepVisible: false, now: 1_010)
        precondition(!state.isVisible(at: 1_010))
        state.screenActivity(touching: true, now: 1_011)
        precondition(state.isVisible(at: 1_100))
        precondition(state.timeUntilHide(at: 1_100) == nil)
        state.screenActivity(touching: false, now: 1_100)
        precondition(state.timeUntilHide(at: 1_100) == 10)
        precondition(!state.isVisible(at: 1_110))
        state.screenActivity(touching: false, now: 1_111)
        precondition(state.isVisible(at: 1_120))
        precondition(!state.isVisible(at: 1_121))
        // Home/IME menus stay usable, then receive a fresh ten seconds.
        state.configure(active: true, controllerConnected: true, keepVisible: true, now: 1_122)
        precondition(state.isVisible(at: 1_200))
        state.configure(active: true, controllerConnected: true, keepVisible: false, now: 1_200)
        precondition(state.isVisible(at: 1_209))
        precondition(!state.isVisible(at: 1_210))
        state.configure(active: true, controllerConnected: false, keepVisible: false, now: 1_211)
        precondition(state.isVisible(at: 1_300))
        state.configure(active: false, controllerConnected: false, keepVisible: false, now: 1_301)
        precondition(!state.isVisible(at: 1_301))

        state.configure(active: true, controllerConnected: false, keepVisible: false, now: 2_000)
        precondition(state.visibilityToggleIsVisible(vpadAvailable: true, at: 2_000))
        precondition(!state.visibilityToggleIsVisible(vpadAvailable: false, at: 2_000))
        state.toggleControls(now: 2_001)
        precondition(state.controlsHidden && !state.isVisible(at: 2_001))
        // Touching a game element, polling, keyboard/background changes and
        // controller reconnects must not undo the manual choice.
        state.screenActivity(touching: true, now: 2_002)
        state.configure(active: true, controllerConnected: true, keepVisible: true, now: 2_003)
        precondition(!state.isVisible(at: 2_003))
        state.screenActivity(touching: false, now: 2_004)
        state.configure(active: true, controllerConnected: false, keepVisible: false, now: 2_005)
        precondition(!state.isVisible(at: 3_000))
        precondition(state.visibilityToggleIsVisible(vpadAvailable: false, at: 3_000))
        precondition(state.timeUntilHide(at: 3_000) == nil)
        // The explicit restore receives a fresh controller-mode deadline.
        state.configure(active: true, controllerConnected: true, keepVisible: false, now: 3_001)
        state.toggleControls(now: 3_002)
        precondition(!state.controlsHidden && state.isVisible(at: 3_011))
        precondition(!state.isVisible(at: 3_012))
        precondition(!state.visibilityToggleIsVisible(vpadAvailable: true, at: 3_012))
        // New sessions start with normal controls, not an invisible pad.
        state.toggleControls(now: 3_013)
        state.configure(active: false, controllerConnected: false, keepVisible: false, now: 3_014)
        precondition(!state.controlsHidden && !state.visibilityToggleIsVisible(vpadAvailable: true, at: 3_014))
        state.toggleControls(now: 3_015)
        precondition(!state.controlsHidden)
        state.configure(active: true, controllerConnected: false, keepVisible: false, now: 3_016)
        precondition(state.isVisible(at: 3_016))
        print("PASS: controller idle timeout, manual hide/restore, persistent restore button, game touches, polling, keyboard/background, reconnect and new session")
    }
}
