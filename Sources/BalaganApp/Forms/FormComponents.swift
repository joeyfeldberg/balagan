import SwiftUI

/// Top-aligned label + content row, shared by the task and project forms.
struct FormFieldGroup<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            content
        }
    }
}

/// Shared dark field appearance: raised fill, hairline border, accent focus ring.
struct FormFieldChrome: ViewModifier {
    var focused: Bool
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                    .fill(Theme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                    .stroke(focused ? Color.accentColor : Theme.hairline, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(focused ? 0.3 : 0), lineWidth: 3)
            )
    }
}

extension View {
    func formFieldChrome(focused: Bool) -> some View {
        modifier(FormFieldChrome(focused: focused))
    }
}

/// A themed segmented control whose selected segment carries the value's color (status / priority).
struct ColoredSegmentedPicker<Value>: View where Value: Hashable & Identifiable {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let color: (Value) -> Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(values) { value in
                let isSelected = value == selection
                Button {
                    selection = value
                } label: {
                    Text(title(value))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
                                .fill(isSelected ? color(value).opacity(0.20) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
                                .stroke(isSelected ? color(value).opacity(0.6) : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Set to \(title(value))")
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }
}
