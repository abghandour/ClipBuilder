import Foundation
import Testing

@testable import Clip_Builder

@MainActor
struct TextLooksRoutingTests {
    @Test func sidebarOpensMatchingTab() {
        #expect(TextLooksTab.tab(for: .captions) == .captions)
        #expect(TextLooksTab.tab(for: .tags) == .tags)
        #expect(TextLooksTab.tab(for: .overlays) == .overlays)
        #expect(TextLooksTab.tab(for: .fonts) == .fonts)
    }
    @Test func otherDestinationsDoNotOpenStudio() {
        for section in SidebarSection.allCases where ![.captions, .tags, .overlays, .fonts].contains(section) {
            #expect(TextLooksTab.tab(for: section) == nil)
        }
    }
    @Test func textRowRoutesEveryLegacySectionAndRemembersTheTab() {
        for section in [SidebarSection.captions, .tags, .overlays, .fonts, .text] {
            #expect(section.projectDestination == .text)
        }
        #expect(SidebarSection.resourceSections.contains(.text))
        #expect(!SidebarSection.resourceSections.contains(where: { [.captions, .tags, .overlays, .fonts].contains($0) }))
        let defaults = UserDefaults(suiteName: "TextLooksRoutingTests.\(UUID().uuidString)")!
        #expect(TextLooksTab.remembered(defaults: defaults) == .captions)
        TextLooksTab.remember(.named, defaults: defaults)
        #expect(TextLooksTab.remembered(defaults: defaults) == .named)
    }
    @Test func namedStylesAreFourthStudioTab() {
        #expect(TextLooksTab.allCases == [.captions, .tags, .overlays, .named, .fonts])
    }
}
