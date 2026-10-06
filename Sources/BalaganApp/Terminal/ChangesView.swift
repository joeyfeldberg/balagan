import AppKit
import SwiftUI
import BalaganCore

/// The Changes pane for the task on screen: loads on appear and whenever the task changes, and reads
/// its state from the view model. Swapped in for the terminal like reader mode — the terminal host
/// keeps running, detached, the way an unselected tab does.
struct ChangesPane: View {
    let task: TaskItem
    @ObservedObject var viewModel: BoardViewModel

    var body: some View {
        let directory = viewModel.taskWorkingDirectory(task)
        ChangesView(
            state: viewModel.taskChanges[task.id],
            isRefreshing: viewModel.taskChangesRefreshing.contains(task.id),
            workingDirectory: directory,
            onRefresh: { viewModel.refreshTaskChanges(taskID: task.id) },
            onDismiss: { viewModel.toggleChangesView() },
            review: DiffReview(
                comments: viewModel.reviewComments(taskID: task.id),
                sendBlocker: viewModel.reviewSendBlocker(taskID: task.id),
                add: { path, line, body in viewModel.addReviewComment(taskID: task.id, path: path, line: line, body: body) },
                update: { id, body in viewModel.updateReviewComment(taskID: task.id, commentID: id, body: body) },
                delete: { id in viewModel.deleteReviewComment(taskID: task.id, commentID: id) },
                send: { viewModel.sendReviewComments(taskID: task.id) },
                discard: { viewModel.discardReviewComments(taskID: task.id) }
            )
        )
        .id(task.id)
        .onAppear { viewModel.refreshTaskChanges(taskID: task.id) }
    }
}

/// Review comments drafted on the diff, and what to do with them (see `BoardReviewComments`).
struct DiffReview {
    var comments: [DiffComment] = []
    /// Why "Send to agent" is unavailable right now, or nil when it can send.
    var sendBlocker: String? = "No comments yet"
    var add: (_ path: String, _ line: DiffLine, _ body: String) -> Void = { _, _, _ in }
    var update: (_ id: DiffComment.ID, _ body: String) -> Void = { _, _ in }
    var delete: (_ id: DiffComment.ID) -> Void = { _ in }
    var send: () -> Void = {}
    var discard: () -> Void = {}

    func comments(in path: String) -> [DiffComment] { comments.filter { $0.path == path } }
}

struct ChangesView: View {
    let state: TaskChangesState?
    let isRefreshing: Bool
    let workingDirectory: String?
    let onRefresh: () -> Void
    let onDismiss: () -> Void
    var review = DiffReview()
    // `BALAGAN_CHANGES_FILE` opens a specific file, for snapshots.
    @State private var selectedPath: String? = ProcessInfo.processInfo.environment["BALAGAN_CHANGES_FILE"]
    @Environment(\.balaganUIScale) private var scale

    private var changes: TaskChanges? {
        if case .loaded(let changes) = state { return changes }
        return nil
    }

