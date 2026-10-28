import Foundation
import CoreGraphics

nonisolated enum TextColor {
    static func parseColor(_ string: String?, fallback: (CGFloat, CGFloat, CGFloat) = (1, 1, 1))
        -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard let string else { return fallback }
        var hex = string.trimmingCharacters(in: .whitespaces).lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        else if hex.hasPrefix("0x") { hex.removeFirst(2) }
        else {
            switch hex {
            case "white": return (1, 1, 1)
            case "black": return (0, 0, 0)
            case "red": return (1, 0, 0)
            case "yellow": return (1, 1, 0)
            default: break
            }
        }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else { return fallback }
        return (CGFloat((value >> 16) & 0xff) / 255,
                CGFloat((value >> 8) & 0xff) / 255,
                CGFloat(value & 0xff) / 255)
    }

    static func cgColor(_ string: String?, fallback: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)) -> CGColor {
        let (r, g, b) = parseColor(string, fallback: fallback)
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }

}
