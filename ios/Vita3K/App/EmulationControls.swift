import Foundation

/// Only screen touches renew the deadline. Gamepad input must not keep the HUD up.
struct ControllerHUDState {
    static let idleInterval: TimeInterval = 10
    private(set) var active = false
    private(set) var controllerConnected = false
    private(set) var keepVisible = false
    private(set) var touching = false
    private(set) var controlsHidden = false
    private var lastActivity: TimeInterval = 0

    mutating func configure(active: Bool, controllerConnected: Bool, keepVisible: Bool, now: TimeInterval) {
        if self.active != active || self.controllerConnected != controllerConnected || self.keepVisible != keepVisible {
            lastActivity = now
        }
        self.active = active
        self.controllerConnected = controllerConnected
        self.keepVisible = keepVisible
        if !active { touching = false; controlsHidden = false }
    }

    mutating func screenActivity(touching: Bool, now: TimeInterval) {
        self.touching = touching
        lastActivity = now
    }

    func isVisible(at now: TimeInterval) -> Bool {
        active && !controlsHidden && (!controllerConnected || keepVisible || touching || now - lastActivity < Self.idleInterval)
    }

    mutating func toggleControls(now: TimeInterval) {
        guard active else { return }
        controlsHidden.toggle()
        lastActivity = now
    }

    func visibilityToggleIsVisible(vpadAvailable: Bool, at now: TimeInterval) -> Bool {
        // Manual hiding must always leave a way back, even after ten seconds
        // or after connecting a controller. Game touches never undo the choice.
        active && (controlsHidden || (vpadAvailable && isVisible(at: now)))
    }

    func timeUntilHide(at now: TimeInterval) -> TimeInterval? {
        guard active, !controlsHidden, controllerConnected, !keepVisible, !touching else { return nil }
        let remaining = Self.idleInterval - (now - lastActivity)
        return remaining > 0 ? remaining : nil
    }
}

#if canImport(UIKit)
import UIKit

/// Observes touches without recognizing a gesture, delaying controls, or stealing
/// the first touch used to reveal the HUD from the game's touch surface.
final class ScreenActivityRecognizer: UIGestureRecognizer {
    var onActivity: ((Bool) -> Void)?
    private var fingers: Set<ObjectIdentifier> = []

    init(onActivity: @escaping (Bool) -> Void) {
        self.onActivity = onActivity
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        fingers.formUnion(touches.map(ObjectIdentifier.init))
        onActivity?(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        onActivity?(!fingers.isEmpty)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        fingers.subtract(touches.map(ObjectIdentifier.init))
        onActivity?(!fingers.isEmpty)
        if fingers.isEmpty { state = .failed }
    }

    override func reset() {
        super.reset()
        if !fingers.isEmpty { fingers.removeAll(); onActivity?(false) }
    }
}

/// Animate the artwork, leaving the button's frame and multitouch hit area fixed.
final class InputFeedbackButton: UIButton {
    private let plate = UIView()
    private(set) var inputPressed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        plate.isUserInteractionEnabled = false
        insertSubview(plate, at: 0)
        backgroundColor = .clear
        setInputPressed(false, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        plate.bounds = bounds
        plate.center = CGPoint(x: bounds.midX, y: bounds.midY)
        plate.layer.cornerRadius = min(bounds.width, bounds.height) / 2
        sendSubviewToBack(plate)
    }

    func setInputPressed(_ pressed: Bool, animated: Bool = true) {
        inputPressed = pressed
        let changes = {
            self.plate.backgroundColor = .white.withAlphaComponent(pressed ? 0.52 : 0.18)
            self.plate.layer.borderColor = UIColor.white.withAlphaComponent(pressed ? 0.95 : 0.22).cgColor
            self.plate.layer.borderWidth = pressed ? 2 : 1
            let scale = pressed ? 0.90 : 1.0
            self.plate.transform = CGAffineTransform(scaleX: scale, y: scale)
            self.titleLabel?.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: pressed ? 0.07 : 0.14, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            plate.layer.removeAllAnimations()
            titleLabel?.layer.removeAllAnimations()
            changes()
        }
        accessibilityValue = pressed ? "1" : "0"
    }
}

/// A 30-point translucent face inside a 44-point tap target.
final class CompactOverlayButton: UIButton {
    private let plate = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        plate.isUserInteractionEnabled = false
        plate.backgroundColor = .black.withAlphaComponent(0.4)
        plate.layer.cornerRadius = 15
        insertSubview(plate, at: 0)
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        config.titleLineBreakMode = .byClipping
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming
            result.font = .systemFont(ofSize: 12, weight: .medium)
            return result
        }
        configuration = config
        titleLabel?.numberOfLines = 1
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        plate.frame = bounds.insetBy(dx: 7, dy: max(0, (bounds.height - 30) / 2))
        sendSubviewToBack(plate)
    }
}
#endif
