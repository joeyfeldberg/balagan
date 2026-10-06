import AppKit
import BalaganCore
import Combine

/// A menu bar item showing how many agents need you, so you notice with Balagan in the background.
/// The count and its tint follow the same queue as ⌘J (waiting oldest-first, then finished); the
/// menu lists who's waiting, finished and running, and picking one brings Balagan forward on it.
@MainActor
final class MenuBarStatus: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private weak var viewModel: BoardViewModel?
    private var cancellable: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private let onOpen: (TaskItem.ID?, Surface.ID?) -> Void

    init(viewModel: BoardViewModel, onOpen: @escaping (TaskItem.ID?, Surface.ID?) -> Void) {
        self.viewModel = viewModel
        self.onOpen = onOpen
        super.init()
        // The view model publishes on every change; the item only needs the latest picture.
        cancellable = viewModel.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVisibility() }
        }
        applyVisibility()
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPreferences.Keys.menuBarItem) as? Bool ?? true
    }

    private func applyVisibility() {
        if Self.isEnabled, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.imagePosition = .imageLeading
            item.button?.setAccessibilityIdentifier("balagan-menu-bar-item")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            refresh()
        } else if Self.isEnabled == false, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func refresh() {
        guard let button = item?.button, let viewModel else { return }
        let entries = viewModel.attentionQueueEntries()
        let waiting = entries.filter { $0.reason == .waiting }.count
        let image = NSImage(systemSymbolName: waiting > 0 ? "questionmark.square.fill" : "terminal", accessibilityDescription: "Balagan")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = waiting > 0 ? .systemOrange : nil
        button.title = entries.isEmpty ? "" : " \(entries.count)"
        button.toolTip = entries.isEmpty
            ? "Balagan: no agent needs you"
            : "Balagan: \(entries.count == 1 ? "1 agent needs" : "\(entries.count) agents need") you"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let viewModel else { return }
        let now = Date()
        let queue = AgentAttentionQueue.ordered(viewModel.attentionQueueEntries())
        let waiting = queue.filter { $0.reason == .waiting }
        let finished = queue.filter { $0.reason == .finished }
        let running = viewModel.runningAgentSurfaces()

        func section(_ title: String, _ rows: [(taskID: TaskItem.ID, surfaceID: Surface.ID, since: Date?)]) {
            guard rows.isEmpty == false else { return }
            if menu.items.isEmpty == false { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: title))
            for row in rows {
                guard let task = viewModel.tasks.first(where: { $0.id == row.taskID }) else { continue }
                let tab = task.workspace.surfaces.first { $0.id == row.surfaceID }
                var label = task.title
                if task.workspace.surfaces.count > 1, let tab { label += " · \(tab.title)" }
                if let since = row.since { label += " · \(SidebarUsageMeter.agoPhrase(since, now: now).replacingOccurrences(of: " ago", with: ""))" }
                let item = NSMenuItem(title: label, action: #selector(openEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [row.taskID, row.surfaceID]
                item.toolTip = viewModel.projectName(for: task.projectID)
                menu.addItem(item)
            }
        }

        section("Waiting for you", waiting.map { ($0.taskID, $0.surfaceID, $0.since) })
        section("Finished", finished.map { ($0.taskID, $0.surfaceID, $0.since) })
        section("Running", running)
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No agents running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Balagan", action: #selector(openApp(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    @objc private func openEntry(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String], ids.count == 2 else { return }
        onOpen(ids[0], ids[1])
    }

    @objc private func openApp(_ sender: NSMenuItem) {
        onOpen(nil, nil)
    }
}

extension BoardViewModel {
    /// Agent tabs that are working right now, longest-running first (the menu bar's "Running").
    func runningAgentSurfaces() -> [(taskID: TaskItem.ID, surfaceID: Surface.ID, since: Date?)] {
        var rows: [(taskID: TaskItem.ID, surfaceID: Surface.ID, since: Date?)] = []
        for task in tasks where task.isArchived == false && hibernatedTaskIDs.contains(task.id) == false {
            for surface in task.workspace.surfaces where surfaceLifecycle[hostKey(task.id, surface.id)] == .running {
                rows.append((task.id, surface.id, surfaceLifecycleSince[hostKey(task.id, surface.id)]))
            }
        }
        return rows.sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }
}
