import SwiftUI
import BalaganCore

/// The Archived view: tasks hidden from the board, each with a restore / delete-now affordance and a
/// countdown to auto-deletion.
struct ArchivedTasksScreen: View {
    @ObservedObject var viewModel: BoardViewModel
    var isSidebarHidden = false
    var onToggleSidebar: () -> Void = {}
    let onDeleteTask: (TaskItem) -> Void
    @Environment(\.balaganUIScale) private var balaganUIScale

    private var archived: [TaskItem] { viewModel.archivedTasks }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10 * balaganUIScale) {
                if isSidebarHidden {
                    Button(action: onToggleSidebar) {
                        Image(systemName: "sidebar.leading")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textSecondary)
                    .help("Show sidebar")
                }
                Image(systemName: "archivebox")
                    .foregroundStyle(Theme.textSecondary)
                Text("Archived")
                    .font(.system(size: 15 * balaganUIScale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if archived.isEmpty == false {
                    Text("\(archived.count)")
                        .font(.system(size: 12 * balaganUIScale))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Text("Auto-deleted after \(BoardViewModel.archivedTaskRetentionDays) days")
                    .font(.system(size: 11.5 * balaganUIScale))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14 * balaganUIScale)
            .padding(.vertical, 10 * balaganUIScale)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            if archived.isEmpty {
                VStack(spacing: 8 * balaganUIScale) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 32 * balaganUIScale))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No archived tasks")
                        .font(.system(size: 14 * balaganUIScale, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Archive a task to hide it from the board.\nArchived tasks are deleted after \(BoardViewModel.archivedTaskRetentionDays) days.")
                        .font(.system(size: 12 * balaganUIScale))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8 * balaganUIScale) {
                        ForEach(archived) { task in
                            archivedRow(task)
                        }
                    }
                    .padding(16 * balaganUIScale)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgWindow)
    }

    @ViewBuilder
    private func archivedRow(_ task: TaskItem) -> some View {
        let days = viewModel.daysUntilAutoDelete(task) ?? BoardViewModel.archivedTaskRetentionDays
        HStack(spacing: 12 * balaganUIScale) {
            VStack(alignment: .leading, spacing: 3 * balaganUIScale) {
                Text(task.title)
                    .font(.system(size: 13.5 * balaganUIScale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6 * balaganUIScale) {
                    Text(viewModel.projectName(for: task.projectID))
                        .foregroundStyle(Theme.textSecondary)
                    Text("·").foregroundStyle(Theme.textTertiary)
                    Text(autoDeleteLabel(days: days))
                        .foregroundStyle(days <= 3 ? TaskStatus.parked.color : Theme.textTertiary)
                }
                .font(.system(size: 11.5 * balaganUIScale))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Restore") {
                viewModel.unarchiveTask(id: task.id)
            }
            .buttonStyle(.bordered)
            .font(.system(size: 12 * balaganUIScale))
            .accessibilityIdentifier("archived-restore-\(task.id)")

            Button {
                onDeleteTask(task)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .font(.system(size: 12 * balaganUIScale))
            .help("Delete now")
            .accessibilityIdentifier("archived-delete-\(task.id)")
        }
        .padding(.horizontal, 14 * balaganUIScale)
        .padding(.vertical, 10 * balaganUIScale)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.hairline, lineWidth: 1)
        )
    }

    private func autoDeleteLabel(days: Int) -> String {
        if days <= 0 { return "auto-deletes soon" }
        if days == 1 { return "auto-deletes tomorrow" }
        return "auto-deletes in \(days) days"
    }
}
