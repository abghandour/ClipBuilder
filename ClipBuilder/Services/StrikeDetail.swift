import Foundation

/// What kind of strike an event was, as the scoring model saw it: the
/// technique, which of the attacker's limbs threw it, where it landed, and
/// which side of the frame the attacker stood on at contact.
///
/// Stored in `FightEventRecord.detail` as "kick|left|legs|right" so it rides
/// the existing column. Every part but the technique may be missing.
/// The limb and frame side are what `StrikeHighlightRules` uses to find the
/// limb in the picture.
nonisolated struct StrikeDetail: Equatable, Sendable {
    enum Technique: String, CaseIterable, Sendable, Codable {
        case punch, kick, knee, elbow

        /// Arms throw punches and elbows; legs throw kicks and knees.
        var usesArm: Bool { self == .punch || self == .elbow }
    }

    enum Side: String, Sendable, Codable { case left, right }
    enum Target: String, CaseIterable, Sendable { case head, body, legs }

    var technique: Technique
    /// The attacker's own left or right limb.
    var limb: Side?
    var target: Target?
    /// Where the attacker stands in the picture at contact.
    var frameSide: Side?

    var encoded: String {
        [technique.rawValue, limb?.rawValue ?? "", target?.rawValue ?? "", frameSide?.rawValue ?? ""]
            .joined(separator: "|")
    }

    init(technique: Technique, limb: Side? = nil, target: Target? = nil, frameSide: Side? = nil) {
        self.technique = technique
        self.limb = limb
        self.target = target
        self.frameSide = frameSide
    }

    /// From a stored `detail`. nil for anything that is not a strike detail
    /// (a submission hold, an older event with none).
    init?(_ stored: String?) {
        let parts = (stored ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let technique = Technique(rawValue: first) else { return nil }
        func part(_ index: Int) -> String { index < parts.count ? parts[index] : "" }
        self.init(technique: technique, limb: Side(rawValue: part(1)),
                  target: Target(rawValue: part(2)), frameSide: Side(rawValue: part(3)))
    }

    /// From one event of the model's answer. The model writes loosely
    /// ("Left", "leg kick", "torso"), so the words are matched, not compared.
    init?(response entry: [String: Any]) {
        func word(_ key: String) -> String {
            (entry[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let named = word("technique")
        let technique: Technique? =
            named.contains("knee") ? .knee
            : named.contains("elbow") ? .elbow
            : named.contains("kick") ? .kick
            : ["punch", "jab", "cross", "hook", "uppercut", "overhand", "hammer"].contains(where: named.contains) ? .punch
            : nil
        guard let technique else { return nil }
        func side(_ value: String) -> Side? {
            value.hasPrefix("l") ? .left : value.hasPrefix("r") ? .right : nil
        }
        let aimed = word("target")
        let target: Target? =
            ["head", "face", "chin", "jaw", "neck"].contains(where: aimed.contains) ? .head
            : ["leg", "thigh", "calf", "knee", "shin"].contains(where: aimed.contains) ? .legs
            : ["body", "torso", "rib", "chest", "stomach", "liver", "arm", "guard", "shoulder"].contains(where: aimed.contains) ? .body
            : nil
        self.init(technique: technique, limb: side(word("limb")), target: target, frameSide: side(word("side")))
    }

    /// "left kick to the legs", "punch to the head", "knee".
    var label: String {
        var text = limb.map { "\($0.rawValue) " } ?? ""
        text += technique.rawValue
        if let target { text += target == .legs ? " to the legs" : " to the \(target.rawValue)" }
        return text
    }
}
