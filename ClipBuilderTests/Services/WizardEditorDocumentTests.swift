import Foundation
import Testing
@testable import Clip_Builder

/// Open in Editor (docs/Open-In-Editor-Plan.md): the editable document is
/// the one `assemble` prepares and renders, and the fields that carry the
/// Wizard's burn-ins survive JSON.
@Suite("Wizard editor document")
struct WizardEditorDocumentTests {
    private struct ProbeStop: Error {}

    private nonisolated final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: TimelineDocument?
        var value: TimelineDocument? { lock.withLock { stored } }
        func set(_ document: TimelineDocument) { lock.withLock { stored = document } }
    }

    /// Sorted-key JSON with every UUID replaced by its order of first
    /// appearance: origin keys and the retained cards folder are fresh per call.
    static func normalizedJSON(_ document: TimelineDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var text = String(decoding: try encoder.encode(document), as: UTF8.self)
        let pattern = try NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        var seen: [String: String] = [:]
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let id = String(text[range])
            if seen[id] == nil { seen[id] = "UUID-\(seen.count)" }
        }
        for (id, token) in seen { text = text.replacingOccurrences(of: id, with: token) }
        return text
    }

    private func fixture() async throws -> (TempDatabase, WizardSelectionTake, WizardOptions, WizardEngine) {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let projectID = try await temp.database.createProject(profileName: "Editor", name: "Editor", videoIDs: [videoID])
        let scene = try #require(try await temp.database.fetchScenes(projectID: projectID).first)
        var options = WizardOptions()
        options.projectID = projectID
        options.useMusic = false
        options.critiqueLoop = false
        options.framing = Framing(subject: .original)
        options.addCaptions = true
        options.captionPosition = "top"
        options.safeAreaOnly = true
        options.safeAreaPlatforms = [.instagram]
        options.includeHeadline = true
        var plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 1, end: 4),
                                         Fixtures.planClip(sceneID: scene.id, start: 5, end: 7)],
                                 transitions: ["fade"])
        plan.headline = "Editor parity"
        let take = try await temp.database.recordWizardTake(projectID: projectID, options: options.step1, plan: plan)
        let ai = AIService(config: AIConfig()) { _, _, _, _, _, _ in
            Issue.record("Preparing a saved take must not call a model")
            throw CancellationError()
        }
        return (temp, take, options, WizardEngine(ai: ai, render: RenderEngine()))
    }

    @Test("editorDocument is the document assemble prepares for the same take")
    func editorDocumentMatchesAssemble() async throws {
        let (temp, take, options, engine) = try await fixture()
        let profile = Fixtures.brand(name: "Editor")
        let editor = try await engine.editorDocument(take: take, options: options, profile: profile,
                                                     database: temp.database, emit: { _ in })
        let captured = Captured()
        do {
            try await WizardEngine.$preparedDocumentProbe.withValue({ document in
                captured.set(document)
                throw ProbeStop()
            }) {
                try await engine.makeReel(take: take, options: options, profile: profile,
                                          database: temp.database, emit: { _ in })
            }
            Issue.record("The probe must stop assemble before it encodes")
        } catch is ProbeStop {}
        let assembled = try #require(captured.value)
        #expect(try Self.normalizedJSON(editor) == Self.normalizedJSON(assembled))
        // Generate never filed a video: the probe stopped it before encoding.
        #expect(try await temp.database.fetchGeneratedVideos(projectID: options.projectID).isEmpty)

        // The burn-ins the extraction adds are on the document.
        #expect(editor.captionPosition == "top")
        #expect(editor.captionLanguage == "")
        #expect(editor.captionSafeAreaOnly == true)
        #expect(editor.captionSafeAreaPlatforms == [.instagram])
        #expect(editor.framingCamera == "balanced")
        #expect(editor.musicMix == nil)
        let headline = try #require(editor.brandLayers?.first)
        #expect(editor.brandLayers?.count == 1 && headline.kind == BrandLayerItem.headline)
        #expect(FileManager.default.fileExists(atPath: headline.path))
        #expect(WizardEngine.isWizardCard(headline.path))
        let main = editor.videoTrack.filter { $0.track == 0 && !$0.bumper }
        #expect(main.count == 2 && main.allSatisfy { $0.captions == "top" })
    }

    @Test("new document fields round-trip and decode as nil when absent")
    func fieldsRoundTrip() throws {
        var clip = Fixtures.timelineClip()
        clip.contentWindow = FreeCropRect(xFrac: 0.1, yFrac: 0.05, wFrac: 0.8, hFrac: 0.9)
        var document = Fixtures.timelineDocument(clips: [clip])
        document.captionStyleID = UUID().uuidString
        document.captionLanguage = "es"
        document.captionPosition = "custom:0.5,0.3"
        document.captionSafeAreaOnly = true
        document.captionSafeAreaPlatforms = [.instagram, .tiktok]
        document.speakerCaptionPositions = ["ann": "top", "ben": "bottom"]
        document.brandLayers = [BrandLayerItem(path: "/tmp/watermark.png", kind: BrandLayerItem.watermark)]
        document.brandLayerStage = TimelineDocument.brandUnderCutaways
        document.framingCamera = "conversation"
        document.musicMix = TimelineDocument.wizardMusicMix
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded.captionStyleID == document.captionStyleID)
        #expect(decoded.captionLanguage == "es")
        #expect(decoded.captionPosition == "custom:0.5,0.3")
        #expect(decoded.captionSafeAreaOnly == true)
        #expect(decoded.captionSafeAreaPlatforms == [.instagram, .tiktok])
        #expect(decoded.speakerCaptionPositions == ["ann": "top", "ben": "bottom"])
        #expect(decoded.brandLayers == document.brandLayers)
        #expect(decoded.brandLayerStage == "under_cutaways")
        #expect(decoded.framingCamera == "conversation")
        #expect(decoded.musicMix == "wizard")
        #expect(decoded.videoTrack.first?.contentWindow == clip.contentWindow)

        let legacy = try JSONDecoder().decode(TimelineDocument.self, from: Data(#"{"video_track":[{"type":"clip","start_time":0,"video_file":"/tmp/a.mp4","start":0,"end":2}]}"#.utf8))
        #expect(legacy.captionStyleID == nil && legacy.captionLanguage == nil && legacy.captionPosition == nil)
        #expect(legacy.captionSafeAreaOnly == nil && legacy.captionSafeAreaPlatforms == nil)
        #expect(legacy.speakerCaptionPositions == nil && legacy.brandLayers == nil && legacy.brandLayerStage == nil)
        #expect(legacy.framingCamera == nil && legacy.musicMix == nil)
        #expect(legacy.videoTrack.count == 1 && legacy.videoTrack.first?.contentWindow == nil)
        // A Builder document writes none of the keys.
        let plain = String(decoding: try JSONEncoder().encode(Fixtures.timelineDocument()), as: UTF8.self)
        for key in ["caption_style_id", "caption_language", "caption_position", "caption_safe_area_only",
                    "caption_safe_area_platforms", "speaker_caption_positions", "brand_layers", "brand_layer_stage",
                    "framing_camera", "music_mix", "content_window"] {
            #expect(!plain.contains("\"\(key)\""), "\(key)")
        }
    }

    @Test("brand layers cover footage only, merged, never bumpers or Wizard cards")
    func brandLayerSpans() {
        var first = Fixtures.timelineClip(sceneID: 1, sourceStart: 0, duration: 2, startTime: 0)
        first.videoFile = "/tmp/a.mp4"
        var second = Fixtures.timelineClip(sceneID: 1, sourceStart: 2, duration: 2, startTime: 2)
        second.videoFile = "/tmp/a.mp4"
        var bumper = TimelineClip()
        bumper.bumper = true; bumper.videoFile = "/tmp/bumper.mp4"; bumper.startTime = 4; bumper.duration = 1
        var third = Fixtures.timelineClip(sceneID: 1, sourceStart: 4, duration: 1, startTime: 5)
        third.videoFile = "/tmp/a.mp4"
        var card = TimelineClip()
        card.videoFile = WizardEngine.wizardCardsRoot.appendingPathComponent("x/outro_card.mp4").path
        card.startTime = 6; card.duration = 2.5
        var upper = Fixtures.timelineClip(sceneID: 1, sourceStart: 0, duration: 8, startTime: 0, track: 1)
        upper.videoFile = "/tmp/b.mp4"
        let document = Fixtures.timelineDocument(clips: [first, second, bumper, third, card, upper])
        let spans = MultitrackRenderer.brandLayerSpans(document: document, totalDuration: 8.5)
        #expect(spans == [0..<4, 5..<6])
    }

    @Test("content windows land on the cut's own clips")
    func contentWindowsFollowTheirCut() {
        let scene = Fixtures.scene(id: 7, start: 0)
        var plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: 7, start: 0, end: 2),
                                         Fixtures.planClip(sceneID: 7, start: 3, end: 5)])
        plan.transitions = ["cut"]
        var document = WizardEngine.timelineDocument(from: plan, sceneMap: [7: scene])
        let box = RenderEngine.ContentBox(x: 0.1, y: 0.2, w: 0.8, h: 0.6, aspect: 1)
        WizardEngine.applyContentWindows([1: box], plan: plan, sceneMap: [7: scene], to: &document)
        let windows = document.videoTrack.sorted { $0.startTime < $1.startTime }.map(\.contentWindow)
        #expect(windows == [nil, FreeCropRect(xFrac: 0.1, yFrac: 0.2, wFrac: 0.8, hFrac: 0.6)])
    }
}
