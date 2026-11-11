import UIKit

// Step 9: SCE_CTRL button bits for the on-screen gamepad (mirrors
// vita3k/ctrl/include/ctrl/ctrl.h). The non-extended set aliases L==L2 and
// R==R2, matching the real Vita's SceCtrlData.buttons layout.
enum SceCtrl {
    static let select: UInt32 = 0x00000001
    static let start: UInt32 = 0x00000008
    static let up: UInt32 = 0x00000010
    static let right: UInt32 = 0x00000020
    static let down: UInt32 = 0x00000040
    static let left: UInt32 = 0x00000080
    static let l: UInt32 = 0x00000100   // non-ext: L2 == L
    static let r: UInt32 = 0x00000200   // non-ext: R2 == R
    static let triangle: UInt32 = 0x00001000
    static let circle: UInt32 = 0x00002000
    static let cross: UInt32 = 0x00004000
    static let square: UInt32 = 0x00008000

    // Extended (SceCtrlDataExt) bits.
    static let extL1: UInt32 = 0x00000400
    static let extR1: UInt32 = 0x00000800
    static let extL2: UInt32 = 0x00000100
    static let extR2: UInt32 = 0x00000200
    static let extL3: UInt32 = 0x00000002
    static let extR3: UInt32 = 0x00000004
}

/// A draggable analog stick. Reports normalized (-1..1) offsets through
/// `onChange` (x right+, y down+ in screen space, which is LX/LY, RX/RY).
/// The knob springs back to center when released.
final class VirtualStickView: UIView {
    var onChange: ((_ x: Float, _ y: Float) -> Void)?

    private let knob = UIView()
    private var travel: CGFloat { max(1, (bounds.width - knob.bounds.width) / 2) }
    private var tracking = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = UIColor.white.withAlphaComponent(0.10)
        layer.cornerRadius = bounds.width / 2
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        knob.layer.cornerRadius = knob.bounds.width / 2
        knob.isUserInteractionEnabled = false
        addSubview(knob)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        let s = knob.bounds.width
        knob.frame = CGRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracking = true
        handle(touches.first)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracking else { return }
        handle(touches.first)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracking = false
        center()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracking = false
        center()
    }

    private func handle(_ touch: UITouch?) {
        guard let touch else { return }
        let p = touch.location(in: self)
        let cx = bounds.width / 2
        let cy = bounds.height / 2
        var dx = p.x - cx
        var dy = p.y - cy
        let dist = max(abs(dx), abs(dy))
        if dist > travel {
            dx *= travel / dist
            dy *= travel / dist
        }
        knob.frame = CGRect(x: (bounds.width - knob.bounds.width) / 2 + dx,
                            y: (bounds.height - knob.bounds.height) / 2 + dy,
                            width: knob.bounds.width, height: knob.bounds.height)
        onChange?(Float(dx / travel), Float(dy / travel))
    }

    func center() {
        tracking = false
        layoutIfNeeded()
        let s = knob.bounds.width
        knob.frame = CGRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
        onChange?(0, 0)
    }
}

/// On-screen gamepad: D-pad, ABXY, two sticks, shoulders, Select/Start.
/// Writes the full SCE_CTRL button mask (and stick axes) into the core on
/// every touch; all buttons clear when the view is deactivated.
final class VirtualGamepadView: UIView {
    private var pressed: Set<UInt32> = []       // non-extended bits held
    private var pressedExt: Set<UInt32> = []    // extended bits held
    private var leftStick: (Float, Float) = (0, 0)
    private var rightStick: (Float, Float) = (0, 0)

    private let leftStickView = VirtualStickView()
    private let rightStickView = VirtualStickView()