    /// The file on the right: the one picked, or the first when the pick is gone (e.g. after a refresh).
    private var selectedFile: DiffFile? {
        guard let files = changes?.files, files.isEmpty == false else { return nil }
        // Default to something with content to read — a deletion or binary is a poor first view.
        return files.first { $0.path == selectedPath }
            ?? files.first { $0.status != .deleted && $0.isBinary == false }
            ?? files[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch state {
                case nil:
                    placeholder(icon: nil, title: "Loading changes…", detail: nil)
                case .failed(let message):
                    placeholder(icon: "exclamationmark.triangle", title: "Couldn't read changes", detail: message)
                case .loaded(let changes) where changes.files.isEmpty:
                    placeholder(
                        icon: "checkmark.circle",
                        title: "No changes yet",
                        detail: changes.baseName.map { "Nothing differs from \($0)." } ?? "Nothing uncommitted."
                    )
                case .loaded(let changes):
                    HStack(spacing: 0) {
                        fileList(changes)
                            .frame(width: 290 * scale)
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                        if let file = selectedFile {
                            DiffFileView(file: file, workingDirectory: workingDirectory, review: review)
                                .id(file.path)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bgWindow)
        .onExitCommand(perform: onDismiss)
        .accessibilityIdentifier("changes-view")
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: "plus.forwardslash.minus")
                .foregroundStyle(Theme.textSecondary)
            Text("Changes")
                .font(.system(size: Theme.TextSize.title * scale, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let changes {
                summary(changes)
            }
            Spacer(minLength: 8 * scale)
            if review.comments.isEmpty == false {
                reviewControls
            }
            if isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
            .help("Reload changes")
            .accessibilityIdentifier("changes-refresh-button")
            // No close button: the header's view switch (and Esc) goes back to the terminal.
        }
        .font(.system(size: Theme.TextSize.body * scale))
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 7 * scale)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// "3 comments · Discard · Send to agent ⌘⏎"
    private var reviewControls: some View {
        HStack(spacing: 8 * scale) {
            Text(review.comments.count == 1 ? "1 comment" : "\(review.comments.count) comments")
                .foregroundStyle(Theme.textSecondary)
            Button("Discard", role: .destructive, action: review.discard)
                .buttonStyle(.borderless)
                .help("Delete all pending comments")
                .accessibilityIdentifier("review-discard-button")
            Button {
                review.send()
            } label: {
                Label("Send to agent", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(review.sendBlocker != nil)
            .help(review.sendBlocker ?? "Paste all comments into the agent as one message and submit it")
            .accessibilityIdentifier("review-send-button")
        }
    }

    /// "vs main · 3 commits · 5 files · 2 uncommitted  +120 −30"
    private func summary(_ changes: TaskChanges) -> some View {
        var parts: [String] = []
        if let base = changes.baseName {
            parts.append("vs \(base)")
            parts.append(changes.commitsAhead == 1 ? "1 commit" : "\(changes.commitsAhead) commits")
        } else {
            parts.append("uncommitted only")
        }
        parts.append(changes.files.count == 1 ? "1 file" : "\(changes.files.count) files")
        if changes.uncommittedCount > 0, changes.baseName != nil {
            parts.append("\(changes.uncommittedCount) uncommitted")
        }
        return HStack(spacing: 8 * scale) {
            Text(parts.joined(separator: " · "))
                .foregroundStyle(Theme.textTertiary)
            ChangeCounts(additions: changes.additions, deletions: changes.deletions, scale: scale)
            if changes.isTruncated {
                Text("truncated")
                    .foregroundStyle(Theme.agentWaiting)
                    .help("The diff was too large to show in full; open the worktree in your editor for the rest.")
            }
        }
        .lineLimit(1)
    }

    // MARK: - File list

    private func fileList(_ changes: TaskChanges) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1 * scale) {
                ForEach(changes.files) { file in
                    ChangedFileRow(
                        file: file,
                        isSelected: file.path == selectedFile?.path,
                        commentCount: review.comments(in: file.path).count,
                        scale: scale
                    ) {
                        selectedPath = file.path
                    }
                    .contextMenu { FileActions(file: file, workingDirectory: workingDirectory).menu }
                }
            }
            .padding(6 * scale)
        }
        .background(Theme.surface)
    }

    private func placeholder(icon: String?, title: String, detail: String?) -> some View {
        VStack(spacing: 8 * scale) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 26 * scale))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ProgressView()
            }
            Text(title)
                .font(.system(size: Theme.TextSize.heading * scale, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            if let detail {
                Text(detail)
                    .font(.system(size: Theme.TextSize.body * scale))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .padding(24 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pieces

private struct ChangeCounts: View {
    let additions: Int
    let deletions: Int
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 5 * scale) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(DiffColors.addedText) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(DiffColors.removedText) }
        }
        .font(.system(size: Theme.TextSize.small * scale, weight: .semibold, design: .monospaced))
    }
}

private enum DiffColors {
    static let addedText = Color(red: 0.36, green: 0.80, blue: 0.48)
    static let removedText = Color(red: 0.93, green: 0.45, blue: 0.43)
    static let addedLine = Color(red: 0.20, green: 0.62, blue: 0.32).opacity(0.16)
    static let removedLine = Color(red: 0.85, green: 0.30, blue: 0.28).opacity(0.16)
    static let addedGutter = Color(red: 0.20, green: 0.62, blue: 0.32).opacity(0.24)
    static let removedGutter = Color(red: 0.85, green: 0.30, blue: 0.28).opacity(0.24)

