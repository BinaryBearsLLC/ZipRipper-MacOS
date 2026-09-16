import SwiftUI

/// Keeps the open choices in the same logical canvas as the field, so drawing,
/// hit testing and accessibility use the window's scale at both GUI sizes.
struct CanvasChooser<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let choices: [Value]
    let title: (Value) -> String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 10) {
                        Text(title(selection)).font(.system(size: 13, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityValue("\(title(selection)), \(expanded ? "expanded" : "collapsed")")
                .accessibilityHint(expanded ? "Hide choices" : "Show choices")

                if expanded {
                    Divider().overlay(.white.opacity(0.12))
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(choices, id: \.self) { choice in
                                Button {
                                    selection = choice
                                    expanded = false
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .semibold))
                                            .opacity(selection == choice ? 1 : 0)
                                            .accessibilityHidden(true)
                                        Text(title(choice)).font(.system(size: 12))
                                            .lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(.white.opacity(0.95))
                                    .padding(.horizontal, 12).frame(height: 36)
                                    .background(.white.opacity(selection == choice ? 0.09 : 0))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(title(choice))
                                .accessibilityAddTraits(selection == choice ? .isSelected : [])
                            }
                        }
                    }
                    .frame(height: min(CGFloat(choices.count) * 36, 180))
                }
            }
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.25)))
        }
    }
}
