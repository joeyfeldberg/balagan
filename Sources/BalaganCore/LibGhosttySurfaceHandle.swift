import CGhosttyShim
import Foundation

public enum LibGhosttyMouseState {
    case press
    case release
}

public enum LibGhosttyMouseButton {
    case left
    case right
    case middle
    case unknown
}

/// Per-surface event sink. Held by its `LibGhosttySurfaceHandle` and handed to libghostty
/// as the surface `userdata`, so the C action callback can route title/pwd changes back here.
final class LibGhosttySurfaceContext: @unchecked Sendable {
    var onTitle: ((String) -> Void)?
    var onWorkingDirectory: ((String) -> Void)?
    var onNotification: ((String?, String?) -> Void)?
    var onBell: (() -> Void)?
    var onSearch: ((LibGhosttySearchEvent) -> Void)?
}

/// Scrollback-search progress reported by libghostty (1.3): a search started (with its needle, which
/// may be empty — e.g. from a keybinding), ended, or a new match count / selected match index.
public enum LibGhosttySearchEvent: Equatable, Sendable {
    case started(needle: String)
    case ended
    case total(Int?)
    case selected(Int?)
}

private func libghosttySurfaceEventTrampoline(
    _ context: UnsafeMutableRawPointer?,
    _ kind: balagan_ghostty_event_kind_t,
    _ text: UnsafePointer<CChar>?,
    _ detail: UnsafePointer<CChar>?
) {
    guard let context else {
        return
    }
    let surfaceContext = Unmanaged<LibGhosttySurfaceContext>.fromOpaque(context).takeUnretainedValue()
    let textValue = text.map { String(cString: $0) }
    let detailValue = detail.map { String(cString: $0) }
    DispatchQueue.main.async {
        if kind == BALAGAN_GHOSTTY_EVENT_TITLE {
            if let textValue {
                surfaceContext.onTitle?(textValue)
            }
        } else if kind == BALAGAN_GHOSTTY_EVENT_PWD {
            if let textValue {
                surfaceContext.onWorkingDirectory?(textValue)
            }
        } else if kind == BALAGAN_GHOSTTY_EVENT_NOTIFICATION {
            surfaceContext.onNotification?(textValue, detailValue)
        } else if kind == BALAGAN_GHOSTTY_EVENT_BELL {
            surfaceContext.onBell?()
        } else if kind == BALAGAN_GHOSTTY_EVENT_SEARCH_START {
            surfaceContext.onSearch?(.started(needle: textValue ?? ""))
        } else if kind == BALAGAN_GHOSTTY_EVENT_SEARCH_END {
            surfaceContext.onSearch?(.ended)
        } else if kind == BALAGAN_GHOSTTY_EVENT_SEARCH_TOTAL {
            surfaceContext.onSearch?(.total(textValue.flatMap(Int.init).flatMap { $0 < 0 ? nil : $0 }))
        } else if kind == BALAGAN_GHOSTTY_EVENT_SEARCH_SELECTED {
            surfaceContext.onSearch?(.selected(textValue.flatMap(Int.init).flatMap { $0 < 0 ? nil : $0 }))
        }
    }
}

enum LibGhosttyEventBridge {
    static let install: Void = {
        balagan_ghostty_set_event_callback(libghosttySurfaceEventTrampoline)
    }()
}

public final class LibGhosttySurfaceHandle: @unchecked Sendable {
    private let surface: OpaquePointer
    private let context: LibGhosttySurfaceContext

    init(surface: OpaquePointer, context: LibGhosttySurfaceContext) {
        self.surface = surface
        self.context = context
    }

    public var onTitleChanged: ((String) -> Void)? {
        get { context.onTitle }
        set { context.onTitle = newValue }
    }

    public var onWorkingDirectoryChanged: ((String) -> Void)? {
        get { context.onWorkingDirectory }
        set { context.onWorkingDirectory = newValue }
    }

    public var onDesktopNotification: ((String?, String?) -> Void)? {
        get { context.onNotification }
        set { context.onNotification = newValue }
    }

    public var onBell: (() -> Void)? {
        get { context.onBell }
        set { context.onBell = newValue }
    }

    public var onSearch: ((LibGhosttySearchEvent) -> Void)? {
        get { context.onSearch }
        set { context.onSearch = newValue }
    }

    deinit {
        balagan_ghostty_surface_free(surface)
    }

    public func draw() {
        balagan_ghostty_surface_draw(surface)
    }

    public func refresh() {
        balagan_ghostty_surface_refresh(surface)
    }

    public func resize(width: UInt32, height: UInt32) {
        balagan_ghostty_surface_resize(surface, width, height)
    }

    public func setFocus(_ focused: Bool) {
        balagan_ghostty_surface_set_focus(surface, focused)
    }

    public func setOcclusion(_ occluded: Bool) {
        balagan_ghostty_surface_set_occlusion(surface, occluded)
    }

