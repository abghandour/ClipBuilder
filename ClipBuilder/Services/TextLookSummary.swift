import Foundation

/// Inspector copy is derived from resolved values; override counts use only stored values.
nonisolated enum TextLookSummary {
    static func overrideCount(_ decor: TextDecor?, prefix: String? = nil) -> Int {
        guard let decor else { return 0 }
        return Mirror(reflecting: decor).children.filter { child in
            (prefix == nil || child.label?.hasPrefix(prefix!) == true)
                && !Mirror(reflecting: child.value).children.isEmpty
        }.count
    }

    static func shadow(_ resolved: TextDecor, stored: TextDecor?) -> String {
        guard resolved.shadowOn == true else { return "Off" }
        let name =
            TextShadowPresets.matching(resolved)?.name
            ?? (resolved.shadowStyle == "extrude" ? "3D extrude" : resolved.shadowStyle == "hard" ? "Hard" : "Soft")
        let count = overrideCount(stored, prefix: "shadow")
        return count == 0 ? name : "\(name) · \(count) override\(count == 1 ? "" : "s")"
    }

    static func box(_ resolved: TextDecor, perWord: Bool) -> String {
        guard resolved.bgOn == true else { return "Off" }
        let scope = resolved.bgPerLine == true ? "per line" : perWord ? "per word" : "whole box"
        return "\((resolved.bgColor ?? "#000000").uppercased()) · radius \(number(resolved.bgRadius ?? 0)) · \(scope)"
    }

    static func stroke(_ resolved: TextDecor) -> String {
        resolved.strokeOn == true
            ? "\((resolved.strokeColor ?? "#000000").uppercased()) · width \(number(resolved.strokeWidth ?? 0))" : "Off"
    }

    static func border(_ resolved: TextDecor) -> String {
        resolved.borderOn == true
            ? "\((resolved.borderColor ?? "#FFFFFF").uppercased()) · width \(number(resolved.borderWidth ?? 0))" : "Off"
    }

    static func resetBox(in decor: TextDecor?) -> TextDecor? {
        guard var decor else { return nil }
        decor.bgOn = nil
        decor.bgColor = nil
        decor.bgOpacity = nil
        decor.bgRadius = nil
        decor.bgPaddingX = nil
        decor.bgPaddingY = nil
        decor.bgPerLine = nil
        decor.borderOn = nil
        decor.borderWidth = nil
        decor.borderColor = nil
        return decor
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
