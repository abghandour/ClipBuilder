import AppKit
import Foundation

/// One text element's look, copied so another element can take it: captions
/// (per word state), name-tag lines and overlays all store the same
/// `TextDecor`, so one payload serves every surface.
nonisolated struct TextStylePayload: Codable, Equatable, Sendable {
    /// The resolved appearance: what the source looked like, every field set.
    var look: TextDecor
    /// The source's own overrides on top of its shared style, when it had one.
    var overrides: TextDecor?
    var sharedStyleID: String?
    var fontFamily: String?
    /// Where it came from, for the Paste button's tooltip.
    var source: String
}

nonisolated enum TextStyleClipboard {
    static let pasteboardType = NSPasteboard.PasteboardType("com.clipbuilder.text-style")

    /// What a partial paste can carry across. Placement (alignment, width) is
    /// never pasted: it would move the target.
    enum Group: String, CaseIterable, Sendable {
        case typography, fill, stroke, shadow, background

        var label: String {
            switch self {
            case .typography: "Typography"
            case .fill: "Fill"
            case .stroke: "Stroke"
            case .shadow: "Shadow"
            case .background: "Background and border"
            }
        }
    }

    static func payload(stored: TextDecor?, inherited: TextDecor, fontFamily: String?,
                        sharedStyleID: String?, source: String) -> TextStylePayload {
        var look = (stored ?? TextDecor()).resolved(over: inherited)
        look.alignment = nil
        look.maxWidthFrac = nil
        return TextStylePayload(look: look, overrides: sharedStyleID == nil ? nil : (stored ?? TextDecor()),
                                sharedStyleID: sharedStyleID, fontFamily: fontFamily, source: source)
    }

    /// The target after a paste. With `linkShared` the target can hold a
    /// shared-style link, so a linked source pastes its link plus its own
    /// overrides and later edits to the named style keep reaching both;
    /// otherwise the full look is written as explicit values.
    static func pasted(_ payload: TextStylePayload, onto stored: TextDecor?, groups: Set<Group> = Set(Group.allCases),
                       linkShared: Bool) -> (decor: TextDecor, sharedStyleID: String?, fontFamily: String?) {
        let useLink = linkShared && payload.sharedStyleID != nil
        let from = useLink ? (payload.overrides ?? TextDecor()) : payload.look
        var result = stored ?? TextDecor()
        for group in groups { copy(group, from: from, into: &result) }
        return (result, useLink ? payload.sharedStyleID : nil,
                groups.contains(.typography) ? payload.fontFamily : nil)
    }

    /// Every key in the group moves across, nil included, so the target ends
    /// up exactly like the source for that group.
    static func copy(_ group: Group, from: TextDecor, into target: inout TextDecor) {
        switch group {
        case .typography:
            target.weight = from.weight; target.italic = from.italic; target.underline = from.underline
            target.strikethrough = from.strikethrough; target.casing = from.casing; target.size = from.size
            target.letterSpacing = from.letterSpacing; target.lineHeight = from.lineHeight
            target.underlineColor = from.underlineColor; target.underlineThickness = from.underlineThickness
        case .fill:
            target.color = from.color; target.gradientOn = from.gradientOn; target.fillEndColor = from.fillEndColor
            target.fillAngle = from.fillAngle; target.textOpacity = from.textOpacity
        case .stroke:
            target.strokeOn = from.strokeOn; target.strokeWidth = from.strokeWidth
            target.strokeColor = from.strokeColor; target.strokeOpacity = from.strokeOpacity
        case .shadow:
            target.shadowOn = from.shadowOn; target.shadowColor = from.shadowColor; target.shadowOpacity = from.shadowOpacity
            target.shadowX = from.shadowX; target.shadowY = from.shadowY; target.shadowBlur = from.shadowBlur
            target.shadowStyle = from.shadowStyle
        case .background:
            target.bgOn = from.bgOn; target.bgColor = from.bgColor; target.bgOpacity = from.bgOpacity
            target.bgRadius = from.bgRadius; target.bgPaddingX = from.bgPaddingX; target.bgPaddingY = from.bgPaddingY
            target.bgPerLine = from.bgPerLine; target.borderOn = from.borderOn
            target.borderWidth = from.borderWidth; target.borderColor = from.borderColor
        }
    }

    // MARK: - Pasteboard

    static func encode(_ payload: TextStylePayload) -> Data? { try? JSONEncoder().encode(payload) }
    static func decode(_ data: Data) -> TextStylePayload? { try? JSONDecoder().decode(TextStylePayload.self, from: data) }

    /// The system pasteboard carries it, so it survives switching profiles
    /// and windows and works between two running copies of the app.
    static func write(_ payload: TextStylePayload, to pasteboard: NSPasteboard = .general) {
        guard let data = encode(payload) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: pasteboardType)
    }

    static func read(from pasteboard: NSPasteboard = .general) -> TextStylePayload? {
        pasteboard.data(forType: pasteboardType).flatMap(decode)
    }
}
