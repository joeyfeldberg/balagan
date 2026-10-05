import AppKit
import BalaganCore

extension LibGhosttyTerminalHostView {
    override func mouseDown(with event: NSEvent) {
        onActivate?()
        if isActive {
            window?.makeFirstResponder(self)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else {
                return
            }

            self.window?.makeFirstResponder(self)
        }
        forwardMouseButton(event, state: .press, button: .left)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouseButton(event, state: .release, button: .left)
        super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardMousePos(event)
        super.mouseDragged(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardMouseButton(event, state: .press, button: .right)
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardMouseButton(event, state: .release, button: .right)
        super.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        forwardMousePos(event)
        super.rightMouseDragged(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        forwardMouseButton(event, state: .press, button: .middle)
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        forwardMouseButton(event, state: .release, button: .middle)
        super.otherMouseUp(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        forwardMousePos(event)
        super.otherMouseDragged(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        forwardMousePos(event, render: false)
        super.mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceHandle else {
            super.scrollWheel(with: event)
            return
        }

        let point = surfacePoint(for: event)
        let mods = ghosttyMods(from: event)
        surfaceHandle.sendMousePos(x: point.x, y: point.y, mods: mods)

        var scrollMods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            scrollMods |= 1
        }
        scrollMods |= scrollMomentum(for: event) << 1

        surfaceHandle.sendMouseScroll(
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            mods: scrollMods
        )
        requestRenderFrame()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    private func forwardMouseButton(_ event: NSEvent, state: LibGhosttyMouseState, button: LibGhosttyMouseButton) {
        guard let surfaceHandle else {
            return
        }
        let point = surfacePoint(for: event)
        let mods = ghosttyMods(from: event)
        surfaceHandle.sendMousePos(x: point.x, y: point.y, mods: mods)
        surfaceHandle.sendMouseButton(state, button: button, mods: mods)
        requestRenderFrame()
    }

    private func forwardMousePos(_ event: NSEvent, render: Bool = true) {
        guard let surfaceHandle else {
            return
        }
        let point = surfacePoint(for: event)
        surfaceHandle.sendMousePos(x: point.x, y: point.y, mods: ghosttyMods(from: event))
        if render {
            requestRenderFrame()
        }
    }

    private func surfacePoint(for event: NSEvent) -> (x: Double, y: Double) {
        let local = convert(event.locationInWindow, from: nil)
        return (Double(local.x), Double(bounds.height - local.y))
    }

    /// Maps an NSEvent modifier set to libghostty's modifier bitmask
    /// (shift = 1, control = 2, option = 4, command = 8). Shared by `ghosttyMods(from:)` and the
    /// keyboard layer's `consumedMods`.
    func ghosttyModifierBitmask(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= 1 }
        if flags.contains(.control) { mods |= 2 }
        if flags.contains(.option) { mods |= 4 }
        if flags.contains(.command) { mods |= 8 }
        return mods
    }

    func ghosttyMods(from event: NSEvent) -> UInt32 {
        ghosttyModifierBitmask(event.modifierFlags)
    }

    private func scrollMomentum(for event: NSEvent) -> Int32 {
        let phase = event.momentumPhase
        if phase.contains(.began) { return 1 }
        if phase.contains(.stationary) { return 2 }
        if phase.contains(.changed) { return 3 }
        if phase.contains(.ended) { return 4 }
        if phase.contains(.cancelled) { return 5 }
        if phase.contains(.mayBegin) { return 6 }
        return 0
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeSurface()
        layoutSearchBar()
    }
}
