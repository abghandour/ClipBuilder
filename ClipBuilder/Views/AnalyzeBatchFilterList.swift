import SwiftUI

/// The expanded analyze-batch selector shared by the Builder's scene browser
/// and the Curated Scenes list: a name-filterable list (5 rows tall) instead
/// of a popup, so batches are scannable at a glance.
struct AnalyzeBatchFilterList: View {
    /// One selectable row: the analyze run's id, display name, and how many
    /// of the surrounding view's scenes it holds.
    struct Batch: Identifiable {
        var id: Int64
        var name: String
        var count: Int
    }

    let batches: [Batch]
    @Binding var selection: Int64?

    @State private var search = ""

    /// Batches matching the batch-name search (partial, case-insensitive).
    private var matchingBatches: [Batch] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return batches }
        return batches.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 4) {
            TextField("Filter analyze batches", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            ScrollView {
                VStack(spacing: 1) {
                    batchRow(name: "All Analyze Batches", count: nil, id: nil)
                    ForEach(matchingBatches) { batch in
                        batchRow(name: batch.name, count: batch.count, id: batch.id)
                    }
                    if matchingBatches.isEmpty {
                        Text("No analyze batches match")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
            }
            // 5 rows of 22pt + spacing stay visible; the rest scrolls.
            .frame(height: 116)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func batchRow(name: String, count: Int?, id: Int64?) -> some View {
        let selected = selection == id
        return Button {
            selection = id
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85))
                                                  : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                }
            }
            .font(.callout)
            // Full accent + white, matching sidebar selection — the old 30%
            // tint was barely distinguishable from an unselected row.
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(Color.accentColor)
                                 : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(id == nil ? "Show scenes from every analyze batch" : name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
