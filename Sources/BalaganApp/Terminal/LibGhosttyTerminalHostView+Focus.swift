import AppKit
import BalaganCore

extension LibGhosttyTerminalHostView {
    override var acceptsFirstResponder: Bool {
        isActive
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        guard isActive else {
            return false
        }
        surfaceHandle?.setFocus(true)
        reportSurfaceFocusedClearingAttention()
        return true
    }

    override func resignFirstResponder() -> Bool {
        surfaceHandle?.setFocus(false)
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            TerminalHostRegistry.shared.clearActiveHost(self)
            isActive = false
            surfaceHandle?.setFocus(false)
            surfaceHandle?.setOcclusion(true)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isActive {
            requestActiveFocus()
        } else {
            applyActiveFocus(requestFirstResponder: false)
        }
        resizeSurface()
    }

    func setActive(_ active: Bool) {
        if active {
            TerminalHostRegistry.shared.setActiveHost(self)
        } else {
            TerminalHostRegistry.shared.clearActiveHost(self)
        }

        guard isActive != active else {
            syncFocusState()
            return
        }

        isActive = active
        if active {
            requestActiveFocus()
        } else {
            applyActiveFocus(requestFirstResponder: false)
        }
        updateRenderLoop()
        if active {
            surfaceHandle?.refresh()
            resizeSurface()
            surfaceHandle?.setOcclusion(false)
            ensureSurfaceFocusedForInput()
            renderFrame()
        }
    }

    func requestUserFocus() {
        if isActive == false {
            setActive(true)
        }

        requestActiveFocus()
        ensureSurfaceFocusedForInput()
        renderFrame()
    }

    private func syncFocusState() {
        guard isActive, let window else {
            return
        }

        surfaceHandle?.setFocus(window.firstResponder === self)
    }

    func ensureSurfaceFocusedForInput() {
        guard isActive else {
            return
        }

        surfaceHandle?.refresh()
        surfaceHandle?.setOcclusion(false)
        surfaceHandle?.setFocus(true)
    }

    var activeHostForForwarding: LibGhosttyTerminalHostView? {
        guard !isActive,
              let activeHost = TerminalHostRegistry.shared.activeHost(),
              activeHost !== self,
              activeHost.isActive
        else {
            return nil
        }

        return activeHost
    }

    func requestActiveFocus() {
        applyActiveFocus(requestFirstResponder: true)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else {
                return
            }

            self.applyActiveFocus(requestFirstResponder: true)
        }

        for delay in [0.05, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isActive else {
                    return
                }

                self.applyActiveFocus(requestFirstResponder: true)
            }
        }
    }

    func applyActiveFocus(requestFirstResponder: Bool) {
        guard let window else {
            return
        }

        if isActive {
            if requestFirstResponder {
                window.makeFirstResponder(self)
            }
            surfaceHandle?.setFocus(window.firstResponder === self)
        } else {
            if window.firstResponder === self {
                window.makeFirstResponder(nil)
            }
        }
    }
}
