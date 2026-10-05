import Foundation

/// Presentation and source-time editing data shared by Q&A and Highlights.
nonisolated struct RangeReviewItem: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        var ownerID: Int64
        var revisionID: Int64? = nil
        var cutIndex: Int? = nil
    }

    struct Caption: Sendable {
        var text: String
        var lineLimit = 1
        var monospaced = false
    }

    enum TrimPolicy: Sendable {
        case qa, wizard

        var minimumSpan: Double { self == .qa ? TranscriptQATrim.minimumSpan : ProposedCutTrim.minimumSpan }

        func clamp(_ range: ClosedRange<Double>, limits: ClosedRange<Double>) -> ClosedRange<Double> {
            switch self {
            case .qa: TranscriptQATrim.clamped(range, limits: limits)
            case .wizard: ProposedCutTrim.clamp(start: range.lowerBound, end: range.upperBound, scene: limits)
            }
        }

        func setting(_ edge: TranscriptQATrim.Edge, at time: Double, in range: ClosedRange<Double>,
                     limits: ClosedRange<Double>) -> ClosedRange<Double> {
            switch self {
            case .qa: TranscriptQATrim.setting(edge, at: time, in: range, limits: limits)
            case .wizard:
                edge == .start ? ProposedCutTrim.settingStart(at: time, in: range, scene: limits)
                    : ProposedCutTrim.settingEnd(at: time, in: range, scene: limits)
            }
        }

        func releasing(_ draft: ClosedRange<Double>, from original: ClosedRange<Double>,
                       words: [TranscriptQATrim.Word], limits: ClosedRange<Double>) -> ClosedRange<Double> {
            switch self {
            case .qa: TranscriptQATrim.releasing(draft, from: original, words: words, limits: limits)
            case .wizard: clamp(draft, limits: limits)
            }
        }
    }

    var id: ID
    var title: String
    var titleHelp: String
    var keepLabel: String
    var captions: [Caption]
    var video: VideoRecord
    var range: ClosedRange<Double>
    var originalRange: ClosedRange<Double>
    var limits: ClosedRange<Double>
    var trimPolicy: TrimPolicy
    var isAvailable = true
    var children: [RangeReviewItem] = []

    var isTrimmed: Bool {
        ProposedCutTrim.differs(range, proposedStart: originalRange.lowerBound, proposedEnd: originalRange.upperBound)
    }

    static func rangeCaption(_ range: ClosedRange<Double>) -> String {
        "\(range.lowerBound.timecode)–\(range.upperBound.timecode) · \((range.upperBound - range.lowerBound).formatted(.number.precision(.fractionLength(1))))s"
    }

    static func allKept(_ kept: Set<Int64>, items: [RangeReviewItem]) -> Bool {
        Set(items.map { $0.id.ownerID }).isSubset(of: kept)
    }

    static func togglingAll(_ kept: Set<Int64>, items: [RangeReviewItem]) -> Set<Int64> {
        allKept(kept, items: items) ? [] : Set(items.map { $0.id.ownerID })
    }
}
