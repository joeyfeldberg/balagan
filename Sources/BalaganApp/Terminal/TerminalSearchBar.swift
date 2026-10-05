import AppKit

/// The find bar pinned to a terminal pane's top-right corner (⌘F). It only collects the query and
/// shows the count; libghostty (1.3) does the matching, highlighting and scrolling. Mirrors Ghostty's
/// own overlay: ⏎ = next match, ⇧⏎ = previous, Esc = close.
final class TerminalSearchBar: NSView, NSTextFieldDelegate {
    var onQueryChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")

    static let size = NSSize(width: 320, height: 34)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 0.97).cgColor
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        layer?.borderWidth = 1
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()
        setAccessibilityIdentifier("terminal-search-bar")

        field.placeholderString = "Find"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = .white
        field.delegate = self
        field.setAccessibilityIdentifier("terminal-search-field")

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.5)
        countLabel.alignment = .right
        countLabel.setAccessibilityIdentifier("terminal-search-count")

        let next = Self.button("chevron.up", "Next match (⏎)", #selector(nextClicked))
        let previous = Self.button("chevron.down", "Previous match (⇧⏎)", #selector(previousClicked))
        let close = Self.button("xmark", "Close (Esc)", #selector(closeClicked))
        for button in [next, previous, close] { button.target = self }

        let stack = NSStackView(views: [field, countLabel, next, previous, close])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: action)
        button.isBordered = false
        button.contentTintColor = NSColor(calibratedWhite: 1, alpha: 0.7)
        button.toolTip = tip
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// libghostty's counts: `selected` is 0-based; either may be unknown while a search runs.
    func showCount(selected: Int?, total: Int?) {
        switch (selected, total) {
        case (_, 0?) where query.isEmpty == false: countLabel.stringValue = "0/0"
        case let (selected?, total): countLabel.stringValue = "\(selected + 1)/\(total.map(String.init) ?? "?")"
        case let (nil, total?): countLabel.stringValue = "-/\(total)"
        default: countLabel.stringValue = ""
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChanged?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    // A click on the bar's own background stays here instead of falling through to the terminal.
    override func mouseDown(with event: NSEvent) { focusField() }

    @objc private func nextClicked() { onNext?() }
    @objc private func previousClicked() { onPrevious?() }
    @objc private func closeClicked() { onClose?() }
}
