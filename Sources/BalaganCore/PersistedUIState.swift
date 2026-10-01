import Foundation

public struct BoardSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var savedAt: Date
    public var boardState: BoardState
    public var uiState: PersistedUIState

    public init(
        schemaVersion: Int = BoardSnapshot.currentSchemaVersion,
        savedAt: Date,
        boardState: BoardState,
        uiState: PersistedUIState = PersistedUIState()
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.boardState = boardState
        self.uiState = uiState
    }
}

public struct PersistedUIState: Codable, Equatable, Sendable {
    public var selectedProjectID: Project.ID?
    public var selectedTaskID: Task.ID?
    public var selectedWorkspaceID: Workspace.ID?
    public var selectedSurfaceID: Surface.ID?
    public var terminalAppearance: TerminalAppearanceSettings
    public var uiAppearance: UIAppearanceSettings
    public var keyboardShortcuts: KeyboardShortcutSettings

    public init(
        selectedProjectID: Project.ID? = nil,
        selectedTaskID: Task.ID? = nil,
        selectedWorkspaceID: Workspace.ID? = nil,
        selectedSurfaceID: Surface.ID? = nil,
        terminalAppearance: TerminalAppearanceSettings = TerminalAppearanceSettings(),
        uiAppearance: UIAppearanceSettings = UIAppearanceSettings(),
        keyboardShortcuts: KeyboardShortcutSettings = KeyboardShortcutSettings()
    ) {
        self.selectedProjectID = selectedProjectID
        self.selectedTaskID = selectedTaskID
        self.selectedWorkspaceID = selectedWorkspaceID
        self.selectedSurfaceID = selectedSurfaceID
        self.terminalAppearance = terminalAppearance
        self.uiAppearance = uiAppearance
        self.keyboardShortcuts = keyboardShortcuts
    }

    private enum CodingKeys: String, CodingKey {
        case selectedProjectID
        case selectedTaskID
        case selectedWorkspaceID
        case selectedSurfaceID
        case terminalAppearance
        case uiAppearance
        case keyboardShortcuts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedProjectID = try container.decodeIfPresent(Project.ID.self, forKey: .selectedProjectID)
        self.selectedTaskID = try container.decodeIfPresent(Task.ID.self, forKey: .selectedTaskID)
        self.selectedWorkspaceID = try container.decodeIfPresent(Workspace.ID.self, forKey: .selectedWorkspaceID)
        self.selectedSurfaceID = try container.decodeIfPresent(Surface.ID.self, forKey: .selectedSurfaceID)
        self.terminalAppearance = try container.decodeIfPresent(
            TerminalAppearanceSettings.self,
            forKey: .terminalAppearance
        ) ?? TerminalAppearanceSettings()
        self.uiAppearance = try container.decodeIfPresent(
            UIAppearanceSettings.self,
            forKey: .uiAppearance
        ) ?? UIAppearanceSettings()
        self.keyboardShortcuts = try container.decodeIfPresent(
            KeyboardShortcutSettings.self,
            forKey: .keyboardShortcuts
        ) ?? KeyboardShortcutSettings()
    }
}

public struct TerminalAppearanceSettings: Codable, Equatable, Sendable {
    public static let defaultFontSize: Float = 13

    public var fontSize: Float

    public init(fontSize: Float = TerminalAppearanceSettings.defaultFontSize) {
        self.fontSize = fontSize
    }
}

/// Reader-mode color theme (the Safari Reader trio). Dark is a *dimmed* dark — body text is a soft
/// off-white, not full white, to avoid halation on long reads.
public enum ReaderTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark
    case sepia
    case light

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .sepia: return "Sepia"
        case .light: return "Light"
        }
    }
}

public struct UIAppearanceSettings: Codable, Equatable, Sendable {
    public static let defaultScale: Double = 1
    public static let minimumScale: Double = 0.8
    public static let maximumScale: Double = 1.4
    public static let scaleStep: Double = 0.05

    public static let defaultReaderFontSize: Double = 15
    public static let minimumReaderFontSize: Double = 11
    public static let maximumReaderFontSize: Double = 24
    public static let readerFontSizeStep: Double = 1

    /// Scale for the main area (kanban board, task header + tabs, terminal chrome).
    public var uiScale: Double
    /// Independent scale for the sidebar. Optional: when unset it falls back to `uiScale`, so existing
    /// boards keep a single unified scale until the sidebar is adjusted on its own.
    public var sidebarScale: Double?
    /// Reader-mode prose size. Optional so older boards decode unchanged.
    public var readerFontSize: Double?
    /// Reader-mode color theme. Optional so older boards decode unchanged.
    public var readerTheme: ReaderTheme?

    public init(
        uiScale: Double = UIAppearanceSettings.defaultScale,
        sidebarScale: Double? = nil,
        readerFontSize: Double? = nil,
        readerTheme: ReaderTheme? = nil
    ) {
        self.uiScale = UIAppearanceSettings.clampedScale(uiScale)
        self.sidebarScale = sidebarScale.map(UIAppearanceSettings.clampedScale)
        self.readerFontSize = readerFontSize.map(UIAppearanceSettings.clampedReaderFontSize)
        self.readerTheme = readerTheme
    }

    /// The sidebar's effective scale (its own value, or `uiScale` when not set independently).
    public var effectiveSidebarScale: Double {
        UIAppearanceSettings.clampedScale(sidebarScale ?? uiScale)
    }

    public var effectiveReaderFontSize: Double {
        UIAppearanceSettings.clampedReaderFontSize(readerFontSize ?? UIAppearanceSettings.defaultReaderFontSize)
    }

    public var effectiveReaderTheme: ReaderTheme {
        readerTheme ?? .dark
    }

    public static func clampedScale(_ scale: Double) -> Double {
        min(max(scale, minimumScale), maximumScale)
    }

    public static func clampedReaderFontSize(_ size: Double) -> Double {
        min(max(size, minimumReaderFontSize), maximumReaderFontSize)
    }
}
