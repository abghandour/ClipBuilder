import Foundation

nonisolated enum CutCadence: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic, twoSeconds, threeSeconds, mixedTwoToFour

    var id: String { rawValue }
    var label: String {
        return switch self {
        case .automatic: "Automatic"
        case .twoSeconds: "Every 2 seconds"
        case .threeSeconds: "Every 3 seconds"
        case .mixedTwoToFour: "Mix of 2–4 seconds"
        }
    }
    var range: ClosedRange<Double>? {
        switch self {
        case .automatic: nil
        case .twoSeconds: 1.8...2.2
        case .threeSeconds: 2.7...3.3
        case .mixedTwoToFour: 2...4
        }
    }
    var averageSeconds: Double? { range.map { ($0.lowerBound + $0.upperBound) / 2 } }
}

nonisolated enum PaceCurve: String, Codable, CaseIterable, Sendable, Identifiable {
    case steady, accelerate, decelerate, buildThenDrop

    var id: String { rawValue }
    var label: String {
        switch self {
        case .steady: "Steady"
        case .accelerate: "Accelerate"
        case .decelerate: "Decelerate"
        case .buildThenDrop: "Build, then drop"
        }
    }
    func intervalMultiplier(at progress: Double) -> Double {
        let progress = min(1, max(0, progress))
        return switch self {
        case .steady: 1
        case .accelerate: 1.35 - 0.7 * progress
        case .decelerate: 0.65 + 0.7 * progress
        case .buildThenDrop: progress < 0.72 ? 1.25 - 0.65 * (progress / 0.72) : 1.45
        }
    }
}

nonisolated struct EditPacing: Codable, Sendable, Equatable, Hashable {
    var cadence: CutCadence = .automatic
    var curve: PaceCurve = .steady

    func interval(at progress: Double) -> Double? {
        cadence.averageSeconds.map { $0 * curve.intervalMultiplier(at: progress) }
    }

    func markers(until duration: Double) -> [Double] {
        guard duration > 0, cadence != .automatic else { return [] }
        var result: [Double] = []
        var cursor = 0.0
        while cursor < duration {
            cursor += interval(at: cursor / duration) ?? duration
            if cursor < duration { result.append(cursor) }
        }
        return result
    }
}