    @discardableResult
    public func performBindingAction(_ action: String) -> Bool {
        action.withCString { pointer in
            balagan_ghostty_surface_binding_action(surface, pointer, UInt(strlen(pointer)))
        }
    }

    public func size() -> LibGhosttySurfaceSize? {
        var columns: UInt16 = 0
        var rows: UInt16 = 0
        var widthPx: UInt32 = 0
        var heightPx: UInt32 = 0
        var cellWidthPx: UInt32 = 0
        var cellHeightPx: UInt32 = 0
        guard balagan_ghostty_surface_size(
            surface,
            &columns,
            &rows,
            &widthPx,
            &heightPx,
            &cellWidthPx,
            &cellHeightPx
        ) else {
            return nil
        }
        return LibGhosttySurfaceSize(
            columns: columns,
            rows: rows,
            widthPx: widthPx,
            heightPx: heightPx,
            cellWidthPx: cellWidthPx,
            cellHeightPx: cellHeightPx
        )
    }

    @discardableResult
    public func sendEnterKey() -> Bool {
        balagan_ghostty_surface_key(surface, BALAGAN_GHOSTTY_KEY_ENTER)
    }

    /// Sends Enter carrying modifier flags (bit0 shift, …) so Shift+Enter is reported distinctly —
    /// apps using the kitty keyboard protocol (e.g. Claude Code) map it to a newline instead of submit.
    @discardableResult
    public func sendEnterKey(mods: UInt32) -> Bool {
        balagan_ghostty_surface_key_with_mods(surface, BALAGAN_GHOSTTY_KEY_ENTER, mods)
    }

    @discardableResult
    public func sendBackspaceKey() -> Bool {
        balagan_ghostty_surface_key(surface, BALAGAN_GHOSTTY_KEY_BACKSPACE)
    }

    @discardableResult
    public func sendTabKey() -> Bool {
        balagan_ghostty_surface_key(surface, BALAGAN_GHOSTTY_KEY_TAB)
    }

    @discardableResult
    public func sendEscapeKey() -> Bool {
        balagan_ghostty_surface_key(surface, BALAGAN_GHOSTTY_KEY_ESCAPE)
    }

    @discardableResult
    public func sendArrowUpKey() -> Bool {
        balagan_ghostty_surface_key(surface, BALAGAN_GHOSTTY_KEY_ARROW_UP)
    }

    @discardableResult
    public func sendArrowDownKey() -> Bool {
        balagan_ghostty_surface_key(surface, BALAGAN_GHOSTTY_KEY_ARROW_DOWN)
    }

    @discardableResult
    public func sendArrowLeftKey() -> Bool {
        balagan_ghostty_surface_key(surface, BALAGAN_GHOSTTY_KEY_ARROW_LEFT)
    }

    @discardableResult
    public func sendArrowRightKey() -> Bool {
        balagan_ghostty_surface_key(surface, BALAGAN_GHOSTTY_KEY_ARROW_RIGHT)
    }

    @discardableResult
    public func sendDeleteKey() -> Bool {
        balagan_ghostty_surface_key(surface, BALAGAN_GHOSTTY_KEY_DELETE)
    }

    @discardableResult
    public func sendHomeKey() -> Bool {
        balagan_ghostty_surface_key(surface, BALAGAN_GHOSTTY_KEY_HOME)
    }

    @discardableResult
    public func sendEndKey() -> Bool {
        balagan_ghostty_surface_key(surface, BALAGAN_GHOSTTY_KEY_END)
    }

    public func sendText(_ text: String) {
        text.withCString { pointer in
            balagan_ghostty_surface_text(surface, pointer, UInt(strlen(pointer)))
        }
    }

    public func sendMouseButton(_ state: LibGhosttyMouseState, button: LibGhosttyMouseButton, mods: UInt32) {
        let ghosttyState: balagan_ghostty_mouse_state_t = state == .press
            ? BALAGAN_GHOSTTY_MOUSE_PRESS
            : BALAGAN_GHOSTTY_MOUSE_RELEASE
        let ghosttyButton: balagan_ghostty_mouse_button_t
        switch button {
        case .left:
            ghosttyButton = BALAGAN_GHOSTTY_MOUSE_BUTTON_LEFT
        case .right:
            ghosttyButton = BALAGAN_GHOSTTY_MOUSE_BUTTON_RIGHT
        case .middle:
            ghosttyButton = BALAGAN_GHOSTTY_MOUSE_BUTTON_MIDDLE
        case .unknown:
            ghosttyButton = BALAGAN_GHOSTTY_MOUSE_BUTTON_UNKNOWN
        }
        balagan_ghostty_surface_mouse_button(surface, ghosttyState, ghosttyButton, mods)
    }

