import SwiftUI

/// Folder tabs: a left-aligned row of text tabs where the open tab merges
/// into the panel under it, the way Safari draws its tabs. Only the open
/// tab's content exists, so the panel takes that content's height (`fills`
/// false) or the whole page (`fills` true). Used for the wizard's steps and
/// Settings tabs, the Express / Full switch and the Reports pages.
struct PageTabs<Tab: Hashable, Content: View>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let label: (Tab) -> String
    /// Fill the page below the tab row instead of sizing to the open tab.
    var fills = false
    var rowSpacing: CGFloat = Theme.spaceM
    var padding: CGFloat = Theme.spaceM
    /// The tab and panel share one surface so the open tab reads as part of
    /// it. Tabs that hold other tabs take a different one from theirs.
    var surface = AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
    /// A tab's tooltip, e.g. what the step behind it currently holds.
    var help: ((Tab) -> String)? = nil
    /// A control at the right end of the tab row, level with the tabs.
    var accessory: AnyView? = nil
    @ViewBuilder let content: (Tab) -> Content

    private var panel: AnyShapeStyle { surface }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(tabs, id: \.self) { tab in
                    let open = tab == selection
                    Button { selection = tab } label: {
                        Text(label(tab))
                            .lineLimit(1).fixedSize()
                            .foregroundStyle(open ? .primary : .secondary)
                            .padding(.horizontal, Theme.spaceL)
                            .padding(.vertical, Theme.spaceS - 1)
                            .background(open ? panel : AnyShapeStyle(.clear),
                                        in: UnevenRoundedRectangle(topLeadingRadius: Theme.cardRadius,
                                                                   topTrailingRadius: Theme.cardRadius))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(help?(tab) ?? "")
                    .accessibilityAddTraits(open ? [.isSelected] : [])
                }
                Spacer(minLength: Theme.spaceS)
                if let accessory {
                    accessory.padding(.bottom, Theme.spaceXS)
                }
            }
            .padding(.horizontal, Theme.spaceS)
            Group {
                if fills {
                    content(selection).padding(padding)
                } else {
                    VStack(alignment: .leading, spacing: rowSpacing) { content(selection) }
                        .padding(padding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .background(panel, in: .rect(cornerRadius: Theme.cardRadius))
        }
    }
}
