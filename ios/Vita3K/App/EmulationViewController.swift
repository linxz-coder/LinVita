// Vita3K iOS shell app
// Step 6: fullscreen UIKit surface hosting the Vulkan/MoltenVK scene.
// Step 7: the same surface hosts the production app session
// (AppSessionController) when `appPath` is set.
//
// All UIKit work happens on the main thread; the core renders on its own
// thread and only reads the lock-free frame host state. The CAMetalLayer is
// delivered to the core through the frame-host channel before the session
// starts. Losing focus suspends CPU/audio and drains GPU submissions while
// retaining the session; only an explicit exit tears it down.

import SwiftUI
import UIKit
import Vita3KCore

/// UIKit-owned CAMetalLayer surface. The layer is handed to the core as an
/// opaque pointer; its pixel drawable size is the extent the swapchain is
/// built from.
final class MetalSurfaceView: UIView {
    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    /// Last pixel size fed to the core (0/0 until the first layout).
    private(set) var drawableWidth = 0
    private(set) var drawableHeight = 0
    private var motionRotation: Int32 = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        // MoltenVK manages the layer's drawables through the
        // VK_EXT_metal_surface; it owns presentation on its own Metal queue.
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = false
        metalLayer.presentsWithTransaction = false
        metalLayer.backgroundColor = UIColor.black.cgColor
        // Step 9: multitouch capture (front touchscreen).
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = L10n.text("Tela do jogo")
        accessibilityIdentifier = "game-surface"
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: MetalSurfaceView, _: UITraitCollection) in
            view.setNeedsLayout()
        }
    }

    // Step 9: front-touch capture. Pixel coordinates of this surface are
    // passed to the core, which maps them through the renderer's letterbox
    // viewport to 960x544 content coordinates. A cancelled touch is
    // delivered as "up" so no finger can stick in the core's state.
    private var fingerIDs: [ObjectIdentifier: Int32] = [:]
    private var nextFingerID: Int32 = 1

    private func fingerID(for touch: UITouch) -> Int32 {
        let key = ObjectIdentifier(touch)
        if let id = fingerIDs[key] { return id }
        let id = nextFingerID
        nextFingerID += 1
        fingerIDs[key] = id
        return id
    }

    private func dropFinger(_ touch: UITouch) {
        fingerIDs[ObjectIdentifier(touch)] = nil
    }

    private func touchPixels(_ touch: UITouch) -> (Int32, Int32) {
        let p = touch.location(in: self)
        let scale = contentScaleFactor
        return (Int32((p.x * scale).rounded()), Int32((p.y * scale).rounded()))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            Vita3KCore.inputTouchEvent(event: 0, fingerID: fingerID(for: touch), px: x, py: y)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            Vita3KCore.inputTouchEvent(event: 1, fingerID: fingerID(for: touch), px: x, py: y)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            Vita3KCore.inputTouchEvent(event: 2, fingerID: fingerID(for: touch), px: x, py: y)
            dropFinger(touch)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            Vita3KCore.inputTouchEvent(event: 2, fingerID: fingerID(for: touch), px: x, py: y)
            dropFinger(touch)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // This is the view's backing layer, not a sublayer. UIKit owns its
        // frame; assigning bounds here would reset the view's origin to zero
        // and render under the toolbar after portrait/landscape relayout.
        applyDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyDrawableSize()
    }

    /// drawableSize is in PIXELS (contentScale included). UIKit main thread
    /// only: the render thread never touches the layer, it reads the size
    /// the core stores lock-free.
    func applyDrawableSize() {
        if let orientation = window?.windowScene?.interfaceOrientation {
            let rotation: Int32?
            // UIKit interface orientation is opposite to UIDevice orientation.
            // Camera right: portrait gravity +X becomes game gravity -Y.
            switch orientation {
            case .portrait: rotation = 0
            case .landscapeRight: rotation = 1
            case .portraitUpsideDown: rotation = 2
            case .landscapeLeft: rotation = 3
            default: rotation = nil
            }
            if let rotation, rotation != motionRotation {
                vita3k_ios_input_set_motion_rotation(rotation)
                motionRotation = rotation
            }
        }
        // A UIView backed by CAMetalLayer can keep the default 1 pixel per
        // point even on a Retina screen. Present at the screen's pixel
        // density so internal upscaling is not lost in a low-res drawable.
        // Touch input uses this same contentScaleFactor above.
        let scale = max(1, window?.screen.nativeScale ?? traitCollection.displayScale)
        if contentScaleFactor != scale {
            contentScaleFactor = scale
        }
        let w = max(1, Int((bounds.width * scale).rounded()))
        let h = max(1, Int((bounds.height * scale).rounded()))
        if w != drawableWidth || h != drawableHeight {
            metalLayer.drawableSize = CGSize(width: w, height: h)
            drawableWidth = w
            drawableHeight = h
            Probe.mark("game-surface points=\(bounds.width)x\(bounds.height) scale=\(scale) drawable=\(w)x\(h)")
        }
        Vita3KCore.frameHostSetSize(width: Int32(w), height: Int32(h))
    }

    /// Opaque pointer to the layer for the C bridge.
    var layerPointer: UnsafeMutableRawPointer {
        unsafeBitCast(metalLayer, to: UnsafeMutableRawPointer.self)
    }
}

