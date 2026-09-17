import Foundation
import Testing
@testable import Clip_Builder

@Suite("Cleanup cut policy")
struct CleanupCutPolicyTests {
    private func proposal(_ id: Int64, _ kind: EditProposal.Kind, decision: EditProposal.Decision = .pending) -> EditProposal {
        EditProposal(id: id, videoID: 1, kind: kind, startTime: 0, endTime: 2, reason: "", decision: decision)
    }

    @Test("review keeps everything pending; dead-air accepts silences only; all accepts silences and filler")
    func decisions() {
        let fresh = [proposal(1, .silence), proposal(2, .filler), proposal(3, .falseStart)]
        #expect(CleanupCutPolicy.review.applied(to: fresh).map(\.decision) == [.pending, .pending, .pending])
        #expect(CleanupCutPolicy.acceptDeadAir.applied(to: fresh).map(\.decision) == [.accepted, .pending, .pending])
        #expect(CleanupCutPolicy.acceptAll.applied(to: fresh).map(\.decision) == [.accepted, .accepted, .pending])
        // A decision already made is never overridden.
        let rejected = [proposal(4, .silence, decision: .rejected)]
        #expect(CleanupCutPolicy.acceptAll.applied(to: rejected).map(\.decision) == [.rejected])
    }

    @Test("settings decode the policy and the automatic translation language, with safe defaults")
    func settingsDecode() throws {
        let decoder = JSONDecoder()
        let bare = try decoder.decode(PodcastSettings.self, from: Data("{}".utf8))
        #expect(bare.cleanupCutPolicy == .acceptDeadAir)
        #expect(bare.autoTranslateLanguage == "")
        let set = try decoder.decode(PodcastSettings.self,
                                     from: Data("{\"cleanup_cut_policy\": \"accept_all\", \"auto_translate_language\": \"pt-BR\"}".utf8))
        #expect(set.cleanupCutPolicy == .acceptAll)
        #expect(set.autoTranslateLanguage == "pt-BR")
        let encoded = try JSONEncoder().encode(set)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"cleanup_cut_policy\":\"accept_all\""))
    }
}