    public func sendMousePos(x: Double, y: Double, mods: UInt32) {
        balagan_ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    public func sendMouseScroll(deltaX: Double, deltaY: Double, mods: Int32) {
        balagan_ghostty_surface_mouse_scroll(surface, deltaX, deltaY, mods)
    }

    public func hasSelection() -> Bool {
        balagan_ghostty_surface_has_selection(surface)
    }

    public func processHasExited() -> Bool {
        balagan_ghostty_surface_process_exited(surface)
    }

    /// Whether something other than the shell prompt is running (Ghostty's close-confirm check).
    public func needsConfirmQuit() -> Bool {
        balagan_ghostty_surface_needs_confirm_quit(surface)
    }

    public func readSelection() -> String? {
        guard hasSelection() else {
            return nil
        }

        var textPointer: UnsafeMutablePointer<CChar>?
        var textLength = 0
        var error = ErrorBuffer()
        let result = error.withMutableCString { errorPointer, errorLength in
            balagan_ghostty_surface_read_selection(surface, &textPointer, &textLength, errorPointer, errorLength)
        }
        guard result == 0, let textPointer else {
            return nil
        }
        defer {
            balagan_ghostty_string_free(textPointer)
        }

        let buffer = UnsafeRawBufferPointer(start: textPointer, count: textLength)
        return String(decoding: buffer, as: UTF8.self)
    }

    public func readVisibleText() throws -> String {
        var textPointer: UnsafeMutablePointer<CChar>?
        var textLength = 0
        var error = ErrorBuffer()
        let result = error.withMutableCString { errorPointer, errorLength in
            balagan_ghostty_surface_read_text(surface, &textPointer, &textLength, errorPointer, errorLength)
        }
        guard result == 0, let textPointer else {
            throw LibGhosttyDynamicLibraryError.textReadFailed(error.message)
        }
        defer {
            balagan_ghostty_string_free(textPointer)
        }

        let buffer = UnsafeRawBufferPointer(start: textPointer, count: textLength)
        return String(decoding: buffer, as: UTF8.self)
    }

    @discardableResult
    public func sendKey(keyCode: UInt32, text: String, unshiftedText: String?) -> Bool {
        let unshiftedCodepoint = unshiftedText?.unicodeScalars.first?.value ?? text.unicodeScalars.first?.value ?? 0
        return text.withCString { pointer in
            balagan_ghostty_surface_key_text(surface, keyCode, pointer, unshiftedCodepoint)
        }
    }

    @discardableResult
    public func sendControlKey(keyCode: UInt32, text: String) -> Bool {
        let unshiftedCodepoint = text.unicodeScalars.first?.value ?? 0
        return text.withCString { pointer in
            balagan_ghostty_surface_control_key_text(surface, keyCode, pointer, unshiftedCodepoint)
        }
    }

    /// Full key-event entry point for the unified input pipeline: forwards keycode + modifiers +
    /// consumed mods + unshifted codepoint + composing state + optional text to libghostty, which
    /// encodes it (legacy or kitty keyboard protocol). Returns whether libghostty consumed it.
    @discardableResult
    public func sendKeyEvent(
        keyCode: UInt32,
        mods: UInt32,
        consumedMods: UInt32,
        action: LibGhosttyKeyAction,
        unshiftedCodepoint: UInt32,
        composing: Bool,
        text: String?
    ) -> Bool {
        func call(_ pointer: UnsafePointer<CChar>?) -> Bool {
            balagan_ghostty_surface_send_key(
                surface, keyCode, mods, consumedMods, action.rawAction, unshiftedCodepoint, composing, pointer
            )
        }
        if let text, text.isEmpty == false {
            return text.withCString { call($0) }
        }
        return call(nil)
    }

    /// Applies the user's Ghostty keyboard config (e.g. macos-option-as-alt) to a modifier set.
    public func keyTranslationMods(_ mods: UInt32) -> UInt32 {
        balagan_ghostty_surface_key_translation_mods(surface, mods)
    }

    /// Sets (text != nil) or clears (nil) the IME preedit overlay libghostty renders for composition.
    public func setPreedit(_ text: String?) {
        if let text, text.isEmpty == false {
            text.withCString { pointer in
                balagan_ghostty_surface_preedit(surface, pointer, UInt(strlen(pointer)))
            }
        } else {
            balagan_ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// The cursor rect (terminal coordinates) for placing the IME candidate window, if available.
    public func imePoint() -> (x: Double, y: Double, width: Double, height: Double)? {
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        guard balagan_ghostty_surface_ime_point(surface, &x, &y, &width, &height) else {
            return nil
        }
        return (x, y, width, height)
    }
}

/// Key event lifecycle, matching libghostty's `ghostty_input_action_e` ordering.
public enum LibGhosttyKeyAction {
    case release
    case press
    case repeatKey

    var rawAction: Int32 {
        switch self {
        case .release: return 0
        case .press: return 1
        case .repeatKey: return 2
        }
    }
}

public struct LibGhosttySurfaceSize: Equatable {
    public var columns: UInt16
    public var rows: UInt16
    public var widthPx: UInt32
    public var heightPx: UInt32
    public var cellWidthPx: UInt32
    public var cellHeightPx: UInt32
}
