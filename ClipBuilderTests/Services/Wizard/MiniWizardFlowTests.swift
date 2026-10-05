import Foundation
import Testing
@testable import Clip_Builder

@Suite("Mini Wizard flow")
struct MiniWizardFlowTests {
    @Test("Only podcasts and interviews offer a footage choice", arguments: VideoType.allCases)
    func footageChoices(type: VideoType) {
        var video = Fixtures.video()
        video.videoType = type.rawValue
        let podcast = type == .podcast || type == .interview
        let flow = MiniWizardFlow(video: video)
        #expect(flow.isPodcastOrInterview == podcast)
        #expect(flow.showsFootageKind == podcast)
        #expect(flow.footageKinds == (podcast ? [.qa, .highlights] : [.highlights]))
    }

    @Test("Podcast exchanges enable podcast questions regardless of declared type", arguments: VideoType.allCases)
    func podcastExchangeFallback(type: VideoType) {
        var video = Fixtures.video()
        video.videoType = type.rawValue
        let flow = MiniWizardFlow(video: video, hasPodcastExchangeScenes: true, footageKind: .qa)
        #expect(flow.footageKinds == [.qa, .highlights])
        #expect(flow.showsFootageKind)
        #expect(!flow.showsLength)
        #expect(flow.showsCameraFocus)
        #expect(flow.showsNameTags)
    }

    @Test("Unknown types use highlights unless exchanges exist")
    func unknownType() {
        let video = Fixtures.video()
        #expect(video.type == nil)
        let ordinary = MiniWizardFlow(video: video, footageKind: .qa)
        #expect(ordinary.footageKinds == [.highlights])
        #expect(!ordinary.showsFootageKind)
        #expect(ordinary.effectiveFootageKind == .highlights)
        #expect(ordinary.showsLength)
        #expect(MiniWizardFlow(video: video, hasPodcastExchangeScenes: true).showsFootageKind)
        let empty = MiniWizardFlow(hasPodcastExchangeScenes: true)
        #expect(!empty.showsFootageKind)
        #expect(!empty.showsCameraFocus)
        #expect(!empty.showsNameTags)
    }

    @Test("Length and podcast settings follow the effective footage kind", arguments: VideoType.allCases)
    func footageQuestions(type: VideoType) {
        var video = Fixtures.video()
        video.videoType = type.rawValue
        let podcast = type == .podcast || type == .interview
        for kind in MiniWizardFlow.FootageKind.allCases {
            let flow = MiniWizardFlow(video: video, footageKind: kind)
            #expect(flow.effectiveFootageKind == (podcast ? kind : .highlights))
            #expect(flow.showsLength == (!podcast || kind == .highlights))
            #expect(flow.showsCameraFocus == podcast)
            #expect(flow.showsNameTags == podcast)
        }
    }

    @Test("Lengths are 10, 15, 30 seconds or Auto")
    func lengths() {
        let flow = MiniWizardFlow()
        #expect(flow.lengthOptions == [.ten, .fifteen, .thirty, .automatic])
        #expect(flow.lengthOptions.map(\.seconds) == [10, 15, 30, nil])
        #expect(flow.lengthOptions.map(\.label) == ["10 s", "15 s", "30 s", "Auto"])
        #expect(flow.length == .automatic)
        #expect(MiniWizardFlow.Length(rawValue: "30") == .thirty)
        #expect(MiniWizardFlow.Length(rawValue: "auto") == .automatic)
    }

    @Test("Caption language needs captions and a known non-English transcript")
    func captionLanguage() {
        let hidden: [String?] = [nil, "", "  ", "und", "unknown", "en", "EN", " en ", "en-US", "en_GB", "eng", "English"]
        for language in hidden {
            #expect(!MiniWizardFlow(captionsEnabled: true, transcriptLanguage: language).showsCaptionLanguage)
        }
        for language in ["pt", "pt-BR", "es", "ar", "Portuguese"] {
            #expect(MiniWizardFlow(captionsEnabled: true, transcriptLanguage: language).showsCaptionLanguage)
            #expect(!MiniWizardFlow(captionsEnabled: false, transcriptLanguage: language).showsCaptionLanguage)
        }
        #expect(!MiniWizardFlow(captionsEnabled: false, transcriptLanguage: "en").showsCaptionLanguage)
    }

