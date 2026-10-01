import AppKit
import BalaganCore

extension LibGhosttyTerminalHostView {
    func startRenderLoop() {
        renderTimer?.invalidate()
        let timer = Timer(timeInterval: renderInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.renderFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    private var renderInterval: TimeInterval {
        isActive ? 1.0 / 60.0 : 1.0 / 12.0
    }

    func updateRenderLoop() {
        guard surfaceHandle != nil else {
            return
        }

        startRenderLoop()
    }

    func renderFrame() {
        appHandle?.tick()
        surfaceHandle?.draw()
        needsDisplay = true
        layer?.setNeedsDisplay()
        detectProcessExitIfNeeded()
        recordVisibleTextIfNeeded()
    }

    private func detectProcessExitIfNeeded() {
        guard processExitDetected == false,
              let surfaceHandle,
              surfaceHandle.processHasExited()
        else {
            return
        }

        processExitDetected = true
        if autoCloseAfterEndedProcessPrompt {
            requestEndedProcessAutoClose()
        }
    }

    func requestRenderFrame() {
        guard surfaceHandle != nil else {
            return
        }
        if Thread.isMainThread {
            renderFrame()
            displayIfNeeded()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.renderFrame()
                self?.displayIfNeeded()
            }
        }
    }

    func resizeSurface() {
        guard let surfaceHandle else {
            return
        }

        // Don't resize to a degenerate size during makeNSView / re-parenting (bounds are 0 before
        // layout). Shrinking the libghostty grid to ~1px and then growing it back leaves the shell's
        // content bottom-anchored with blank rows above — the "weird space" seen on re-entry. Wait
        // for a real laid-out size instead.
        guard bounds.width > 1, bounds.height > 1 else {
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = UInt32(max(1, bounds.width * scale))
        let height = UInt32(max(1, bounds.height * scale))
        surfaceHandle.resize(width: width, height: height)
        requestRenderFrame()
    }
}
