import Foundation

/// What happens to the pauses and filler runs the transcript analysis
/// finds. Dead air is objective (a silence longer than the threshold);
/// filler is a judgement about speech style, so the default accepts only
/// the former and leaves filler for the user to decide.
nonisolated enum CleanupCutPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Every cut stays Pending until decided in Transcript Tools or the
    /// review before rendering.
    case review
    /// Silences are accepted at once; filler runs stay Pending.
    case acceptDeadAir = "accept_dead_air"
    /// Silences and filler runs are accepted at once.
    case acceptAll = "accept_all"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .review: "Review every cut"
        case .acceptDeadAir: "Accept dead air, review filler"
        case .acceptAll: "Accept dead air and filler"
        }
    }

    var help: String {
        switch self {
        case .review: "Pauses and filler runs are listed as proposed cuts and wait for your decision."
        case .acceptDeadAir: "Silences longer than the dead-air threshold are cut without asking; filler runs wait for your decision, since filler is a matter of style."
        case .acceptAll: "Both silences and filler runs are cut without asking. You can still reject any of them in Transcript Tools."
        }
    }

    /// The decision a freshly detected cut starts with under this policy.
    func decision(for kind: EditProposal.Kind) -> EditProposal.Decision {
        switch (self, kind) {
        case (.review, _): .pending
        case (.acceptDeadAir, .silence), (.acceptAll, .silence), (.acceptAll, .filler): .accepted
        default: .pending
        }
    }

    /// Fresh proposals with their starting decision applied.
    func applied(to proposals: [EditProposal]) -> [EditProposal] {
        proposals.map { proposal in
            var proposal = proposal
            if proposal.decision == .pending { proposal.decision = decision(for: proposal.kind) }
            return proposal
        }
    }
}
