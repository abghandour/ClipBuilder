import AppKit
import Foundation
import Testing
@testable import Clip_Builder

struct TextStyleClipboardTests {
    private var source: TextDecor {
        TextDecor(color: "#ff0000", weight: "black", size: 1.4, strokeOn: true, strokeWidth: 3,
                  shadowOn: true, shadowStyle: "extrude", bgOn: true, bgColor: "#00ff00",
                  alignment: "leading", maxWidthFrac: 0.5)
    }

    @Test func copyCapturesTheResolvedLookWithoutPlacement() {
        let payload = TextStyleClipboard.payload(stored: source, inherited: .defaults, fontFamily: "Georgia",
                                                 sharedStyleID: nil, source: "overlay")
        #expect(payload.look.color == "#ff0000" && payload.look.shadowStyle == "extrude")
        #expect(payload.look.strokeColor == "#000000", "inherited values are filled in")
        #expect(payload.look.alignment == nil && payload.look.maxWidthFrac == nil)
        #expect(payload.overrides == nil && payload.fontFamily == "Georgia")
    }

    @Test func fullPasteReplacesEveryGroupAndKeepsPlacement() {
        let payload = TextStyleClipboard.payload(stored: source, inherited: .defaults, fontFamily: "Georgia",
                                                 sharedStyleID: nil, source: "overlay")
        let target = TextDecor(color: "#0000ff", alignment: "trailing", maxWidthFrac: 0.9)
        let pasted = TextStyleClipboard.pasted(payload, onto: target, linkShared: true)
        #expect(pasted.decor.color == "#ff0000" && pasted.decor.bgColor == "#00ff00" && pasted.decor.weight == "black")
        #expect(pasted.decor.alignment == "trailing" && pasted.decor.maxWidthFrac == 0.9)
        #expect(pasted.sharedStyleID == nil && pasted.fontFamily == "Georgia")
    }

    @Test func partialPasteTouchesOnlyTheChosenGroup() {
        let payload = TextStyleClipboard.payload(stored: source, inherited: .defaults, fontFamily: "Georgia",
                                                 sharedStyleID: nil, source: "overlay")
        let target = TextDecor(color: "#0000ff", shadowOn: false)
        let pasted = TextStyleClipboard.pasted(payload, onto: target, groups: [.shadow], linkShared: true)
        #expect(pasted.decor.color == "#0000ff", "fill untouched")
        #expect(pasted.decor.shadowOn == true && pasted.decor.shadowStyle == "extrude")
        #expect(pasted.fontFamily == nil, "font belongs to typography")
    }

    @Test func linkedSourcePastesTheLinkPlusOverridesWhereLinksAreSupported() {
        var overrides = TextDecor()
        overrides.color = "#123456"
        let payload = TextStyleClipboard.payload(stored: overrides, inherited: .defaults, fontFamily: nil,
                                                 sharedStyleID: "style-1", source: "caption")
        #expect(payload.overrides == overrides && payload.sharedStyleID == "style-1")
        let linked = TextStyleClipboard.pasted(payload, onto: TextDecor(strokeOn: true), linkShared: true)
        #expect(linked.sharedStyleID == "style-1")
        #expect(linked.decor.color == "#123456" && linked.decor.strokeOn == nil, "the source's nil override clears the target's")
        let flat = TextStyleClipboard.pasted(payload, onto: nil, linkShared: false)
        #expect(flat.sharedStyleID == nil && flat.decor.strokeOn == false, "no link: the full look is written")
    }

    @Test func pasteboardRoundTrip() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("clipbuilder.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let payload = TextStyleClipboard.payload(stored: source, inherited: .defaults, fontFamily: "Menlo",
                                                 sharedStyleID: nil, source: "name tag line")
        #expect(TextStyleClipboard.read(from: pasteboard) == nil)
        TextStyleClipboard.write(payload, to: pasteboard)
        #expect(TextStyleClipboard.read(from: pasteboard) == payload)
    }
}
