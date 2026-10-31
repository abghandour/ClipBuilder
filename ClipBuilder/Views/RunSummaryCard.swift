import SwiftUI

/// What Generate will make: the footage and length as a headline, then the
/// active choices as chips, one row per Settings tab.
struct RunSummaryCard: View {
    let summary: WizardRunSummary
    /// The one-line form, for assistive technology.
    var accessibilityText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.spaceS) {
                Image(systemName: summary.hasFootage ? "film.stack" : "exclamationmark.triangle")
                    .foregroundStyle(summary.hasFootage ? Color.accentColor : Color.orange)
                Text(summary.headline)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if let length = summary.length {
                    Text(length).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
            }
            ForEach(summary.sections, id: \.title) { section in
                // The label is the first item of the flow: chips start right
                // after it and wrap onto the next row, so a narrow column
                // does not pay for an aligned label gutter.
                FlowLayout(spacing: Theme.spaceXS) {
                    SectionLabel(section.title)
                        .padding(.trailing, Theme.spaceXS).padding(.vertical, 3)
                    ForEach(section.items, id: \.self) { item in
                        Text(item)
                            .font(.caption)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 260)
                            .padding(.horizontal, Theme.spaceS).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText ?? summary.headline)
    }
}