    static func badge(_ status: DiffFile.Status) -> Color {
        switch status {
        case .added, .untracked: return addedText
        case .deleted: return removedText
        case .modified: return Color(red: 0.90, green: 0.70, blue: 0.30)
        case .renamed: return Color(red: 0.50, green: 0.65, blue: 0.95)
        }
    }
}

private struct ChangedFileRow: View {
    let file: DiffFile
    let isSelected: Bool
    var commentCount = 0
    let scale: CGFloat
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7 * scale) {
            Text(file.status.letter)
                .font(.system(size: Theme.TextSize.micro * scale, weight: .bold, design: .monospaced))
                .foregroundStyle(DiffColors.badge(file.status))
                .frame(width: 12 * scale)
            VStack(alignment: .leading, spacing: 1 * scale) {
                Text(file.fileName)
                    .font(.system(size: Theme.TextSize.body * scale, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Theme.textPrimary)
                    .strikethrough(file.status == .deleted, color: Theme.textTertiary)
                if file.directory.isEmpty == false {
                    Text(file.directory)
                        .font(.system(size: Theme.TextSize.micro * scale))
                        .foregroundStyle(Theme.textTertiary)
                        .truncationMode(.head)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4 * scale)
            if commentCount > 0 {
                Label("\(commentCount)", systemImage: "text.bubble.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: Theme.TextSize.micro * scale, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .help(commentCount == 1 ? "1 comment" : "\(commentCount) comments")
            }
            if file.isUncommitted {
                Circle()
                    .fill(Theme.agentWaiting)
                    .frame(width: 5 * scale, height: 5 * scale)
                    .help("Has uncommitted changes")
            }
            ChangeCounts(additions: file.additions, deletions: file.deletions, scale: scale)
        }
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 5 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.accentSoft : (isHovered ? Theme.surfaceHover : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
        .accessibilityIdentifier("changed-file-\(file.path)")
    }
}

/// Open / reveal / copy for a changed file — the file list's context menu and the diff header.
private struct FileActions {
    let file: DiffFile
    let workingDirectory: String?

    private var fullPath: String? {
        workingDirectory.map { ($0 as NSString).appendingPathComponent(file.path) }
    }

    private var exists: Bool {
        fullPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    func open() {
        guard let fullPath, exists else { return }
        if EditorLauncher.openInZed(path: fullPath) == false {
            NSWorkspace.shared.open(URL(fileURLWithPath: fullPath))
        }
    }

    func reveal() {
        guard let fullPath, exists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullPath)])
    }

    func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
    }

    @ViewBuilder
    var menu: some View {
        Button(EditorLauncher.isZedInstalled ? "Open in Zed" : "Open") { open() }
            .disabled(exists == false)
        Button("Reveal in Finder") { reveal() }
            .disabled(exists == false)
        Divider()
        Button("Copy Path") { copyPath() }
    }
}

// MARK: - Diff

/// One flattened row of a file's diff, so a long diff renders through a single lazy list.
private enum DiffRow: Identifiable {
    case hunk(Int, String)
    case line(Int, DiffLine)

    var id: Int {
        switch self {
        case .hunk(let id, _), .line(let id, _): return id
        }
    }
}

