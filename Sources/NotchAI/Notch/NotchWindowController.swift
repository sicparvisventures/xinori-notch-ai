import AppKit
import Combine
import SwiftUI

// MARK: - Panel

/// A borderless, non-activating panel that floats above the menu bar.
///
/// `.nonactivatingPanel` is the important bit: interacting with the notch must
/// never steal focus from whatever the user is actually working in. The panel
/// still becomes *key* while open, which is what lets the text field receive
/// typing without activating the app.
final class NotchPanel: NSPanel {
    /// Only true while the panel is open, so a closed notch can never capture
    /// keyboard focus.
    var isKeyable = false

    override var canBecomeKey: Bool { isKeyable }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        // Above the menu bar and above full-screen apps. `.statusBar` is not
        // enough — the menu bar overlay in full screen sits higher than that.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
    }
}

// MARK: - Container

/// Hosts the SwiftUI content and owns all mouse handling.
///
/// The window is sized for the *largest* state, so most of it is transparent.
/// `hitTest` clips interaction to the currently visible shape, otherwise a
/// 520×300 invisible rectangle would swallow clicks meant for the menu bar.
final class NotchContainerView: NSView {
    private let model: NotchModel
    private var trackingAreaRef: NSTrackingArea?
    private var forceClickHandled = false

    init(model: NotchModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in our superview's space; as the content view that is
        // the window's space, which shares our origin.
        guard model.activeRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }

        // Deliberately not `.inVisibleRect`: the tracking rect must follow the
        // shape, not the (much larger) window.
        let area = NSTrackingArea(rect: model.activeRect,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    /// Call after any state change so the tracking rect matches the new shape.
    func refreshTracking() {
        needsDisplay = true
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        model.setHovering(true)
        refreshTracking()
    }

    override func mouseExited(with event: NSEvent) {
        // While open the panel stays put — the user may be reading or typing.
        // Closing is an explicit act: click the notch, click away, or Escape.
        model.setHovering(false)
        refreshTracking()
    }

    // MARK: Click

    override func mouseDown(with event: NSEvent) {
        forceClickHandled = false
    }

    override func mouseUp(with event: NSEvent) {
        // A force click already toggled on the way down; don't undo it here.
        guard !forceClickHandled else {
            forceClickHandled = false
            return
        }
        model.toggle()
        refreshTracking()
    }

    /// Force click (stage 2) fires the moment the trackpad registers the deeper
    /// press, so a firm press opens without waiting for the release.
    override func pressureChange(with event: NSEvent) {
        guard event.stage >= 2, !forceClickHandled else { return }
        forceClickHandled = true
        model.toggle()
        refreshTracking()
    }
}

// MARK: - Controller

@MainActor
final class NotchWindowController {
    private let model: NotchModel
    private let app: AppModel
    private let panel: NotchPanel
    private let container: NotchContainerView
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?

    init(model: NotchModel, app: AppModel) {
        self.model = model
        self.app = app

        let size = model.windowSize
        let origin = model.windowOrigin
        panel = NotchPanel(contentRect: NSRect(origin: origin, size: size))

        container = NotchContainerView(model: model)
        container.frame = NSRect(origin: .zero, size: size)

        let hosting = NSHostingView(rootView: NotchRootView(model: model, app: app))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // The hosting view must not intercept events outside the shape; the
        // container's hitTest is the single gate for that.
        container.addSubview(hosting)

        panel.contentView = container

        observeState()
        installMonitors()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    func show() {
        panel.orderFrontRegardless()
        container.refreshTracking()
    }

    // MARK: - Focus

    private func observeState() {
        model.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                let open = state == .open
                self.panel.isKeyable = open
                if open {
                    // Key without activating: the frontmost app keeps its focus
                    // ring, we just take the keystrokes.
                    self.panel.makeKeyAndOrderFront(nil)
                } else {
                    if self.panel.isKeyWindow { self.panel.resignKey() }
                    // Never leave the mic hot or a reply talking to an empty notch.
                    Task { await self.app.standDown() }
                }
                self.container.refreshTracking()
            }
            .store(in: &cancellables)
    }

    private func installMonitors() {
        // Clicking anywhere in another app dismisses the panel. Global monitors
        // never see our own clicks, so this can't fight the toggle.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.state == .open else { return }
                self.model.close()
            }
        }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model.state == .open, event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self.model.close() }
            return nil
        }
    }

    // MARK: - Screen changes

    /// Re-seat the panel after a display change (docking, resolution switch,
    /// closing the lid). If the notched screen disappears we simply hide.
    private func reposition() {
        guard let geometry = NotchGeometry.current(),
              geometry.size == model.geometry.size else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(NSRect(origin: model.windowOrigin, size: model.windowSize), display: true)
        panel.orderFrontRegardless()
        container.refreshTracking()
    }
}