    /// 0 = off, 1 = on (drives the core's virtual_pad.active)
    var isActive = false {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isUserInteractionEnabled = true
        addSubview(leftStickView)
        addSubview(rightStickView)

        leftStickView.onChange = { [weak self] x, y in
            guard let self else { return }
            self.leftStick = (x, y)
            self.pushAxes()
        }
        rightStickView.onChange = { [weak self] x, y in
            guard let self else { return }
            self.rightStick = (x, y)
            self.pushAxes()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let W = bounds.width
        let H = bounds.height
        let on = isActive
        // Both axes matter: landscape phones have much less vertical room.
        let cell = min(48, max(30, min(W * 0.105, (H - 74) / 4.6)))
        let stick = min(100, cell * 1.7)
        leftStickView.isHidden = !on
        rightStickView.isHidden = !on
        let leftCX = cell * 1.5 + 4
        let rightCX = W - leftCX
        leftStickView.frame = CGRect(x: leftCX - stick / 2, y: H - stick - 4, width: stick, height: stick)
        rightStickView.frame = CGRect(x: rightCX - stick / 2, y: H - stick - 4, width: stick, height: stick)
        leftStickView.knobSize(stick * 0.4)
        rightStickView.knobSize(stick * 0.4)
        let padY = max(48, leftStickView.frame.minY - cell * 3 - 8)
        dpad(4, padY, cell, on)
        let rightX = W - 4 - 3 * cell
        placeButton(abTriangle, rightX + cell, padY, cell, on)
        placeButton(abSquare, rightX, padY + cell, cell, on)
        placeButton(abCircle, rightX + 2 * cell, padY + cell, cell, on)
        placeButton(abCross, rightX + cell, padY + 2 * cell, cell, on)
        placeButton(btnSelect, W / 2 - 55, H - 44, 44, on)
        placeButton(btnStart, W / 2 + 11, H - 44, 44, on)
        placeButton(btnL, leftCX - 22, 0, 44, on)
        placeButton(btnR, rightCX - 22, 0, 44, on)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Empty overlay space belongs to the game's front touchscreen.
        isActive && subviews.contains { !$0.isHidden && $0.frame.contains(point) }
    }

    func resetInput() {
        pressed.removeAll()
        pressedExt.removeAll()
        for button in buttonCache.values {
            button.isHighlighted = false
            button.setInputPressed(false, animated: false)
        }
        leftStickView.center()
        rightStickView.center()
        leftStick = (0, 0)
        rightStick = (0, 0)
        Vita3KCore.virtualAxes(lx: 0, ly: 0, rx: 0, ry: 0)
        Vita3KCore.virtualButtons(0, 0)
    }

    // MARK: - Layout helpers

    private func placeButton(_ b: UIButton, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ on: Bool) {
        b.frame = CGRect(x: x, y: y, width: size, height: size)
        b.isHidden = !on
        b.layer.cornerRadius = size / 2
    }

    private func dpad(_ x: CGFloat, _ y: CGFloat, _ c: CGFloat, _ on: Bool) {
        // (col,row): up=(1,0) left=(0,1) right=(2,1) down=(1,2)
        placeButton(dpUp, x + c, y, c, on)
        placeButton(dpLeft, x, y + c, c, on)
        placeButton(dpRight, x + c * 2, y + c, c, on)
        placeButton(dpDown, x + c, y + c * 2, c, on)
    }

    // MARK: - Button widgets (created once, reused across layouts)

    private var buttonCache: [Int: InputFeedbackButton] = [:]

    private func button(_ title: String, tag: Int) -> UIButton {
        if let b = buttonCache[tag] {
            return b
        }
        let b = InputFeedbackButton(frame: .zero)
        b.configuration = .plain()
        b.configuration?.title = title
        b.configuration?.contentInsets = .zero
        b.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = .systemFont(ofSize: tag >= 30 ? 11 : 20, weight: .semibold)
            return attributes
        }
        b.titleLabel?.numberOfLines = 1
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.tintColor = .white.withAlphaComponent(0.85)
        b.tag = tag
        b.accessibilityIdentifier = "pad-\(tag)"
        b.accessibilityLabel = title
        addSubview(b)
        wire(b)
        buttonCache[tag] = b
        return b
    }

    private var dpUp: UIButton { button("▲", tag: 0) }
    private var dpLeft: UIButton { button("◀", tag: 1) }
    private var dpRight: UIButton { button("▶", tag: 2) }
    private var dpDown: UIButton { button("▼", tag: 3) }
    private var abTriangle: UIButton { button("△", tag: 10) }
    private var abSquare: UIButton { button("□", tag: 11) }
    private var abCross: UIButton { button("✕", tag: 12) }
    private var abCircle: UIButton { button("◯", tag: 13) }
    private var btnL: UIButton { button("L", tag: 20) }
    private var btnR: UIButton { button("R", tag: 21) }
    private var btnSelect: UIButton { button("SEL", tag: 30) }
    private var btnStart: UIButton { button("ST", tag: 31) }

    private func wire(_ b: UIButton) {
        b.addTarget(self, action: #selector(buttonDown(_:)), for: .touchDown)
        b.addTarget(self, action: #selector(buttonUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func buttonDown(_ sender: UIButton) {
        (sender as? InputFeedbackButton)?.setInputPressed(true)
        setPressed(buttonBit(sender.tag, ext: false), ext: false, on: true)
        setPressed(buttonBit(sender.tag, ext: true), ext: true, on: true)
        pushButtons()
    }

    @objc private func buttonUp(_ sender: UIButton) {
        (sender as? InputFeedbackButton)?.setInputPressed(false)
        setPressed(buttonBit(sender.tag, ext: false), ext: false, on: false)
        setPressed(buttonBit(sender.tag, ext: true), ext: true, on: false)
        pushButtons()
    }

    private func buttonBit(_ tag: Int, ext: Bool) -> UInt32 {
        switch tag {
        case 0: return SceCtrl.up
        case 1: return SceCtrl.left
        case 2: return SceCtrl.right
        case 3: return SceCtrl.down
        case 10: return SceCtrl.triangle
        case 11: return SceCtrl.square
        case 12: return SceCtrl.cross
        case 13: return SceCtrl.circle
        case 20: return ext ? SceCtrl.extL1 : SceCtrl.l
        case 21: return ext ? SceCtrl.extR1 : SceCtrl.r
        case 30: return SceCtrl.select
        case 31: return SceCtrl.start
        default: return 0
        }
    }

    private func setPressed(_ bit: UInt32, ext: Bool, on: Bool) {
        guard bit != 0 else { return }
        if on {
            _ = ext ? pressedExt.insert(bit) : pressed.insert(bit)
        } else {
            _ = ext ? pressedExt.remove(bit) : pressed.remove(bit)
        }
    }

    private func pushButtons() {
        guard isActive else { return }
        var m: UInt32 = 0
        for b in pressed { m |= b }
        var me: UInt32 = 0
        for b in pressedExt { me |= b }
        Vita3KCore.virtualButtons(m, me)
    }

    private func pushAxes() {
        guard isActive else { return }
        Vita3KCore.virtualAxes(lx: leftStick.0, ly: leftStick.1, rx: rightStick.0, ry: rightStick.1)
    }

    /// Show/hide the pad and enable/disable it in the core.
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        isUserInteractionEnabled = on
        if on {
            Vita3KCore.virtualPadEnabled(true)
        } else {
            resetInput()
            Vita3KCore.virtualPadEnabled(false)
        }
        setNeedsLayout()
    }
}

extension VirtualStickView {
    func knobSize(_ s: CGFloat) {
        knob.bounds.size = CGSize(width: s, height: s)
        knob.layer.cornerRadius = s / 2
        layoutIfNeeded()
    }
}