private struct DiffFileView: View {
    let file: DiffFile
    let workingDirectory: String?
    var review = DiffReview()
    @Environment(\.balaganUIScale) private var scale
    /// The line row under the pointer (shows the + to comment).
    @State private var hoveredRow: Int?
    /// The line row with an open "new comment" box.
    @State private var composingRow: Int?
    @State private var draft = ""
    /// The comment being edited in place.
    @State private var editingCommentID: DiffComment.ID?
    @State private var editDraft = ""

    /// Past this many lines the view stops rendering and points at the editor instead.
    private static let lineCap = 5000

    private var rows: (rows: [DiffRow], truncated: Bool) {
        var rows: [DiffRow] = []
        var id = 0
        var lineCount = 0
        for hunk in file.hunks {
            rows.append(.hunk(id, hunk.header)); id += 1
            for line in hunk.lines {
                if lineCount >= Self.lineCap { return (rows, true) }
                rows.append(.line(id, line)); id += 1
                lineCount += 1
            }
        }
        return (rows, false)
    }

    var body: some View {
        let actions = FileActions(file: file, workingDirectory: workingDirectory)
        VStack(spacing: 0) {
            header(actions)
            if file.isBinary {
                note("Binary file — not shown.")
            } else if file.hunks.isEmpty {
                note(file.status == .renamed
                     ? "Renamed from \(file.oldPath ?? "?") with no content changes."
                     : "Empty file.")
            } else {
                let (rows, truncated) = rows
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            switch row {
                            case .hunk(_, let header): hunkHeader(header)
                            case .line(let id, let line): annotatedLine(id: id, line: line)
                            }
                        }
                        if truncated {
                            note("Diff cut off after \(Self.lineCap) lines — open the file to see the rest.")
                        }
                    }
                    .padding(.bottom, 12 * scale)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ actions: FileActions) -> some View {
        HStack(spacing: 8 * scale) {
            Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(.system(size: Theme.TextSize.body * scale, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            if file.isUncommitted {
                Text("uncommitted")
                    .font(.system(size: Theme.TextSize.micro * scale, weight: .semibold))
                    .foregroundStyle(Theme.agentWaiting)
            }
            Spacer(minLength: 8 * scale)
            ChangeCounts(additions: file.additions, deletions: file.deletions, scale: scale)
            if file.status != .deleted {
                Button(EditorLauncher.isZedInstalled ? "Open in Zed" : "Open") { actions.open() }
                    .buttonStyle(.bordered)
                    .font(.system(size: Theme.TextSize.small * scale))
                    .accessibilityIdentifier("changes-open-file-button")
            }
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 7 * scale)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func hunkHeader(_ header: String) -> some View {
        Text(header)
            .font(.system(size: Theme.TextSize.small * scale, design: .monospaced))
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 4 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceRaised.opacity(0.6))
            .padding(.top, 6 * scale)
    }

    /// A diff line, the + to comment on it, its saved comments, and the box for a new one.
    @ViewBuilder
    private func annotatedLine(id: Int, line: DiffLine) -> some View {
        let comments = review.comments(in: file.path).filter { $0.isAnchored(to: line) }
        let canComment = DiffComment.anchor(for: line) != nil
        VStack(alignment: .leading, spacing: 0) {
            lineRow(line)
                .overlay(alignment: .leading) {
                    if canComment, hoveredRow == id || composingRow == id {
                        Button {
                            composingRow = id
                            draft = ""
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10 * scale, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 16 * scale, height: 16 * scale)
                                .background(RoundedRectangle(cornerRadius: 4 * scale).fill(Color.accentColor))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 4 * scale)
                        .help("Comment on this line")
                        .accessibilityIdentifier("diff-comment-add")
                    }
                }
                .onHover { inside in
                    if inside { hoveredRow = id } else if hoveredRow == id { hoveredRow = nil }
                }
            ForEach(comments) { comment in
                commentCard(comment)
            }
            if composingRow == id {
                commentEditor(text: $draft, saveTitle: "Comment", onSave: {
                    review.add(file.path, line, draft)
                    composingRow = nil
                    draft = ""
                }, onCancel: {
                    composingRow = nil
                    draft = ""
                })
            }
        }
    }

    @ViewBuilder
    private func commentCard(_ comment: DiffComment) -> some View {
        if editingCommentID == comment.id {
            commentEditor(text: $editDraft, saveTitle: "Save", onSave: {
                review.update(comment.id, editDraft)
                editingCommentID = nil
            }, onCancel: { editingCommentID = nil })
        } else {
            HStack(alignment: .top, spacing: 8 * scale) {
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(Color.accentColor)
                Text(comment.body)
                    .font(.system(size: Theme.TextSize.body * scale))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Edit") {
                    editDraft = comment.body
                    editingCommentID = comment.id
                }
                .buttonStyle(.borderless)
                Button {
                    review.delete(comment.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete comment")
            }
            .font(.system(size: Theme.TextSize.small * scale))
            .padding(10 * scale)
            .background(RoundedRectangle(cornerRadius: 8 * scale).fill(Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 8 * scale).stroke(Theme.hairline))
            .padding(.vertical, 4 * scale)
            .padding(.leading, 110 * scale)
            .padding(.trailing, 12 * scale)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("diff-comment")
        }
    }

    private func commentEditor(
        text: Binding<String>,
        saveTitle: String,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .trailing, spacing: 8 * scale) {
            TextField("Leave a comment for the agent", text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.TextSize.body * scale))
                .lineLimit(2...8)
                .padding(8 * scale)
                .background(RoundedRectangle(cornerRadius: 6 * scale).fill(Theme.bgWindow))
                .overlay(RoundedRectangle(cornerRadius: 6 * scale).stroke(Color.accentColor.opacity(0.6)))
                .onExitCommand(perform: onCancel)
                .accessibilityIdentifier("diff-comment-field")
            HStack(spacing: 8 * scale) {
                Text("⌘⏎ to save · Esc to cancel")
                    .font(.system(size: Theme.TextSize.micro * scale))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                Button(saveTitle, action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("diff-comment-save")
            }
        }
        .padding(10 * scale)
        .background(RoundedRectangle(cornerRadius: 8 * scale).fill(Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 8 * scale).stroke(Theme.hairline))
        .padding(.vertical, 4 * scale)
        .padding(.leading, 110 * scale)
        .padding(.trailing, 12 * scale)
    }

    private func lineRow(_ line: DiffLine) -> some View {
        let (sign, lineBackground, gutterBackground): (String, Color, Color) = {
            switch line.kind {
            case .added: return ("+", DiffColors.addedLine, DiffColors.addedGutter)
            case .removed: return ("−", DiffColors.removedLine, DiffColors.removedGutter)
            case .context: return (" ", .clear, .clear)
            }
        }()
        return HStack(alignment: .top, spacing: 0) {
            // Tint only the gutter on the side that changed.
            gutter(line.oldNumber)
                .background(line.kind == .removed ? gutterBackground : .clear)
            gutter(line.newNumber)
                .background(line.kind == .added ? gutterBackground : .clear)
            Text(sign)
                .foregroundStyle(line.kind == .added ? DiffColors.addedText : (line.kind == .removed ? DiffColors.removedText : Theme.textTertiary))
                .frame(width: 16 * scale)
            (Text(line.text.isEmpty ? " " : line.text)
                .foregroundColor(line.kind == .context ? Theme.textSecondary : Theme.textPrimary)
             + Text(line.missingNewline ? "  (no newline at end)" : "").foregroundColor(Theme.textTertiary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(size: Theme.TextSize.body * scale, design: .monospaced))
        .padding(.trailing, 12 * scale)
        .background(lineBackground)
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(Theme.textTertiary.opacity(0.8))
            .frame(width: 44 * scale, alignment: .trailing)
            .padding(.trailing, 6 * scale)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.TextSize.body * scale))
            .foregroundStyle(Theme.textTertiary)
            .padding(20 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
