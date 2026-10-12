import Testing
@testable import Clip_Builder

struct ActiveTranscriptionTests {
    @Test func pinWinsOverNewerSet() {
        let old = TranscriptionSet(id: "old", createdAt: "2026-10-11", model: nil)
        let new = TranscriptionSet(id: "new", createdAt: "2026-10-12", model: nil)
        let result = ActiveLayers.resolveTranscription(pinnedKey: "old", sets: [new, old])
        #expect(result.key == "old" && result.isPinned && !result.missingPin)
    }

    @Test func automaticUsesTimestampThenPortableKey() {
        let a = TranscriptionSet(id: "a", createdAt: "2026-10-12", model: nil)
        let z = TranscriptionSet(id: "z", createdAt: "2026-10-12", model: nil)
        #expect(ActiveLayers.resolveTranscription(pinnedKey: nil, sets: [z, a]).key == "z")
        #expect(ActiveLayers.resolveTranscription(pinnedKey: nil, sets: [a, z]).key == "z")
        #expect(ActiveLayers.resolveTranscription(pinnedKey: nil, sets: []).key == nil)
    }

    @Test func missingPinFallsBackWithoutDiscardingMissingState() {
        let set = TranscriptionSet(id: "local", createdAt: "2026-10-12", model: nil)
        let result = ActiveLayers.resolveTranscription(pinnedKey: "remote", sets: [set])
        #expect(result.key == "local" && result.missingPin && !result.isPinned)
        let empty = ActiveLayers.resolveTranscription(pinnedKey: "remote", sets: [])
        #expect(empty.key == nil && empty.missingPin)
    }
}