final class EmulationViewController: UIViewController {
    private let onExit: () -> Void

    /// nil = step 6 Vulkan/MoltenVK demo; otherwise a title id to boot (step 7).
    private let appPath: String?

    private let surfaceView = MetalSurfaceView()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let performanceOverlay = PerformanceOverlayView()
    private var frameSampler = GuestFrameSampler()
    // Fullscreen play: no top bar. The HOME button (top center, visible
    // while a session is active) pauses the game and offers "Continuar" /
    // "Exit Game" — teardown finishes before returning to the library.
    private let homeButton = CompactOverlayButton(frame: .zero)
    private let touchPortButton = CompactOverlayButton(frame: .zero)
    private let controlsVisibilityButton = CompactOverlayButton(frame: .zero)
    private var hudState = ControllerHUDState()
    private var hudHideTask: Task<Void, Never>?
    private var hudVisible = false
    private let hudOpacity: CGFloat = 0.55
    private let touchPortHint = UILabel()
    private var touchHintTask: Task<Void, Never>?
    private var rearTouch = false
    private let homeMenu = UIView()
    private let homeResume = UIButton(configuration: .borderedProminent())
    private let homeExit = UIButton(configuration: .bordered())
    private let homeTitle = UILabel()
    private var userPaused = false
    private let exitCoordinator = GameExitCoordinator()
    private var jitWarningShown = false

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        AppOrientation.supportedOrientations
    }
    override var shouldAutorotate: Bool { true }

    /// Fullscreen while playing: hide the status bar on the game surface.
    override var prefersStatusBarHidden: Bool {
        isSessionMode
    }

    // Both sceImeOpen and sceImeDialogInit use the native iPhone keyboard.
    private let imeBar = GameKeyboardView()
    private var imeVisible = false
    private var dismissedImeRequest: UInt64?

    // Step 9: on-screen (virtual) gamepad. Shown while a session is
    // running and no physical gamepad is attached; it writes SCE_CTRL
    // button masks and -1..1 analogs into the core (blended with any
    // physical pad) so touch-only play works without external hardware.
    private let vpad = VirtualGamepadView()
    private var vpadVisible = false

    /// Debug: cap the number of vpad-check probe markers per VC instance.
    private var vpadDebug = 0

    /// Debug hook: force the on-screen pad even with a (phantom) physical
    /// pad detected — the simulator sees the Mac's host controllers. Set
    /// via the VITA3K_FORCE_VPAD env var or a force-vpad.txt marker in
    /// Documents.
    static func forceVpadEnabled() -> Bool {
        if ProcessInfo.processInfo.environment["VITA3K_FORCE_VPAD"] == "1" {
            return true
        }
        return FileManager.default.fileExists(atPath: Self.basePath + "/force-vpad.txt")
    }

    private var pollTask: Task<Void, Never>?
    private var jitKeepaliveTick = 0
    private var startInFlight = false
    private var userExited = false
    private var appSuspended = false
    private var appResigningObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?

    /// Both flavors now link MoltenVK (device slice from the XCFramework,
    /// simulator slice built from source), so the core always has a Vulkan
    /// driver available on this surface.
    private var hasMoltenVK: Bool { true }

    init(appPath: String?, onExit: @escaping () -> Void) {
        self.appPath = appPath
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .black
        view = root
        root.addGestureRecognizer(ScreenActivityRecognizer { [weak self] touching in
            guard let self else { return }
            self.hudState.screenActivity(touching: touching, now: ProcessInfo.processInfo.systemUptime)
            self.updateOverlayControls()
        })

        surfaceView.frame = root.bounds
        root.addSubview(surfaceView)

        // Fullscreen: no top bar. HOME (top center) pauses the game and
        // shows a small menu with "Continuar" / "Voltar à biblioteca".
        homeButton.translatesAutoresizingMaskIntoConstraints = false
        homeButton.configuration?.image = UIImage(systemName: "house.fill",
                                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 14))
        homeButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        homeButton.configuration?.contentInsets = .zero
        homeButton.tintColor = .white
        homeButton.accessibilityLabel = L10n.text("Home")
        homeButton.accessibilityIdentifier = "home-button"
        homeButton.isHidden = true
        homeButton.addAction(UIAction { [weak self] _ in self?.homeTapped() }, for: .touchUpInside)

        homeMenu.translatesAutoresizingMaskIntoConstraints = false
        homeMenu.backgroundColor = .black.withAlphaComponent(0.78)
        homeMenu.layer.cornerRadius = 18
        homeMenu.isHidden = true
        homeTitle.text = L10n.text("Pausado")
        homeTitle.translatesAutoresizingMaskIntoConstraints = false
        homeTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        homeTitle.textColor = .white
        homeTitle.textAlignment = .center
        homeTitle.adjustsFontSizeToFitWidth = true
        homeTitle.minimumScaleFactor = 0.65
        homeResume.configuration?.title = L10n.text("Continuar")
        homeResume.configuration?.baseForegroundColor = .white
        homeResume.translatesAutoresizingMaskIntoConstraints = false
        homeResume.accessibilityIdentifier = "resume-game"
        homeResume.addAction(UIAction { [weak self] _ in self?.resumeGame() }, for: .touchUpInside)
        homeExit.configuration?.title = L10n.text("game.exit")
        homeExit.configuration?.baseForegroundColor = .white
        homeExit.translatesAutoresizingMaskIntoConstraints = false
        homeExit.accessibilityIdentifier = "exit-game"
        homeExit.addAction(UIAction { [weak self] _ in self?.exit() }, for: .touchUpInside)
        homeMenu.addSubview(homeTitle)
        homeMenu.addSubview(homeResume)
        homeMenu.addSubview(homeExit)

        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 2
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .white.withAlphaComponent(0.85)
        detailLabel.numberOfLines = 3

        let bottom = UIStackView()
        bottom.addArrangedSubview(statusLabel)
        bottom.addArrangedSubview(detailLabel)
        bottom.axis = .vertical
        bottom.alignment = .leading
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.backgroundColor = .black.withAlphaComponent(0.55)

        // Step 9: IME software keyboard (session mode only).
        imeBar.translatesAutoresizingMaskIntoConstraints = false
        imeBar.isHidden = true
        imeBar.onEdit = { id, text, caret in Vita3KCore.imeReplace(id: id, text: text, caret: caret) }
        imeBar.onFinish = { [weak self] id, cancel in
            guard Vita3KCore.imeFinish(id: id, cancel: cancel) else { return false }
            self?.dismissedImeRequest = id
            self?.imeHide()
            return true
        }

        root.addSubview(homeButton)
        touchPortButton.translatesAutoresizingMaskIntoConstraints = false
        touchPortButton.configuration?.title = L10n.text("controller.frontTouch")
        touchPortButton.configuration?.baseForegroundColor = .white
        touchPortButton.isHidden = true
        touchPortButton.accessibilityIdentifier = "touch-port-toggle"
        touchPortButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Vita3KCore.inputClear()
            self.vpad.resetInput()
            self.rearTouch.toggle()
            Vita3KCore.setRearTouch(self.rearTouch)
            self.touchPortButton.configuration?.title = L10n.text(self.rearTouch ? "controller.rearTouch" : "controller.frontTouch")
            self.touchHintTask?.cancel()
            self.touchPortHint.isHidden = !self.rearTouch
            if self.rearTouch {
                self.touchHintTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.touchPortHint.isHidden = true
                }
            }
        }, for: .touchUpInside)
        root.addSubview(touchPortButton)
        controlsVisibilityButton.translatesAutoresizingMaskIntoConstraints = false
        controlsVisibilityButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        controlsVisibilityButton.configuration?.contentInsets = .zero
        controlsVisibilityButton.accessibilityIdentifier = "controls-visibility-toggle"
        controlsVisibilityButton.isHidden = true
        controlsVisibilityButton.alpha = hudOpacity
        controlsVisibilityButton.addAction(UIAction { [weak self] _ in self?.toggleControlsVisibility() }, for: .touchUpInside)
        root.addSubview(controlsVisibilityButton)
        touchPortHint.translatesAutoresizingMaskIntoConstraints = false
        touchPortHint.text = L10n.text("controller.rearTouchHint")
        touchPortHint.font = .systemFont(ofSize: 14, weight: .medium)
        touchPortHint.textColor = .white
        touchPortHint.backgroundColor = .black.withAlphaComponent(0.8)
        touchPortHint.textAlignment = .center
        touchPortHint.numberOfLines = 0
        touchPortHint.isUserInteractionEnabled = false
        touchPortHint.isHidden = true
        root.addSubview(touchPortHint)
        root.addSubview(bottom)
        root.addSubview(imeBar)
        root.addSubview(homeMenu)
        // On-screen gamepad fills the screen; its widgets are anchored to
        // the bottom. It sits above the surface but below the IME bar.
        vpad.frame = root.bounds
        vpad.alpha = UserDefaults.standard.object(forKey: "emulation.controlOpacity") as? Double ?? 0.8
        homeButton.alpha = hudOpacity
        touchPortButton.alpha = hudOpacity
        root.addSubview(vpad)
        performanceOverlay.translatesAutoresizingMaskIntoConstraints = false
        performanceOverlay.isHidden = true
        root.addSubview(performanceOverlay)
        root.bringSubviewToFront(homeButton)
        root.bringSubviewToFront(touchPortButton)
        root.bringSubviewToFront(controlsVisibilityButton)
        root.bringSubviewToFront(touchPortHint)
        root.bringSubviewToFront(imeBar)
        root.bringSubviewToFront(homeMenu)

        NSLayoutConstraint.activate([
            performanceOverlay.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            performanceOverlay.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            performanceOverlay.trailingAnchor.constraint(lessThanOrEqualTo: controlsVisibilityButton.leadingAnchor, constant: -8),

            // Stay in the same place when the other controls disappear.
            controlsVisibilityButton.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            controlsVisibilityButton.trailingAnchor.constraint(equalTo: homeButton.leadingAnchor, constant: -8),
            controlsVisibilityButton.widthAnchor.constraint(equalToConstant: 44),
            controlsVisibilityButton.heightAnchor.constraint(equalToConstant: 44),

            homeButton.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            homeButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            homeButton.widthAnchor.constraint(equalToConstant: 44),
            homeButton.heightAnchor.constraint(equalToConstant: 44),

            touchPortButton.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            // Keep this control clear of the virtual R shoulder button.
            touchPortButton.leadingAnchor.constraint(equalTo: homeButton.trailingAnchor, constant: 8),
            touchPortButton.trailingAnchor.constraint(lessThanOrEqualTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            touchPortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            touchPortButton.heightAnchor.constraint(equalToConstant: 44),
            touchPortHint.topAnchor.constraint(equalTo: touchPortButton.bottomAnchor, constant: 8),
            touchPortHint.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            touchPortHint.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            touchPortHint.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            homeMenu.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            homeMenu.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            homeMenu.widthAnchor.constraint(equalToConstant: 300),
            homeMenu.heightAnchor.constraint(equalToConstant: 156),
            homeTitle.topAnchor.constraint(equalTo: homeMenu.topAnchor, constant: 16),
            homeTitle.leadingAnchor.constraint(equalTo: homeMenu.leadingAnchor, constant: 16),
            homeTitle.trailingAnchor.constraint(equalTo: homeMenu.trailingAnchor, constant: -16),
            homeResume.topAnchor.constraint(equalTo: homeTitle.bottomAnchor, constant: 12),
            homeResume.leadingAnchor.constraint(equalTo: homeMenu.leadingAnchor, constant: 16),
            homeResume.trailingAnchor.constraint(equalTo: homeMenu.trailingAnchor, constant: -16),
            homeResume.heightAnchor.constraint(equalToConstant: 40),
            homeExit.topAnchor.constraint(equalTo: homeResume.bottomAnchor, constant: 10),
            homeExit.leadingAnchor.constraint(equalTo: homeMenu.leadingAnchor, constant: 16),
            homeExit.trailingAnchor.constraint(equalTo: homeMenu.trailingAnchor, constant: -16),
            homeExit.heightAnchor.constraint(equalToConstant: 40),

            bottom.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),

            imeBar.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            imeBar.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            imeBar.bottomAnchor.constraint(equalTo: root.keyboardLayoutGuide.topAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Fullscreen: the surface fills the safe area (no top bar). In
        // portrait the game sits on top and the on-screen pad below it.
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let content = safe
        let portrait = view.bounds.height > view.bounds.width
        if portrait && isSessionMode && vpadVisible {
            let screenHeight = min(content.width * 544 / 960, content.height * 0.48)
            surfaceView.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: screenHeight)
            vpad.frame = CGRect(x: content.minX, y: surfaceView.frame.maxY + 8,
                                width: content.width, height: max(1, content.maxY - surfaceView.frame.maxY - 8))
        } else {
            surfaceView.frame = content
            vpad.frame = content.insetBy(dx: 8, dy: 4)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        // Do not carry held fingers/buttons into a different coordinate space.
        Vita3KCore.inputClear()
        vpad.resetInput()
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.view.setNeedsLayout(); self.view.layoutIfNeeded() })
    }

    /// HOME (the only in-game control): pause the game and show the
    /// Continue / Exit Game menu. A second tap just hides
    /// the menu (the game stays paused).
    private func homeTapped() {
        guard !userExited, isSessionMode, Vita3KCore.sessionIsActive() else { return }
        if !homeMenu.isHidden {
            homeMenu.isHidden = true
            updateOverlayControls()
            return
        }
        if !userPaused {
            guard vita3k_ios_session_set_pause(1, 1) == 0 else { return }
            userPaused = true
            frameSampler.reset()
        }
        homeMenu.isHidden = false
        view.bringSubviewToFront(homeMenu)
        updateOverlayControls()
    }

    private func resumeGame() {
        guard !userExited else { return }
        guard vita3k_ios_session_set_pause(1, 0) == 0 else { return }
        userPaused = false
        homeMenu.isHidden = true
        frameSampler.reset()
        updateOverlayControls()
    }

    private func updateOverlayControls() {
        let now = ProcessInfo.processInfo.systemUptime
        hudState.configure(active: isSessionMode && Vita3KCore.sessionIsActive() && !userExited,
                           controllerConnected: Vita3KCore.gamepadCount() > 0,
                           keepVisible: userPaused || !homeMenu.isHidden || imeVisible || appSuspended,
                           now: now)
        let visible = hudState.isVisible(at: now)
        let showToggle = hudState.visibilityToggleIsVisible(vpadAvailable: virtualPadAvailable, at: now)
            && !imeVisible && !userPaused && homeMenu.isHidden
        controlsVisibilityButton.isHidden = !showToggle
        controlsVisibilityButton.isUserInteractionEnabled = showToggle
        controlsVisibilityButton.configuration?.image = UIImage(systemName: hudState.controlsHidden ? "eye" : "eye.slash")
        controlsVisibilityButton.accessibilityLabel = L10n.text(hudState.controlsHidden ? "controller.showControls" : "controller.hideControls")
        controlsVisibilityButton.accessibilityValue = L10n.text(rearTouch ? "controller.rearTouch" : "controller.frontTouch")
        setVpadVisible(virtualPadAvailable && !hudState.controlsHidden)
        performanceOverlay.isHidden = hudState.controlsHidden || Vita3KCore.sessionPhase() != 2
            || !UserDefaults.standard.bool(forKey: "emulation.showStatus")
        homeButton.isUserInteractionEnabled = visible
        touchPortButton.isUserInteractionEnabled = visible && !imeVisible
        if visible != hudVisible {
            hudVisible = visible
            if visible { homeButton.isHidden = false; touchPortButton.isHidden = imeVisible }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.homeButton.alpha = visible ? self.hudOpacity : 0
                self.touchPortButton.alpha = visible ? self.hudOpacity : 0
            } completion: { [weak self] _ in
                guard let self else { return }
                self.homeButton.isHidden = !self.hudVisible
                self.touchPortButton.isHidden = !self.hudVisible || self.imeVisible
            }
        } else {
            touchPortButton.isHidden = !visible || imeVisible
        }
        if !visible { touchPortHint.isHidden = true }
        hudHideTask?.cancel()
        hudHideTask = nil
        if !appSuspended, let delay = hudState.timeUntilHide(at: now) {
            hudHideTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.updateOverlayControls()
            }
        }
    }

    private var virtualPadAvailable: Bool {
        isSessionMode && Vita3KCore.sessionIsActive() && !userExited
            && (Vita3KCore.gamepadCount() == 0 || Self.forceVpadEnabled() || !PhysicalController.hideTouchControls)
            && !imeVisible && Self.showControls
    }

    private func toggleControlsVisibility() {
        guard isSessionMode, Vita3KCore.sessionIsActive(), !imeVisible, !userPaused, homeMenu.isHidden else { return }
        // Hiding in portrait also resizes the game surface; release fingers
        // and pad state before changing its coordinate space. Keep touch port.
        Vita3KCore.inputClear()
        vpad.resetInput()
        hudState.toggleControls(now: ProcessInfo.processInfo.systemUptime)
        touchHintTask?.cancel()
        touchPortHint.isHidden = true
        updateOverlayControls()
        view.layoutIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
        // App lifecycle is delivered as notifications to the VC (the
        // willResignActive/didBecomeActive responder methods are not reliably
        // invoked on a presented view controller).
        appResigningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspendForBackground()
                }
            }
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.userExited, self.viewIfLoaded?.window != nil else { return }
                    self.resumeFromBackground()
                }
            }
        if UIApplication.shared.applicationState == .active {
            vita3k_ios_session_set_background(0)
            startDemo()
        } else {
            suspendForBackground()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        userExited = true
        if let o = appResigningObserver { NotificationCenter.default.removeObserver(o) }
        if let o = appActiveObserver { NotificationCenter.default.removeObserver(o) }
        appResigningObserver = nil
        appActiveObserver = nil
        imeHide()
        vpad.setActive(false)
        // No stuck input may survive the surface's death: lift all fingers
        // and drop the overlay mouse in the core.
        Vita3KCore.inputClear()
        stopDemo()
    }

    deinit {
        pollTask?.cancel()
        touchHintTask?.cancel()
        hudHideTask?.cancel()
    }

    // MARK: - Session

    private func exit() {
        guard !userExited else { return }
        userExited = true
        stopDemo { self.onExit() }
        if isSessionMode {
            homeTitle.text = L10n.text("game.exiting")
            homeResume.isEnabled = false
            homeExit.isEnabled = false
            homeExit.configuration?.showsActivityIndicator = true
            homeMenu.isHidden = false
            homeButton.isUserInteractionEnabled = false
            view.bringSubviewToFront(homeMenu)
        }
    }

    private var isSessionMode: Bool { appPath != nil }

    private func suspendForBackground() {
        // During an orderly exit the surface stays alive. It must still
        // drain GPU work if iOS backgrounds the app before teardown ends.
        guard (!userExited || exitCoordinator.started), !appSuspended else { return }
        appSuspended = true
        pollTask?.cancel()
        pollTask = nil
        frameSampler.reset()
        vpad.resetInput()
        Vita3KCore.inputClear()
        // Do not dismiss the IME request or clear its text/selection. UIKit
        // retains the editing view across application activation changes.
        vita3k_ios_session_set_background(1)
        Probe.mark("lifecycle suspended " + Vita3KCore.sessionReport())
    }

    private func resumeFromBackground() {
        guard appSuspended, !userExited else { return }
        if isSessionMode, Vita3KCore.jitValidateAlive() != 0 {
            showJITUnavailable()
            return
        }
        appSuspended = false
        view.layoutIfNeeded()
        surfaceView.applyDrawableSize()
        vita3k_ios_session_set_background(0)
        Probe.mark("lifecycle resumed " + Vita3KCore.sessionReport())
        // Starting is also a live session: never submit a second launch.
        if startInFlight || (isSessionMode ? Vita3KCore.sessionPhase() != 0 : Vita3KCore.vulkanDemoIsRunning()) {
            startPolling()
            if imeVisible { imeBar.textView.becomeFirstResponder() }
        } else {
            startDemo()
        }
    }

    private func showJITUnavailable() {
        statusLabel.isHidden = false
        statusLabel.text = L10n.text("JIT indisponível — reabra pelo StikDebug.")
        // Keep the guest suspended until the user exits. Do not run cached
        // JIT code after the grant has been revoked, or auto-launch a new game.
        suspendForBackground()
        guard !jitWarningShown else { return }
        jitWarningShown = true
        let alert = UIAlertController(title: L10n.text("Abra pelo StikDebug"), message: L10n.text("O JIT não está mais disponível. Inicie o LinVita pelo StikDebug usando Universal."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.text("Voltar à biblioteca"), style: .default) { [weak self] _ in self?.exit() })
        present(alert, animated: true)
    }

    private func startDemo() {
        guard !userExited, !appSuspended, !startInFlight else { return }
        guard !isSessionMode || Vita3KCore.jitValidateAlive() == 0 else {
            statusLabel.text = L10n.text("JIT indisponível. Abra o LinVita pelo StikDebug com Universal.")
            return
        }
        view.layoutIfNeeded()
        if !isSessionMode {
            guard !Vita3KCore.vulkanDemoIsRunning() else { return }
        }
        startInFlight = true
        Probe.mark("startDemo mode=\(isSessionMode ? "game" : "demo") appPath=\(appPath ?? "nil")")
        statusLabel.text = isSessionMode ? L10n.text("inicializando sessão…") : L10n.text("inicializando Vulkan/MoltenVK…")
        detailLabel.text = ""

        let basePath = Self.basePath
        let staticAssets = Bundle.main.bundlePath
        let width = surfaceView.drawableWidth
        let height = surfaceView.drawableHeight
        let moltenvk: Int32 = hasMoltenVK ? 1 : 0

        if isSessionMode {
            // A previously exited session may still be tearing down: wait, bounded,
            // for it to become idle before delivering the layer and spawning
            // the new session on the main thread.
            Task { @MainActor [weak self] in
                let deadline = Date().addingTimeInterval(30)
                while Vita3KCore.sessionPhase() != 0, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard let self, !self.userExited, !self.appSuspended else {
                    self?.startInFlight = false
                    return
                }
                guard Vita3KCore.sessionPhase() == 0 else {
                    self.startInFlight = false
                    self.statusLabel.text = L10n.text("sessão anterior não encerrou")
                    return
                }
                // The CAMetalLayer is UIKit (main-thread) owned: deliver it to
                // the core on the main thread, through the frame-host channel,
                // before the session is spawned. The heavy work (renderer
                // init, 4 GiB reservation, app load) runs on the core's thread.
                Vita3KCore.frameHostSetLayer(self.surfaceView.layerPointer)
                Vita3KCore.frameHostSetSize(width: Int32(width), height: Int32(height))
                guard let appPath else {
                    self.startInFlight = false
                    self.statusLabel.text = L10n.text("sem título para a sessão")
                    return
                }
                // Step 7: the C facade spawns the launch worker itself.
                PhysicalController.applyPreferences()
                let rc = Vita3KCore.sessionLaunch(appPath: appPath, width: Int32(width), height: Int32(height))
                self.startInFlight = false
                if rc == 0 {
                    self.statusLabel.text = L10n.format("iniciando %@…", appPath)
                    self.startPolling()
                } else {
                    self.statusLabel.text = L10n.format("launch falhou (rc=%d)", rc)
                    self.detailLabel.text = Vita3KCore.sessionReport()
                }
            }
            return
        }

        // The CAMetalLayer is UIKit (main-thread) owned: deliver it to the
        // core on the main thread, through the frame-host channel, before
        // the demo is spawned (the session path does its own delivery after
        // waiting for a previous session to stop).
        Vita3KCore.frameHostSetLayer(surfaceView.layerPointer)
        Vita3KCore.frameHostSetSize(width: Int32(width), height: Int32(height))

        Task.detached(priority: .userInitiated) { [weak self] in
            // renderer::init creates the instance/device/swapchain and
            // compiles the screen filter pipeline (SPIR-V -> MSL): this can
            // take a couple of seconds, so it must not block the UI.
            let (rc, report) = Vita3KCore.startVulkanDemo(
                basePath: basePath, staticAssets: staticAssets,
                hasMoltenVK: moltenvk, width: Int32(width), height: Int32(height))

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.startInFlight = false
                if rc == 0 {
                    self.show(report: report)
                    self.startPolling()
                } else {
                    self.statusLabel.text = L10n.format("demo indisponível (rc=%d)", rc)
                    self.detailLabel.text = report
                }
            }
        }
    }

    private func stopDemo(onStopped: @escaping @MainActor @Sendable () -> Void = {}) {
        hudHideTask?.cancel()
        hudHideTask = nil
        imeHide()
        dismissedImeRequest = nil
        performanceOverlay.isHidden = true
        frameSampler.reset()
        pollTask?.cancel()
        pollTask = nil
        // Runtime teardown clears the core's pad state and its visibility.
        setVpadVisible(false)
        homeMenu.isHidden = true
        userPaused = false

        if isSessionMode {
            exitCoordinator.stop(
                requestStop: { _ = Vita3KCore.sessionStop() },
                isStopped: { Vita3KCore.sessionPhase() == 0 },
                onSlowStop: {
                    self.homeTitle.text = L10n.text("game.exitSlow")
                },
                onStopped: {
                    self.statusLabel.text = L10n.text("sessão parada")
                    onStopped()
                })
            return
        }

        guard Vita3KCore.vulkanDemoIsRunning() else { onStopped(); return }
        Task.detached(priority: .userInitiated) {
            // stop joins the render thread and waits the GPU idle.
            _ = Vita3KCore.stopVulkanDemo()
            await MainActor.run {
                self.statusLabel.text = L10n.text("demo parado")
                onStopped()
            }
        }
    }

    private func startPolling() {
        guard !appSuspended, !userExited else { return }
        pollTask?.cancel()
        frameSampler.reset()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await MainActor.run {
                    if self.isSessionMode {
                        let phase = Vita3KCore.sessionPhase()
                        if ProcessInfo.processInfo.environment["VITA3K_UI_TEST"] == "1" {
                            // Read-only continuity evidence for lifecycle UI tests.
                            self.surfaceView.accessibilityValue = Vita3KCore.sessionReport()
                                .components(separatedBy: "\n")
                                .filter { $0.hasPrefix("lifecycle:") || $0.hasPrefix("paused:") }
                                .joined(separator: " ")
                        }
                        let showStatus = UserDefaults.standard.bool(forKey: "emulation.showStatus")
                        switch phase {
                        case 1:
                            self.statusLabel.text = L10n.text("inicializando sessão…")
                        case 2:
                            self.statusLabel.text = self.userPaused ? L10n.text("Pausado") : L10n.text("Em execução")
                        case 3:
                            self.statusLabel.text = L10n.text("Encerrando sessão…")
                        case 4:
                            self.statusLabel.text = L10n.text("Falha ao iniciar o jogo. Consulte o diagnóstico.")
                        default:
                            self.statusLabel.text = L10n.text("Sessão encerrada")
                        }
                        self.statusLabel.isHidden = phase == 2 && !self.userPaused
                        self.detailLabel.text = ""
                        self.performanceOverlay.isHidden = phase != 2 || !showStatus || self.hudState.controlsHidden
                        if !self.performanceOverlay.isHidden {
                            let paused = Vita3KCore.sessionIsPaused()
                            let frames = self.frameSampler.sample(frames: Vita3KCore.sessionFrameCount(),
                                                                  time: ProcessInfo.processInfo.systemUptime,
                                                                  paused: paused)
                            self.performanceOverlay.update(frames: frames,
                                                           memory: PerformanceMemory.read(device: self.surfaceView.metalLayer.device),
                                                           paused: paused)
                        } else {
                            self.frameSampler.reset()
                        }
                        if phase == 4 {
                            let report = Vita3KCore.sessionReport()
                            self.detailLabel.text = report.components(separatedBy: "\n").first(where: { $0.hasPrefix("error:") })
                        }
                        // HOME button while a session is active; the pause
                        // menu cannot outlive the session.
                        let active = Vita3KCore.sessionIsActive()
                        if !active {
                            self.homeMenu.isHidden = true
                            self.touchPortHint.isHidden = true
                            self.userPaused = false
                        }
                        // Step 9: mirror the guest's IME state into the
                        // software keyboard visibility.
                        let request = Vita3KCore.imeSnapshot()
                        if let request, request.id != self.dismissedImeRequest {
                            if !self.imeVisible || self.imeBar.request?.id != request.id {
                                self.imeShow(request)
                            }
                        } else if self.imeVisible {
                            self.imeHide()
                        }
                        self.updateOverlayControls()
                        // updateOverlayControls also applies manual hiding;
                        // polling must never bring a hidden pad back.
                        if self.vpadDebug <= 3 {
                            self.vpadDebug += 1
                            Probe.mark("vpad-check available=\(self.virtualPadAvailable) active=\(Vita3KCore.sessionIsActive()) pads=\(Vita3KCore.gamepadCount()) ime=\(self.imeVisible) visible=\(self.vpadVisible)")
                        }
                        // JIT keep-alive (the ARMSX2 pattern): the StikDebug
                        // session can be revoked after ~30-60 s of
                        // inactivity; probe every ~12 s and surface the
                        // expiry so the user can relaunch via StikDebug.
                        self.jitKeepaliveTick += 1
                        if self.jitKeepaliveTick % 12 == 0, Vita3KCore.jitValidateAlive() != 0 {
                            self.showJITUnavailable()
                            Probe.mark("jit-keepalive: grant revoked")
                        }
                    } else {
                        self.show(report: Vita3KCore.vulkanDemoReport())
                    }
                }
            }
        }
    }

    /// One-line status + the full report, straight from the core (demo mode).
    private func show(report: String) {
        let lines = report.components(separatedBy: "\n")
        var first = lines.first ?? ""
        if lines.contains("running: yes") {
            first = L10n.text("demo ativo")
            if let f = lines.first(where: { $0.hasPrefix("fps:") }),
               let fr = lines.first(where: { $0.hasPrefix("frames:") }) {
                first += "  \(String(fr.split(separator: ":").last ?? ""))  \(String(f.split(separator: ":").last ?? ""))"
            }
        }
        if let gpu = lines.first(where: { $0.hasPrefix("gpu:") }) {
            first += "\n\(gpu)"
        }
        statusLabel.text = first
        detailLabel.text = lines.dropFirst().joined(separator: "\n")
    }

    // MARK: - Step 9: IME software keyboard

    private func imeShow(_ request: GameKeyboardRequest) {
        imeVisible = true
        view.bringSubviewToFront(imeBar)
        imeBar.present(request)
        // The keyboard takes the bottom of the screen: hide the pad.
        if vpadVisible {
            setVpadVisible(false)
        }
    }

    private func imeHide() {
        guard imeVisible else { return }
        imeVisible = false
        imeBar.dismiss()
        // Respect manual hiding when the game's keyboard goes away.
        updateOverlayControls()
    }

    /// Show/hide the on-screen gamepad (also enables/disables it in the
    /// core and clears its state when hiding).
    private func setVpadVisible(_ on: Bool) {
        guard on != vpadVisible else { return }
        vpadVisible = on
        vpad.setActive(on)
        view.setNeedsLayout()
        Probe.mark("vpad \(on ? "shown" : "hidden") (gamepads=\(Vita3KCore.gamepadCount()))")
    }

    static var basePath: String {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.path
        }
        return FileManager.default.currentDirectoryPath
    }

    static var showControls: Bool {
        UserDefaults.standard.object(forKey: "emulation.showControls") as? Bool ?? true
    }
}

// MARK: - SwiftUI hosting

struct EmulationSurfaceView: UIViewControllerRepresentable {
    let appPath: String?
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> EmulationViewController {
        let controller = EmulationViewController(appPath: appPath, onExit: onExit)
        Probe.mark("makeUIViewController appPath=\(appPath ?? "nil")")
        return controller
    }

    func updateUIViewController(_ uiViewController: EmulationViewController, context: Context) {}
}
