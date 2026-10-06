import AppKit
import BalaganCore

/// Dropping onto a terminal: files paste as shell-escaped paths (so `claude` / `codex` pick up an
/// image or file), image data without a file is saved under `~/.balagan/drops` first, and links or
/// text paste as they are. Everything goes in as one paste, like ⌘V (`TerminalDrop`, Core).
extension LibGhosttyTerminalHostView {
    static let droppableTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff, .string]

    func registerForDrops() {
        registerForDraggedTypes(Self.droppableTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard surfaceHandle != nil, dropText(from: sender.draggingPasteboard, saving: false) != nil else { return [] }
        setDropHighlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        return acceptDrop(sender.draggingPasteboard)
    }

    /// Types what a drop of `pasteboard` should type. Also the seam for the unlisted
    /// `terminal.drop` control method, since a real drag can't be simulated headlessly.
    @discardableResult
    func acceptDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard let surfaceHandle, let text = dropText(from: pasteboard, saving: true) else { return false }
        surfaceHandle.sendText(text)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        requestRenderFrame()
        return true
    }

    /// What the drop would type; nil when there's nothing usable. `saving` writes image data to a
    /// file (only on the actual drop, not while hovering).
    private func dropText(from pasteboard: NSPasteboard, saving: Bool) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.isEmpty == false {
            return TerminalDrop.pasteText(forPaths: urls.map(\.path))
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            guard saving else { return "" }
            return savedImagePath(data).map { TerminalDrop.pasteText(forPaths: [$0]) }
        }
        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL {
            return url.absoluteString
        }
        if let string = pasteboard.string(forType: .string), string.isEmpty == false {
            return string
        }
        return nil
    }

    /// Writes dropped image data as a PNG under `~/.balagan/drops` and returns its path.
    private func savedImagePath(_ data: Data) -> String? {
        let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        let path = TerminalDrop.dropFile(root: AgentUsageStore.defaultRoot, extension: "png")
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try png.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    private func setDropHighlight(_ on: Bool) {
        layer?.borderColor = on ? NSColor.controlAccentColor.cgColor : nil
        layer?.borderWidth = on ? 2 : 0
    }
}
