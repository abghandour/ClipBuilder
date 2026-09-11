import Foundation

/// Strict wire wrapper: the document's synthesized codec accepts unknown keys.
nonisolated struct BuilderPacing: Codable, Sendable, Equatable {
    var cadence: CutCadence
    var curve: PaceCurve

    init(cadence: CutCadence, curve: PaceCurve = .steady) {
        self.cadence = cadence; self.curve = curve
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ScriptKey.self)
        try c.only(["cadence", "curve"])
        cadence = try c.decode(CutCadence.self, forKey: ScriptKey("cadence"))
        curve = try c.decode(PaceCurve.self, forKey: ScriptKey("curve"))
    }

    var value: EditPacing { EditPacing(cadence: cadence, curve: curve) }
}
