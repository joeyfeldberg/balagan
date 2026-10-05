import AppKit
import BalaganCore

/// Scrollback search for one terminal pane: ⌘F opens `TerminalSearchBar` over the pane and drives
/// libghostty's search through binding actions; libghostty reports counts back as search events.
extension LibGhosttyTerminalHostView {
    /// Opens the find bar (or refocuses it). `needle` pre-fills it when libghostty started the search.
    func startSearch(needle: String? = nil) {
        guard surfaceHandle != nil else { return }
        let bar = searchBar ?? makeSearchBar()
        if let needle, needle.isEmpty == false, needle != bar.query {
            bar.query = needle
            sendSearch(needle)
        }
        bar.focusField()
    }

    /// Closes the find bar and clears the highlights, handing focus back to the terminal.
    func endSearch() {
        guard let bar = searchBar else { return }
        searchQueryWork?.cancel()
        _ = surfaceHandle?.performBindingAction("end_search")
        bar.removeFromSuperview()
        searchBar = nil
        searchSelected = nil
        searchTotal = nil
        window?.makeFirstResponder(self)
    }

    func handleSearchEvent(_ event: LibGhosttySearchEvent) {
        switch event {
        case .started(let needle):
            startSearch(needle: needle)
        case .ended:
            // Ended inside libghostty (e.g. its own keybinding): just drop our bar.
            searchBar?.removeFromSuperview()
            searchBar = nil
            searchSelected = nil
            searchTotal = nil
        case .total(let total):
            searchTotal = total
            searchBar?.showCount(selected: searchSelected, total: total)
        case .selected(let selected):
            searchSelected = selected
            searchBar?.showCount(selected: selected, total: searchTotal)
        }
    }

    /// Keeps the bar pinned top-right when the pane resizes.
    func layoutSearchBar() {
        guard let bar = searchBar else { return }
        let size = TerminalSearchBar.size
        let width = min(size.width, max(160, bounds.width - 16))
        bar.frame = NSRect(x: bounds.maxX - width - 8, y: bounds.maxY - size.height - 8, width: width, height: size.height)
    }

    private func makeSearchBar() -> TerminalSearchBar {
        let bar = TerminalSearchBar(frame: .zero)
        bar.onQueryChanged = { [weak self] query in self?.scheduleSearch(query) }
        bar.onNext = { [weak self] in _ = self?.surfaceHandle?.performBindingAction("navigate_search:next") }
        bar.onPrevious = { [weak self] in _ = self?.surfaceHandle?.performBindingAction("navigate_search:previous") }
        bar.onClose = { [weak self] in self?.endSearch() }
        addSubview(bar)
        searchBar = bar
        layoutSearchBar()
        return bar
    }

    /// Debounced a little, like Ghostty's own overlay, so each keystroke doesn't restart a search
    /// over a long scrollback.
    private func scheduleSearch(_ query: String) {
        searchQueryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendSearch(query) }
        searchQueryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (query.count < 3 ? 0.25 : 0.08), execute: work)
    }

    private func sendSearch(_ query: String) {
        if query.isEmpty {
            searchSelected = nil
            searchTotal = nil
            searchBar?.showCount(selected: nil, total: nil)
        }
        _ = surfaceHandle?.performBindingAction("search:\(query)")
    }
}