    @Test("Initial and source-only states keep later cards collapsed")
    func sourceCard() {
        for video in [nil, Fixtures.video()] {
            let flow = MiniWizardFlow(video: video)
            #expect(flow.openCard == .source)
            #expect(!flow.isCollapsed(.source))
            #expect(flow.isCollapsed(.footage))
            #expect(flow.isCollapsed(.settings))
            #expect(flow.canExpand(.source))
            #expect(!flow.canExpand(.footage))
            #expect(!flow.canExpand(.settings))
            #expect(flow.summary(for: .footage) == "Pick a source first")
            #expect(flow.summary(for: .settings) == "Choose footage first")
            #expect(flow.summary(for: .source) == (video?.filename ?? "Pick a source first"))
        }
    }

    @Test("Cards require their inputs and only the open card expands")
    func cardPrerequisites() {
        for hasSource in [false, true] {
            for hasFootage in [false, true] {
                for hasKeptFootage in [false, true] {
                    for requested in MiniWizardFlow.Card.allCases {
                        let flow = MiniWizardFlow(video: hasSource ? Fixtures.video() : nil,
                                                  hasFootage: hasFootage, hasKeptFootage: hasKeptFootage,
                                                  requestedCard: requested)
                        let canReview = hasSource && hasFootage
                        let canConfigure = canReview && hasKeptFootage
                        let expected: MiniWizardFlow.Card = switch requested {
                        case .source: .source
                        case .footage: canReview ? .footage : .source
                        case .settings: canConfigure ? .settings : canReview ? .footage : .source
                        }
                        #expect(flow.canExpand(.footage) == canReview)
                        #expect(flow.canExpand(.settings) == canConfigure)
                        #expect(flow.openCard == expected)
                        for card in MiniWizardFlow.Card.allCases {
                            #expect(flow.isCollapsed(card) == (card != expected))
                        }
                    }
                }
            }
        }
    }

    @Test("Completed cards can reopen; removing inputs returns to the preceding card")
    func revisitAndInvalidate() {
        var flow = MiniWizardFlow(video: Fixtures.video(), hasFootage: true, hasKeptFootage: true,
                                  requestedCard: .settings)
        #expect(flow.openCard == .settings)
        #expect(flow.summary(for: .footage) == "Review footage")
        #expect(flow.summary(for: .settings) == "Ready to generate")
        flow.requestedCard = .source
        #expect(flow.openCard == .source)
        #expect(flow.isCollapsed(.footage))
        #expect(flow.isCollapsed(.settings))
        flow.requestedCard = .footage
        #expect(flow.openCard == .footage)
        flow.requestedCard = .settings
        flow.hasKeptFootage = false
        #expect(flow.openCard == .footage)
        flow.hasFootage = false
        #expect(flow.openCard == .source)
        flow.hasFootage = true
        flow.hasKeptFootage = true
        flow.video = nil
        #expect(flow.openCard == .source)
    }

    @Test("Output modes preserve separate videos and one reel")
    func outputModes() {
        #expect(MiniWizardFlow.OutputMode.allCases == [.separateVideos, .oneReel])
        #expect(MiniWizardFlow().outputMode == .separateVideos)
        #expect(MiniWizardFlow(outputMode: .oneReel).outputMode == .oneReel)
        #expect(MiniWizardFlow.OutputMode(rawValue: "separateVideos") == .separateVideos)
        #expect(MiniWizardFlow.OutputMode(rawValue: "oneReel") == .oneReel)
    }
}

extension MiniWizardFlowTests {
    @Test func footageSummaryUsesExchangesForQAAndCandidatesForHighlights() {
        #expect(MiniWizardFlow.footageSummary(kind: .qa, count: 4, keptCount: 3) == "4 exchanges · 3 kept")
        #expect(MiniWizardFlow.footageSummary(kind: .qa, count: 0, keptCount: 0) == "0 exchanges · 0 kept")
        #expect(MiniWizardFlow.footageSummary(kind: .highlights, count: 3, keptCount: 2) == "3 candidates · 2 kept")
        var run = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .qa, length: .automatic,
            batchID: "qa", candidates: [], options: WizardOptions(),
            qa: MiniWizardQA(sections: [], rows: [], labels: [:], turns: [], kept: [999]))
        #expect(run.hasFootage && run.keptCount == 0 && run.summary == "0 exchanges · 0 kept")
        var scene = Fixtures.scene()
        scene.tags = ["q&a"]
        run.qa?.sections = TranscriptQASections.sections(scenes: [scene], rows: [], labels: [:])
        run.qa?.kept = [scene.id, 999]
        #expect(run.summary == "1 exchanges · 1 kept")
    }
}

