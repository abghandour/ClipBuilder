import Testing
@testable import Clip_Builder

@Suite("Builder assistant")
struct BuilderAssistantTests {
    @Test(arguments: ["put a duck face on the left fighter", "ADD a crown sticker", "draw glasses", "generate an image", "make a picture", "give him a hat", "put a\nmask on her",
                      "Add a sticker to the clip", "Make an image for the reel"])
    func imageRequests(_ text: String) {
        #expect(BuilderAssistant.route(text) == .image(text))
    }

    @Test(arguments: ["Make a 30-second reel", "Remove the image", "Face the camera", "Put the clip first", "Make a faceoff reel", "Makeup image", "",
                      "Make a 30-second reel of the face off", "Make a reel where he puts his glasses on", "Add the clip with the mask walkout"])
    func wizardRequests(_ text: String) {
        #expect(BuilderAssistant.route(text) == .wizard(text))
    }

    @Test func whitespaceIsTrimmed() {
        #expect(BuilderAssistant.route("  Put a sticker on him\n") == .image("Put a sticker on him"))
        #expect(BuilderAssistant.route("  trim the first clip  ") == .wizard("trim the first clip"))
    }

    // MARK: - Context and suggestions

    private func context(_ edit: (inout BuilderAssistant.Snapshot) -> Void = { _ in }) -> AssistantContext {
        var snapshot = BuilderAssistant.Snapshot()
        snapshot.timelineName = "Reel"
        snapshot.durationSeconds = 75
        snapshot.clipCount = 4
        edit(&snapshot)
        return BuilderAssistant.context(snapshot)
    }

    private func ids(_ context: AssistantContext) -> [String] {
        BuilderAssistant().suggestions(for: context).map(\.id)
    }

    @Test func summaryLine() {
        #expect(context().summaryLine == "Builder · Reel · 1:15 · 4 clips · captions off")
        #expect(context { $0.reviewFlags = 2; $0.captionsOn = true }.summaryLine == "Builder · Reel · 1:15 · 4 clips · captions on · 2 flags")
        #expect(BuilderAssistant.context(.init()).summaryLine == "Builder · No timeline open")
    }

    @Test func quietWithoutATimelineOrReasons() {
        #expect(ids(BuilderAssistant.context(.init())).isEmpty)
        #expect(ids(context()).isEmpty)
    }

    @Test func reviewFlagsRule() {
        let rows = BuilderAssistant().suggestions(for: context { $0.reviewFlags = 3 })
        #expect(rows.map(\.id) == ["builder.flags.review"])
        #expect(rows.first?.actionID == "builder.flags.jump")
        #expect(rows.first?.title == "Check 3 flagged moments")
    }

    @Test func cleanupRule() {
        #expect(ids(context { $0.cleanupCuts = 5 }) == ["builder.cleanup.apply"])
        #expect(ids(context { $0.cleanupCuts = 0 }).isEmpty)
        #expect(ids(context { $0.cleanupCuts = nil }).isEmpty)
    }

    @Test func speechPolishRule() {
        #expect(ids(context { $0.hasSpeech = true }) == ["builder.polish.on"])
        #expect(ids(context { $0.hasSpeech = true; $0.speechPolish = true }).isEmpty)
        #expect(BuilderAssistant().suggestions(for: context { $0.hasSpeech = true }).first?.kind == .setting)
    }

    @Test func captionsRule() {
        #expect(ids(context { $0.hasTranscript = true; $0.hasSpeech = true; $0.speechPolish = true }) == ["builder.captions.on"])
        #expect(ids(context { $0.hasTranscript = true; $0.hasSpeech = true; $0.speechPolish = true; $0.captionsOn = true }).isEmpty)
    }

    @Test func cleanupCountIsPerTimelineAndRevision() {
        #expect(BuilderAssistant.cleanupCutsKey(timelineID: 7, revision: 3) == "7@3")
        #expect(BuilderAssistant.cleanupCutsKey(timelineID: 7, revision: 3) != BuilderAssistant.cleanupCutsKey(timelineID: 8, revision: 3))
        let state = BuilderAssistant.cleanupCutsState(4, timelineID: 7, revision: 3)
        #expect(BuilderAssistant.cleanupCuts(in: state, timelineID: 7, revision: 3) == 4)
        // An edit (new revision) or another timeline: not counted yet, so no suggestion from a stale count.
        #expect(BuilderAssistant.cleanupCuts(in: state, timelineID: 7, revision: 4) == nil)
        #expect(BuilderAssistant.cleanupCuts(in: state, timelineID: 8, revision: 3) == nil)
        #expect(BuilderAssistant.cleanupCuts(in: AssistantPageState(), timelineID: 7, revision: 3) == nil)
        // A newer count replaces the older one under the same keys.
        let newer = state.merging(BuilderAssistant.cleanupCutsState(0, timelineID: 7, revision: 5))
        #expect(BuilderAssistant.cleanupCuts(in: newer, timelineID: 7, revision: 5) == 0)
        #expect(BuilderAssistant.cleanupCuts(in: newer, timelineID: 7, revision: 3) == nil)
    }

    // MARK: - Captions resolved per clip

    private func document(trackCaptions: String, clips: [(captions: String, bumper: Bool, role: ClipRole)]) -> TimelineDocument {
        var document = TimelineDocument()
        document.trackSettings[0].captions = trackCaptions
        document.videoTrack = clips.map { spec in
            var clip = TimelineClip()
            clip.captions = spec.captions
            clip.bumper = spec.bumper
            clip.role = spec.role
            return clip
        }
        return document
    }

    @Test func wizardClipsWithCaptionsOffAreNotVisible() {
        // The Wizard writes "none" on every clip when captions are off: the track setting alone shows nothing.
        let wizardOff = document(trackCaptions: "bottom", clips: [("none", false, .main), ("none", false, .main)])
        #expect(!BuilderAssistant.captionsVisible(wizardOff))
        #expect(BuilderAssistant.captionsVisible(document(trackCaptions: "bottom", clips: [("inherit", false, .main)])))
        #expect(!BuilderAssistant.captionsVisible(document(trackCaptions: "none", clips: [("inherit", false, .main)])))
        #expect(BuilderAssistant.captionsVisible(document(trackCaptions: "none", clips: [("top", false, .main)])))
        // A bumper's own setting does not count.
        #expect(!BuilderAssistant.captionsVisible(document(trackCaptions: "none", clips: [("bottom", true, .main)])))
    }

    @Test func turningCaptionsOnReachesWizardClips() {
        let wizardOff = document(trackCaptions: "none",
                                 clips: [("none", false, .main), ("none", true, .main), ("none", false, .cutaway), ("top", false, .main)])
        let on = BuilderAssistant.turningCaptionsOn(wizardOff)
        #expect(on.trackSettings[0].captions == "bottom")
        #expect(on.videoTrack.map(\.captions) == ["inherit", "none", "none", "top"])
        #expect(BuilderAssistant.captionsVisible(on))
        // Already on: nothing changes, so no undo step.
        #expect(BuilderAssistant.turningCaptionsOn(on) == on)
        // An existing track position is kept.
        let middle = BuilderAssistant.turningCaptionsOn(document(trackCaptions: "middle", clips: [("none", false, .main)]))
        #expect(middle.trackSettings[0].captions == "middle")
        #expect(middle.videoTrack.map(\.captions) == ["inherit"])
    }
}
