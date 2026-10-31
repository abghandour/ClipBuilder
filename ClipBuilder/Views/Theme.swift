import SwiftUI

/// Shared design tokens — the one place the spacing rhythm, card chrome,
/// wayfinding tints, and badge typography come from. New surfaces should
/// draw from here instead of minting new literals.
enum Theme {
    // 4-pt base spacing scale.
    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 12
    static let spaceL: CGFloat = 16
    static let spaceXL: CGFloat = 20

    /// Card surfaces (scene cards, library cards): one radius + padding.
    static let cardRadius: CGFloat = 8
    static let cardPadding: CGFloat = 8
    /// Chips and small overlay badges.
    static let chipRadius: CGFloat = 4
    /// Media inside cards (thumbnails, players).
    static let mediaRadius: CGFloat = 6

    /// Sidebar group tints — the app's wayfinding hues (Mail-style).
    static let assetsTint = Color.teal
    static let footageTint = Color.orange
    static let instagramTint = Color.pink
    static let createTint = Color.purple
    static let outputTint = Color.green
    static let projectTint = Color.blue
}

extension SidebarSection {
    var tint: Color {
        switch projectDestination {
        case .sources, .scenes: Theme.footageTint
        case .timelines: Theme.createTint
        case .outputs: Theme.outputTint
        case .people: Theme.footageTint
        case .instagram: Theme.instagramTint
        case .resources: Theme.assetsTint
        case .projects: Theme.projectTint
        default: .secondary
        }
    }
}

extension Font {
    /// Badge text overlaid on media (score, duration, WIDE, speed).
    static let badge = Font.caption2.bold().monospacedDigit()
    /// Compact badge variant for dense list rows and timeline blocks.
    static let badgeCompact = Font.system(size: 9, weight: .bold).monospacedDigit()
}


/// Window title convention: the window is named for the profile ("Clip
/// Builder — Peace Grappler"); the current screen and its status line ride
/// in the subtitle. Profiles switch under Settings › Profile, so the name
/// doubles as the reminder of which brand you are working in.
private struct ScreenTitle: ViewModifier {
    @Environment(\.workspacePageVisible) private var pageVisible
    @Environment(AppStore.self) private var store
    let screen: String
    let subtitle: String

    func body(content: Content) -> some View {
        content.background {
            if pageVisible {
                Color.clear
                    .navigationTitle("Clip Builder — \(store.activeProfile.profileName)")
                    .navigationSubtitle(subtitle.isEmpty ? screen : "\(screen) · \(subtitle)")
            }
        }
    }
}

extension View {
    /// See `ScreenTitle`.
    func screenTitle(_ screen: String, subtitle: String = "") -> some View {
        modifier(ScreenTitle(screen: screen, subtitle: subtitle))
    }
}

private struct AskAIToolbar: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.workspacePageVisible) private var pageVisible
    // A stored property, not an environment value: an existential cannot be
    // compared, so writing it into the environment would invalidate the whole
    // page subtree on every parent pass.
    let assistant: (any PageAssistant)?
    @State private var showing = false
    @State private var outcome: AskAIOutcome?

    func body(content: Content) -> some View {
        content.toolbar {
            if pageVisible, let assistant {
                ToolbarItem(placement: .automatic) {
                    Button("Ask AI", systemImage: "sparkles") { showing = true }
                        .lineLimit(1).fixedSize()
                        .popover(isPresented: $showing) {
                            AskAIPopover(assistant: assistant, outcome: outcome) { text in
                                showing = false
                                outcome = assistant.handle(text, store: store)
                                if case .unavailable(let message) = outcome {
                                    store.presentNotice("Ask AI", message)
                                }
                            }
                        }
                }
            }
        }
    }
}

extension View {
    /// Apply before the page's primary-action toolbar. Nil adds no button.
    func askAI(_ assistant: (any PageAssistant)?) -> some View {
        modifier(AskAIToolbar(assistant: assistant))
    }
}