extension MiniWizardFlowTests {
    @Test func generateTitleAndSettingsSummary() {
        let separate = MiniWizardFlow(outputMode: .separateVideos)
        #expect(separate.generateButtonTitle(keptCount: 1) == "Generate Video")
        #expect(separate.generateButtonTitle(keptCount: 3) == "Generate Videos")
        #expect(MiniWizardFlow(outputMode: .oneReel).generateButtonTitle(keptCount: 3) == "Generate Video")
        #expect(separate.outputCount(keptCount: 3) == 3)
        #expect(MiniWizardFlow(outputMode: .oneReel).outputCount(keptCount: 3) == 1)
        #expect(MiniWizardFlow(outputMode: .oneReel).outputCount(keptCount: 0) == 0)
        var settings = MiniWizardSettings()
        settings.captions = true
        #expect(separate.settingsSummary(settings) == "Balanced · 9:16 · 1080p · captions · watermark · separate videos")
        settings.outputMode = .oneReel
        settings.captions = false
        settings.watermark = false
        settings.preset = .landscape4K
        settings.quality = .archival
        #expect(separate.settingsSummary(settings) == "High · 16:9 · 4K · one reel")
    }
}

extension MiniWizardFlowTests {
    @Test func runSummaryUsesKeptTakeNamesOutputModeLengthAndPresentation() {
        func candidate(_ id: Int64, name: String, ordinal: Int, kept: Bool = true) -> MiniWizardCandidate {
            let selection = WizardSelectionRecord(id: id, projectID: 1, name: name, recipe: "custom",
                                                   step1Options: WizardStep1Options())
            let take = WizardSelectionTake(id: id, selectionID: id, ordinal: ordinal,
                                           plan: Fixtures.plan(), sceneIDs: [1])
            return MiniWizardCandidate(selection: selection, take: take, kept: kept)
        }
        let candidates = [candidate(1, name: "Not kept", ordinal: 1, kept: false),
            candidate(2, name: "Guard pass that ended it", ordinal: 2),
            candidate(3, name: "Second", ordinal: 1), candidate(4, name: "Third", ordinal: 1)]
        var settings = MiniWizardSettings()
        settings.captions = true
        let flow = MiniWizardFlow(video: Fixtures.video(), length: .fifteen)
        #expect(flow.runSummary(candidates: candidates, exchangeCount: 0, settings: settings)
            == "3 reels from Guard pass that ended it, Take 2 + 2 more · 15 s · Balanced · 9:16 · 1080p · captions · watermark")
        let single = [candidates[1]]
        #expect(flow.runSummary(candidates: single, exchangeCount: 0, settings: settings).hasPrefix("1 reel from Guard pass that ended it, Take 2 · 15 s"))
        settings.outputMode = .oneReel
        #expect(flow.runSummary(candidates: candidates, exchangeCount: 0, settings: settings).hasPrefix("One reel from Guard pass that ended it, Take 2 + 2 more"))
        #expect(flow.runSummary(candidates: [candidates[0]], exchangeCount: 0, settings: settings) == "No kept footage")
        #expect(MiniWizardFlow(video: Fixtures.video()).runSummary(candidates: single, exchangeCount: 0, settings: settings).contains("Auto length"))
    }

    @Test func runSummaryUsesWholeExchangeCountsAndOmitsDisabledPresentation() {
        let flow = MiniWizardFlow(video: Fixtures.video(), hasPodcastExchangeScenes: true, footageKind: .qa)
        var settings = MiniWizardSettings()
        settings.outputMode = .oneReel
        settings.quality = .archival
        settings.preset = .landscape1080
        settings.watermark = false
        #expect(flow.runSummary(candidates: [], exchangeCount: 4, settings: settings)
            == "One reel from 4 exchanges · High · 16:9 · 1080p")
        settings.outputMode = .separateVideos
        settings.introVideo = true
        settings.outroVideo = true
        settings.nameTags = true
        #expect(flow.runSummary(candidates: [], exchangeCount: 1, settings: settings)
            == "1 reel from 1 exchange · High · 16:9 · 1080p · intro video · outro video · name tags")
        #expect(flow.runSummary(candidates: [], exchangeCount: 4, settings: settings).hasPrefix("4 reels from 4 exchanges"))
        #expect(flow.runSummary(candidates: [], exchangeCount: 0, settings: settings) == "No kept footage")
    }
}


extension MiniWizardFlowTests {
    @Test func tagStyleSurvivesEffectivePodcastSettings() {
        var settings = MiniWizardSettings()
        settings.nameTags = true
        settings.nameTagStyleID = UUID().uuidString
        let podcast = MiniWizardFlow(video: Fixtures.video(), hasPodcastExchangeScenes: true)
        let effective = settings.effective(for: podcast, introAvailable: false, outroAvailable: false)
        #expect(effective.nameTagStyleID == settings.nameTagStyleID)
        #expect(effective.step2Options(base: WizardStep2Options()).nameTagStyleID == settings.nameTagStyleID)
    }
}
