import SwiftUI
import GameController
import Vita3KCore

@MainActor
enum PhysicalController {
    static let triggerPreference = "controller.triggerShoulders"
    static let deadzonePreference = "controller.stickDeadzone"
    static let hidePreference = "controller.hideTouchControls"

    static func applyPreferences() {
        let defaults = UserDefaults.standard
        vita3k_ios_input_gamepad_config(
            (defaults.object(forKey: triggerPreference) as? Bool ?? true) ? 1 : 0,
            Float(defaults.object(forKey: deadzonePreference) as? Double ?? 0.12))
    }

    static var hideTouchControls: Bool {
        UserDefaults.standard.object(forKey: hidePreference) as? Bool ?? true
    }

    // Read only: SDL owns GameController's valueChanged handlers. Replacing
    // them here would silently stop input reaching the emulated Vita.
    static func snapshot() -> (name: String, buttons: String, axes: String) {
        guard let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }),
              let pad = controller.extendedGamepad else { return ("", "", "") }
        let buttons: [(String, GCControllerButtonInput?)] = [
            ("×", pad.buttonA), ("○", pad.buttonB), ("□", pad.buttonX), ("△", pad.buttonY),
            ("L1", pad.leftShoulder), ("R1", pad.rightShoulder),
            ("L2", pad.leftTrigger), ("R2", pad.rightTrigger),
            ("Start", pad.buttonMenu), ("Select", pad.buttonOptions),
            ("L3", pad.leftThumbstickButton), ("R3", pad.rightThumbstickButton),
            ("↑", pad.dpad.up), ("↓", pad.dpad.down), ("←", pad.dpad.left), ("→", pad.dpad.right)
        ]
        let held = buttons.filter { $0.1?.isPressed == true }.map(\.0).joined(separator: "  ")
        let axes = String(format: "L  %+.2f  %+.2f\nR  %+.2f  %+.2f\nL2  %.2f    R2  %.2f",
                          pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value,
                          pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value,
                          pad.leftTrigger.value, pad.rightTrigger.value)
        return (controller.vendorName ?? controller.productCategory, held, axes)
    }
}

struct ControllerSettingsView: View {
    @AppStorage(PhysicalController.triggerPreference) private var triggerShoulders = true
    @AppStorage(PhysicalController.deadzonePreference) private var deadzone = 0.12
    @AppStorage(PhysicalController.hidePreference) private var hideControls = true
    @State private var name = ""
    @State private var buttons = ""
    @State private var axes = ""

    var body: some View {
        Form {
            Section("controller.connection") {
                Label(name.isEmpty ? L10n.text("controller.disconnected") : name,
                      systemImage: name.isEmpty ? "gamecontroller" : "gamecontroller.fill")
                Text("controller.x5s.pairing").font(.footnote).foregroundStyle(.secondary)
                Link("controller.officialGuide", destination: URL(string: "https://doc.xiaoji.com/zh/x5s/detail/1766.html")!)
            }
            Section("controller.mapping") {
                Text("controller.x5s.mapping")
                Toggle("controller.triggerShoulders", isOn: $triggerShoulders)
                Text("controller.triggerHelp").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Text("controller.deadzone")
                    Spacer()
                    Text(deadzone, format: .percent.precision(.fractionLength(0)))
                }
                Slider(value: $deadzone, in: 0...0.3, step: 0.01)
                    .accessibilityLabel("controller.deadzone")
                Toggle("controller.hideTouchControls", isOn: $hideControls)
                Text("controller.touchHelp").font(.footnote).foregroundStyle(.secondary)
            }
            Section("controller.inputTest") {
                Text(buttons.isEmpty ? L10n.text("controller.pressButtons") : buttons)
                    .font(.headline.monospaced()).frame(minHeight: 28)
                if !axes.isEmpty { Text(axes).font(.body.monospaced()).textSelection(.enabled) }
                Text("controller.inputTestHelp").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("controller.title")
        .onChange(of: triggerShoulders) { _, _ in PhysicalController.applyPreferences() }
        .onChange(of: deadzone) { _, _ in PhysicalController.applyPreferences() }
        .task {
            PhysicalController.applyPreferences()
            while !Task.isCancelled {
                let state = PhysicalController.snapshot()
                name = state.name; buttons = state.buttons; axes = state.axes
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
    }
}
