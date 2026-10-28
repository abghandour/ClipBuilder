import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Clip_Builder

@Suite("Wizard preview composite")
struct WizardPreviewCompositeTests {
    @Test func previewTrackingWindowStaysInsideTheActiveSpanAndRecord() {
        #expect(WizardPreviewFraming.trackingWindow(time: 150, range: 100...400) == 148...152)
        #expect(WizardPreviewFraming.trackingWindow(time: 100, range: 100...400) == 100...102)
        #expect(WizardPreviewFraming.trackingWindow(time: 400, range: 100...400) == 398...400)
        #expect(WizardPreviewFraming.trackingWindow(time: 150, range: 100...400, span: 149...151) == 149...151)
        #expect(WizardPreviewFraming.trackingWindow(time: 100, range: 100...400, span: 99...101) == 100...101)
        #expect(WizardPreviewFraming.trackingWindow(time: 400, range: 100...400, span: 399...401) == 399...400)
        #expect(WizardPreviewFraming.trackingWindow(time: 105, range: 100...101) == 100...101)
    }

    @Test func scenePlanningIgnoresCompositeControlsButKeepsPlanningInputs() {
        for subject in Framing.Subject.allCases {
            let framing = Framing(subject: subject)
            let original = WizardPreviewFraming.planningFraming(framing, videoType: .podcast)
            for change: (inout Framing) -> Void in [
                { $0.fit = .blurredFill }, { $0.feather = 0.7 }, { $0.blur = 0.9 }, { $0.lockAspect = false },
            ] {
                var changed = framing
                change(&changed)
                #expect(WizardPreviewFraming.planningFraming(changed, videoType: .podcast) == original)
            }
            for change: (inout Framing) -> Void in [
                { $0.subject = subject == .original ? .centerStage : .original },
                { $0.moves = .cuts }, { $0.focusFrame = FreeCropRect(wFrac: 0.5) },
                { $0.sourceRoles = ["screen": "source"] }, { $0.layout = "PiP" },
            ] {
                var changed = framing
                change(&changed)
                #expect(WizardPreviewFraming.planningFraming(changed, videoType: .podcast) != original)
            }
        }
        for subject in Framing.Subject.allCases {
            for type in [VideoType.podcast, .fight] {
                let original = WizardPreviewFraming.planningFraming(Framing(subject: subject), videoType: type)
                let changed = WizardPreviewFraming.planningFraming(Framing(subject: subject, pullBack: 1), videoType: type)
                let affectsPlanning = subject == .auto || subject == .speakerFocus || (subject == .vipFocus && type == .fight)
                #expect((changed != original) == affectsPlanning)
            }
        }
    }

    @Test func cancelledReloadRetainsTheSceneButCannotCompositeItAsCurrent() async throws {
        let model = WizardPreviewModel(thumbnails: ThumbnailService())
        let record = Fixtures.scene()
        let profile = Fixtures.brand()
        var options = WizardOptions()
        options.framing = Framing(subject: .original)
        await model.loadScene(record, database: nil, people: [], language: nil, tagStyleID: nil,
            profile: profile, options: options)
        let original = try #require(model.scene)
        let revision = model.contentRevision
        #expect(model.isSceneCurrent)

        let reload = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.loadScene(record, database: nil, people: [], language: nil, tagStyleID: nil,
                profile: profile, options: options, time: record.startTime)
        }
        await reload.value
        #expect(model.scene?.time == original.time)
        #expect(model.loadedSceneID == record.id)
        #expect(model.loadedTime == original.time)
        #expect(model.contentRevision == revision)
        #expect(!model.isSceneCurrent && !model.isLoadingScene)
        let key = PreviewKey(options: options, scene: record, profile: profile,
            contentRevision: revision, overlayTexts: [])
        var requestedInput = false
        model.update(key: key) { requestedInput = true; return nil }
        #expect(!requestedInput)

        await model.loadScene(record, database: nil, people: [], language: nil, tagStyleID: nil,
            profile: profile, options: options)
        #expect(model.isSceneCurrent)
        // Rejecting a stale scene must not claim its key and suppress the retry.
        model.update(key: key) { requestedInput = true; return nil }
        #expect(requestedInput)

        var other = record
        other.id += 1
        let changeRecord = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.loadScene(other, database: nil, people: [], language: nil, tagStyleID: nil,
                profile: profile, options: options)
        }
        await changeRecord.value
        #expect(model.scene == nil && model.loadedSceneID == nil && model.loadedTime == nil)
        await model.loadScene(record, database: nil, people: [], language: nil, tagStyleID: nil,
            profile: profile, options: options)
        await model.loadScene(nil, database: nil, people: [], language: nil, tagStyleID: nil,
            profile: profile, options: options)
        #expect(model.scene == nil && model.loadedSceneID == nil && model.loadedTime == nil)
    }

    @Test func namedClusterTurnsUseThePersonsCaptionStyleAndMarkerName() async throws {
        let temp = try TempDatabase()
        let fixture = try await Fixtures.personCorrection(in: temp)
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("UPDATE speaker_turns SET person_key = NULL WHERE video_id = ?", [.integer(fixture.video.id)])
        try raw.execute("UPDATE transcripts SET speaker_key = NULL WHERE video_id = ?", [.integer(fixture.video.id)])
        let clusterTurns = try await temp.database.fetchSpeakerTurns(videoID: fixture.video.id)
        #expect(clusterTurns.allSatisfy { $0.personKey == nil })
        let evidence = await CaptionSpeakerEvidence.load(database: temp.database, videoID: fixture.video.id)

        var input = try input()
        input.options.addCaptions = true
        input.options.nameTags = false
        input.options.captionPosition = nil
        input.scene.time = 1
        input.scene.captionSegment = .init(start: 0, end: 4, text: "A strong moment")
        input.scene.speakerTurns = evidence.turns
        input.scene.speakerRows = evidence.rows
        input.scene.roster = evidence.names
        var speakerStyle = input.profile.captions
        speakerStyle.color = "#ff0000"
        speakerStyle.position = "top"
        let named = NamedCaptionStyle(name: "Guest", style: speakerStyle)
        input.profile.captionStyles = [named]
        input.profile.personCaptionStyles = [fixture.from.key: named.id.uuidString]
        let base = try WizardPreviewComposite.croppedFrame(input)
        let rendered = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base)
        let marker = try #require(rendered.layout.captions.first)
        #expect(rendered.layout.captions.count == 1)
        #expect(marker.personKey == fixture.from.key)
        #expect(marker.name == fixture.from.displayName)
        #expect(marker.isTalking)

        // The named speaker renders identically to selecting their style for the run.
        var expected = input
        expected.profile.personCaptionStyles = nil
        expected.profile.captions = speakerStyle
        let direct = try WizardPreviewComposite.renderWithLayout(expected, baseFrame: base)
        let canvas = CGRect(x: 0, y: 0, width: 640, height: 360)
        #expect(try changedPixels(rendered.image, direct.image, in: canvas) == 0)
        #expect(rendered.layout == direct.layout)
        input.scene.speakerTurns = clusterTurns
        let unnamed = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base)
        #expect(unnamed.layout.captions.first?.name == "Caption")
        #expect(try changedPixels(rendered.image, unnamed.image, in: canvas) > 100)
    }

    @Test func previewMomentUsesSpeakerStyleAndMatchesDirectCaptionRender() throws {
        var input = try input()
        input.options.addCaptions = true
        input.options.nameTags = false
        input.options.captionPosition = nil
        input.scene.time = 5
        input.scene.person = PersonRecord(id: 1, key: "host", name: "Host", descriptor: "")
        input.scene.captionText = "A strong moment"
        input.scene.captionSegment = .init(start: 4, end: 8, text: "A strong moment")
        input.scene.speakerTurns = [
            .init(videoID: 1, start: 0, end: 4, cluster: 0, confidence: 1, personKey: "host"),
            .init(videoID: 1, start: 4, end: 8, cluster: 1, confidence: 1, personKey: "ana")]
        input.profile.captions = CaptionStyle()
        var speakerStyle = input.profile.captions
        speakerStyle.color = "#ff0000"
        speakerStyle.position = "top"
        let named = NamedCaptionStyle(name: "Ana", style: speakerStyle)
        input.profile.captionStyles = [named]
        input.profile.personCaptionStyles = ["ana": named.id.uuidString]
        let base = try WizardPreviewComposite.croppedFrame(input)
        let rendered = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let renderer = CaptionRenderer(videoWidth: 640, videoHeight: 360, style: speakerStyle,
            safeArea: input.options.resolvedSafeArea, safeAreaOnly: input.options.safeAreaOnly == true)
        let caption = try renderer.render(text: "A strong moment", to: folder)
        let origin = renderer.position(for: caption, positionOverride: "auto")
        let source = try #require(CGImageSourceCreateWithURL(caption.pngURL as CFURL, nil))
        let png = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        let canvas = CGRect(x: 0, y: 0, width: 640, height: 360)
        context.draw(base, in: canvas)
        context.draw(png, in: CGRect(x: origin.x, y: 360 - origin.y - caption.height,
                                    width: caption.width, height: caption.height))
        let expected = try #require(context.makeImage())
        #expect(try changedPixels(rendered.image, expected, in: canvas) == 0)
        #expect(rendered.layout.captions.first?.rect == CGRect(x: origin.x, y: origin.y, width: caption.width, height: caption.height))

        var plain = input
        plain.profile.personCaptionStyles = nil
        let fallback = try WizardPreviewComposite.render(plain, baseFrame: base)
        #expect(try changedPixels(rendered.image, fallback, in: canvas) > 100)
        input.scene.speakerRows = [.init(id: 1, videoID: 1, language: "en", isTranslation: false,
            startTime: 4, endTime: 8, text: "A strong moment", speakerKey: "")]
        #expect(try changedPixels(WizardPreviewComposite.render(input, baseFrame: base), fallback, in: canvas) == 0)
    }

    @Test func everyFitControlInvalidatesPreviewPixels() {
        let scene = Fixtures.scene()
        let profile = Fixtures.brand()
        var options = WizardOptions()
        options.framing = Framing(subject: .original)
        let original = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        for framing in [Framing(subject: .original, fit: .blurredFill),
                        Framing(subject: .original, feather: 0.2), Framing(subject: .original, blur: 1)] {
            options.framing = framing
            #expect(PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: []) != original)
        }
    }

    @Test func personCaptionChoicesInvalidatePreviewKeyWithoutAProfileGenerationChange() {
        let scene = Fixtures.scene()
        let options = WizardOptions()
        var profile = Fixtures.brand()
        let original = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        let named = NamedCaptionStyle(name: "Speaker", style: CaptionStyle())
        profile.personCaptionStyles = ["ana": named.id.uuidString]
        let changed = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        #expect(changed != original)
        profile.personCaptionStyles = nil
        #expect(PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: []) == original)
    }

    @Test func fallbackTagPersonPrefersThisVideoRosterThenAnyNamedPerson() {
        let roster = [VideoPersonRecord(videoID: 1, personID: 2, key: "guest", name: "Guest",
            descriptor: "", portraitAt: 0, portraitBox: nil, vip: false)]
        let host = PersonRecord(id: 1, key: "host", name: "Marcello Spinelli", descriptor: "Press")
        let guest = PersonRecord(id: 2, key: "guest", name: "Tanner Boser", descriptor: "")
        let unnamed = PersonRecord(id: 3, key: "guest", name: "", descriptor: "")
        var hiddenGuest = guest
        hiddenGuest.hidden = true
        #expect(WizardPreviewFraming.fallbackPerson(roster: roster, people: [host, guest])?.key == "guest")
        #expect(WizardPreviewFraming.fallbackPerson(roster: roster, people: [host, hiddenGuest])?.key == "host")
        #expect(WizardPreviewFraming.fallbackPerson(roster: [], people: [host, guest])?.key == "host")
        #expect(WizardPreviewFraming.fallbackPerson(roster: roster, people: [unnamed]) == nil)
    }

    @Test func plannedCellWithNoFeedOwnerTagsTheScenePerson() {
        let guest = PersonRecord(id: 2, key: "guest", name: "Tanner Boser", descriptor: "Press")
        var scene = WizardPreviewComposite.Scene(videoURL: URL(fileURLWithPath: "/tmp/preview.mp4"),
            time: 1, faceRect: nil, person: guest, captionText: nil, words: nil)
        let cell = WizardPreviewComposite.Cell(source: WizardPreviewFraming.full, area: WizardPreviewFraming.full)
        scene.framing = .cells([cell])
        let single = WizardPreviewComposite.tagGeometry(scene: scene, canvas: CGSize(width: 1000, height: 1000))
        #expect(single.people.map(\.name) == ["Tanner Boser"] && single.people.map(\.role) == ["Press"])
        // Two unowned cells: only the talking one borrows the scene person.
        var talking = cell; talking.isTalking = true
        scene.framing = .cells([cell, talking])
        let pair = WizardPreviewComposite.tagGeometry(scene: scene, canvas: CGSize(width: 1000, height: 1000))
        #expect(pair.people.map(\.name) == ["Alex Morgan", "Tanner Boser"])
    }

    @Test func vipPreviewShowsGuestWhileHostTalks() throws {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        let guest = VideoPersonRecord(videoID: video.id, personID: 1, key: "guest", name: "Guest",
            descriptor: "", portraitAt: 0, portraitBox: .init(x: 0.7, y: 0.2, w: 0.1, h: 0.3), vip: true)
        let turn = SpeakerTurn(videoID: video.id, start: 0, end: 10, cluster: 0, confidence: 1,
            personKey: "host", tile: 0)
        var scene = Fixtures.scene()
        scene.startTime = 0
        scene.endTime = 10
        var options = WizardOptions()
        options.framing = Framing(subject: .vipFocus)
        let result = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
            turns: [turn], roster: [guest], people: [], layouts: ScreenCropStore.builtIn)
        #expect(result.warning == nil)
        guard case .cells(let cells) = result.framing else { Issue.record("Expected VIP cell"); return }
        #expect(cells.count == 1)
        #expect(cells[0].source.midX > 0.5)
        #expect(!cells[0].isTalking)
        #expect(CameraFocusChooser.allowedSubjects(type: .fight, hasTurns: true, hasVIP: true).contains(.vipFocus))
        #expect(!CameraFocusChooser.allowedSubjects(type: .podcast, hasTurns: true, hasVIP: false).contains(.vipFocus))
    }

    /// The same speaker shots can glide or cut without changing the subject.
    @Test func speakerMovesSwitchBetweenGlidesAndCuts() throws {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.singleCamera.rawValue
        video.duration = 40
        // Far apart: no 9:16 column holds both faces.
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, faceX: 0.24, faceY: 0.28),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, faceX: 0.59, faceY: 0.28)]
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
        let vip = VideoPersonRecord(videoID: video.id, personID: 1, key: "vip", name: "VIP",
            descriptor: "", portraitAt: 5, portraitBox: .init(x: 0.55, y: 0.2, w: 0.08, h: 0.16), vip: true)
        let host = VideoPersonRecord(videoID: video.id, personID: 2, key: "host", name: "Host",
            descriptor: "", portraitAt: 5, portraitBox: .init(x: 0.2, y: 0.2, w: 0.08, h: 0.16), vip: false)
        let turns = [SpeakerTurn(videoID: video.id, start: 0, end: 10, cluster: 1, confidence: 1, personKey: "host", tile: 0),
                     SpeakerTurn(videoID: video.id, start: 10, end: 40, cluster: 0, confidence: 1, personKey: "vip", tile: 1)]
        var scene = Fixtures.scene()
        scene.startTime = 0
        scene.endTime = 40
        var options = WizardOptions()
        options.framing = Framing(subject: .speakerFocus)
        options.framing?.pullBack = 0
        func source(moves: Framing.Moves, at time: Double) -> CGRect? {
            options.framing?.moves = moves
            let result = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
                turns: turns, roster: [vip, host], people: [], layouts: ScreenCropStore.builtIn, time: time)
            guard case .cells(let cells) = result.framing else { Issue.record("Expected cells"); return nil }
            return cells.first?.source
        }
        let smooth = source(moves: .smooth, at: 10.4)
        let cut = source(moves: .cuts, at: 10.4)
        #expect(smooth != cut)
        #expect(cut == source(moves: .cuts, at: 12))
        let profile = Fixtures.brand()
        options.framing?.moves = .smooth
        let before = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        options.framing?.moves = .cuts
        #expect(PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: []) != before)
    }

    /// A moment inside a camera move shows the crop part-way, as the export does.
    @Test func interviewPreviewInterpolatesInsideACameraMove() throws {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.singleCamera.rawValue
        video.duration = 60
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, faceX: 0.46, faceY: 0.28),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, faceX: 0.59, faceY: 0.28)]
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
        let vip = VideoPersonRecord(videoID: video.id, personID: 1, key: "vip", name: "VIP",
            descriptor: "", portraitAt: 5, portraitBox: .init(x: 0.55, y: 0.2, w: 0.08, h: 0.16), vip: true)
        let host = VideoPersonRecord(videoID: video.id, personID: 2, key: "host", name: "Host",
            descriptor: "", portraitAt: 5, portraitBox: .init(x: 0.42, y: 0.2, w: 0.08, h: 0.16), vip: false)
        let turns = [SpeakerTurn(videoID: video.id, start: 0, end: 10, cluster: 1, confidence: 1, personKey: "host", tile: 0),
                     SpeakerTurn(videoID: video.id, start: 10, end: 40, cluster: 0, confidence: 1, personKey: "vip", tile: 1)]
        var scene = Fixtures.scene()
        scene.startTime = 0
        scene.endTime = 40
        var options = WizardOptions()
        options.framing = Framing(subject: .speakerFocus)
        func source(at time: Double) -> CGRect? {
            let result = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
                turns: turns, roster: [vip, host], people: [], layouts: ScreenCropStore.builtIn, time: time)
            guard case .cells(let cells) = result.framing, cells.count == 1 else { Issue.record("Expected one cell"); return nil }
            return cells[0].source
        }
        // The move toward the tight shot starts at 10 s and takes 0.8 s.
        guard let before = source(at: 9.9), let middle = source(at: 10.4), let after = source(at: 12) else { return }
        #expect(before != after)
        #expect(middle != before && middle != after, "half-way through the move the crop is between the two shots")
        #expect(min(before.minX, after.minX) - 0.001 <= middle.minX && middle.minX <= max(before.minX, after.minX) + 0.001)
        #expect(min(before.height, after.height) - 0.001 <= middle.height && middle.height <= max(before.height, after.height) + 0.001)
    }

    /// A kept range narrower than the scene keeps the saved Center Stage path on the scene's clock.
    @Test func keptRangeKeepsTheSavedPathOnTheSceneClock() throws {
        var scene = Fixtures.scene(id: 1, start: 100, end: 160)
        scene.wide = true
        let path = SceneCameraPath(camera: "center_stage", keyframes: [CameraPathKeyframe(t: 0, x: 0.1, y: 0, w: 0.3, h: 1),
                                               CameraPathKeyframe(t: 20, x: 0.1, y: 0, w: 0.3, h: 1),
                                               CameraPathKeyframe(t: 40, x: 0.6, y: 0, w: 0.3, h: 1),
                                               CameraPathKeyframe(t: 60, x: 0.6, y: 0, w: 0.3, h: 1)])
        scene.centerStagePathJSON = String(decoding: try JSONEncoder().encode(path), as: UTF8.self)
        var kept = scene
        kept.startTime = 120
        kept.endTime = 160
        var options = WizardOptions()
        options.framing = Framing(subject: .speakerFocus)
        // Showing 130 s: 30 s into the scene (left shot), not 10 s into the kept range.
        let wrong = WizardPreviewFraming.resolve(options: options, record: kept, video: nil, face: nil,
            turns: [], roster: [], people: [], layouts: ScreenCropStore.builtIn, time: 130)
        let right = WizardPreviewFraming.resolve(options: options, record: kept, video: nil, face: nil,
            turns: [], roster: [], people: [], layouts: ScreenCropStore.builtIn, time: 130, sceneStart: scene.startTime)
        guard case .path(let fixed) = right.framing else { Issue.record("Expected the saved path"); return }
        #expect(fixed.t == 20 || fixed.t == 40, "the nearest keyframe on the scene clock")
        #expect(abs(fixed.x - 0.1) < 0.001 || abs(fixed.x - 0.6) < 0.001)
        if case .path(let shifted) = wrong.framing { #expect(shifted.t != fixed.t || shifted.x != fixed.x) }
    }

    @Test func previewKeyFollowsTheDubLanguageLikeTheRender() {
        var options = WizardOptions()
        options.captionLanguage = "en"
        let scene = Fixtures.scene()
        let profile = Fixtures.brand()
        let english = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        options.dubLanguage = "pt-BR"
        let dubbed = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        #expect(english != dubbed)
        #expect(dubbed.captionLanguage == "pt-BR")
    }

    @Test func interviewPullBackChangesPreviewFramingAndKey() {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.singleCamera.rawValue
        let vip = VideoPersonRecord(videoID: video.id, personID: 1, key: "vip", name: "VIP",
            descriptor: "", portraitAt: 5, portraitBox: .init(x: 0.3, y: 0.2, w: 0.08, h: 0.16), vip: true)
        let host = VideoPersonRecord(videoID: video.id, personID: 2, key: "host", name: "Host",
            descriptor: "", portraitAt: 5, portraitBox: .init(x: 0.55, y: 0.2, w: 0.08, h: 0.16), vip: false)
        let turn = SpeakerTurn(videoID: video.id, start: 0, end: 10, cluster: 0, confidence: 1,
            personKey: "vip", tile: 0)
        var scene = Fixtures.scene()
        scene.startTime = 0
        scene.endTime = 10
        var options = WizardOptions()
        options.framing = Framing(subject: .speakerFocus)
        func cells(zoom: Double) -> [WizardPreviewComposite.Cell]? {
            options.framing?.pullBack = zoom
            let result = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
                turns: [turn], roster: [vip, host], people: [], layouts: ScreenCropStore.builtIn)
            #expect(result.warning == nil, "\(result.warning ?? "")")
            guard case .cells(let cells) = result.framing else { Issue.record("Expected interview cell"); return nil }
            return cells
        }
        guard let tight = cells(zoom: 0), let wide = cells(zoom: 1) else { return }
        #expect(tight.count == 1 && wide.count == 1)
        #expect(wide[0].source.height > tight[0].source.height)
        #expect(abs(wide[0].source.height - 1) < 0.001)
        #expect(WizardPreviewComposite.Framing.cells(tight) != WizardPreviewComposite.Framing.cells(wide))
        let profile = Fixtures.brand()
        options.framing?.pullBack = 0
        let before = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        options.framing?.pullBack = 1
        #expect(PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: []) != before)
    }

    /// The render samples faces in the clip before planning Interview focus;
    /// the preview must plan from the same refined faces or its crop and
    /// name tags land elsewhere than the output's.
    @Test func interviewPreviewPlansFromTheRefinedRosterLikeTheRender() async {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.singleCamera.rawValue
        // Portraits measured elsewhere in the recording: saturated boxes map to nothing.
        let vip = VideoPersonRecord(videoID: video.id, personID: 1, key: "vip", name: "VIP",
            descriptor: "", portraitAt: 500, portraitBox: .init(x: 1, y: 1, w: 1, h: 1), vip: true)
        let host = VideoPersonRecord(videoID: video.id, personID: 2, key: "host", name: "Host",
            descriptor: "", portraitAt: 500, portraitBox: .init(x: 1, y: 1, w: 1, h: 1), vip: false)
        let turn = SpeakerTurn(videoID: video.id, start: 0, end: 10, cluster: 0, confidence: 1, personKey: "vip", tile: 0)
        var scene = Fixtures.scene()
        scene.startTime = 0
        scene.endTime = 10
        var options = WizardOptions()
        options.framing = Framing(subject: .speakerFocus)
        options.framing?.pullBack = 1
        let refinedVIP = CGRect(x: 0.56, y: 0.17, width: 0.06, height: 0.11)
        let refinedHost = CGRect(x: 0.34, y: 0.25, width: 0.07, height: 0.13)
        let refiner: WizardPreviewFraming.RosterRefiner = { _, roster, range, _, _, _ in
            #expect(range == 0...10)
            return InterviewFaceSampling.applying(faces: ["vip": refinedVIP, "host": refinedHost], at: 0.1, to: roster)
        }
        let plain = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
            turns: [turn], roster: [vip, host], people: [], layouts: ScreenCropStore.builtIn)
        let refined = await WizardPreviewFraming.resolveCached(options: options, record: scene, video: video, face: nil,
            turns: [turn], roster: [vip, host], people: [], layouts: ScreenCropStore.builtIn, refine: refiner)
        guard case .cells(let before) = plain.framing, case .cells(let after) = refined.framing else {
            Issue.record("Expected interview cells"); return
        }
        #expect(before.count == 1 && after.count == 1)
        // The crop follows the sampled faces, and the cell carries a sampled
        // face (the two-shot's tile owner) for the tag planner, never the saturated portrait.
        #expect(before[0].source != after[0].source)
        #expect(after[0].face == refinedVIP || after[0].face == refinedHost)
        #expect(before[0].face.map { $0.minX >= 1 } ?? true)
        #expect(WizardPreviewFraming.usesRefinedRoster(options: options))
        options.framing = Framing(subject: .centerStage)
        #expect(!WizardPreviewFraming.usesRefinedRoster(options: options))
    }

    /// The scrubber's moment picks the keyframe inside the plan; the plan
    /// itself still covers the whole kept range, like the render's.
    @Test func interviewPreviewFollowsTheScrubbedMomentAlongTheCameraPath() throws {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.singleCamera.rawValue
        video.duration = 60
        // Two speech feeds on one camera, the host on the left, the VIP on the
        // right: close enough that a 9:16 two-shot holds both faces (a full
        // height column is 0.316 of a 16:9 source), far enough apart that the
        // two-shot is not the tight shot (outside the dead zone).
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, faceX: 0.46, faceY: 0.28),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, faceX: 0.59, faceY: 0.28)]
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
        let vip = VideoPersonRecord(videoID: video.id, personID: 1, key: "vip", name: "VIP",
            descriptor: "", portraitAt: 5, portraitBox: .init(x: 0.55, y: 0.2, w: 0.08, h: 0.16), vip: true)
        let host = VideoPersonRecord(videoID: video.id, personID: 2, key: "host", name: "Host",
            descriptor: "", portraitAt: 5, portraitBox: .init(x: 0.42, y: 0.2, w: 0.08, h: 0.16), vip: false)
        // The host asks for the first ten seconds, then the VIP answers.
        let turns = [SpeakerTurn(videoID: video.id, start: 0, end: 10, cluster: 1, confidence: 1, personKey: "host", tile: 0),
                     SpeakerTurn(videoID: video.id, start: 10, end: 40, cluster: 0, confidence: 1, personKey: "vip", tile: 1)]
        var scene = Fixtures.scene()
        scene.startTime = 0
        scene.endTime = 40
        var options = WizardOptions()
        options.framing = Framing(subject: .speakerFocus)
        func source(at time: Double?) -> CGRect? {
            let result = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
                turns: turns, roster: [vip, host], people: [], layouts: ScreenCropStore.builtIn, time: time)
            guard case .cells(let cells) = result.framing, cells.count == 1 else {
                Issue.record("Expected one cell, got \(result.framing) \(result.warning ?? "")"); return nil
            }
            return cells[0].source
        }
        guard let opening = source(at: 0), let middle = source(at: nil), let answer = source(at: 30) else { return }
        var recipe = CropRecipe(kind: .interview)
        recipe.interviewZoom = 0
        recipe.interviewPunchIn = .talker
        let plan = try? CropRecipePlanner.plan(recipe, video: video, range: 0...40, turns: turns, roster: [vip, host],
            layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
        let detail = "tiles=\(plan?.tiles ?? []) path=\(plan?.slots.first?.path ?? []) notes=\(plan?.notes ?? [])"
        #expect(middle == answer, "the default moment is the middle of the range")
        #expect(opening != answer, "the opening two-shot differs from the tight answer shot \(detail)")
        #expect(opening.minX < answer.minX, "the two-shot reaches toward the host on the left")
    }

    @Test func interviewPullBackChangesAnchoredPreviewWhileInterviewerTalks() throws {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.singleCamera.rawValue
        video.duration = 40
        // Far-apart feeds cannot share a portrait crop, even at full height.
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, faceX: 0.12, faceY: 0.28),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, faceX: 0.88, faceY: 0.28)]
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
        let vip = VideoPersonRecord(videoID: video.id, personID: 1, key: "vip", name: "VIP",
            descriptor: "", portraitAt: 5, portraitBox: .init(x: 0.85, y: 0.2, w: 0.06, h: 0.16), vip: true)
        let host = VideoPersonRecord(videoID: video.id, personID: 2, key: "host", name: "Host",
            descriptor: "", portraitAt: 5, portraitBox: .init(x: 0.09, y: 0.2, w: 0.06, h: 0.16), vip: false)
        let turns = [SpeakerTurn(videoID: video.id, start: 0, end: 10, cluster: 1, confidence: 1, personKey: "host", tile: 0),
                     SpeakerTurn(videoID: video.id, start: 10, end: 40, cluster: 0, confidence: 1, personKey: "vip", tile: 1)]
        var scene = Fixtures.scene()
        scene.startTime = 0
        scene.endTime = 40
        var options = WizardOptions()
        options.framing = Framing(subject: .speakerFocus)
        func source(zoom: Double) -> CGRect? {
            options.framing?.pullBack = zoom
            // Explicitly show the interviewer turn, not the VIP answer at the midpoint.
            let result = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
                turns: turns, roster: [vip, host], people: [], layouts: ScreenCropStore.builtIn, time: 5)
            #expect(result.warning == nil, "\(result.warning ?? "")")
            guard case .cells(let cells) = result.framing, cells.count == 1 else {
                Issue.record("Expected one interview cell"); return nil
            }
            return cells[0].source
        }
        guard let close = source(zoom: 0), let wide = source(zoom: 1) else { return }
        #expect(close.height < CenterStageService.Tuning.conversation.minCropHeightFraction, "0 % is tighter than the conversation crop")
        #expect(close.height >= InterviewFocusPlanning.minimumHeight - 0.001)
        #expect(wide.height > close.height)
        #expect(abs(wide.height - 1) < 0.001)
        #expect(wide.minX < close.minX, "Pull-back reveals more of the interviewer on the left")
    }

    @Test func safeAreaControlsInvalidatePreviewKey() {
        var options = WizardOptions()
        let scene = Fixtures.scene()
        let profile = Fixtures.brand()
        func key() -> PreviewKey {
            PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        }
        let initial = key()
        options.safeAreaOnly = true
        let enabled = key()
        #expect(enabled != initial)
        options.safeAreaPlatforms = [.instagram]
        #expect(key() != enabled)
    }

    @Test func safeAreaOnlyLiftsPreviewCaptionAboveInstagramFooter() async throws {
        var input = try input()
        input.options.renderSettings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        input.options.renderSettings.platformSafeArea.enabled = false
        input.options.safeAreaPlatforms = [.instagram]
        let plain = try await WizardPreviewComposite.render(input)
        input.options.addCaptions = true
        input.options.captionPosition = "bottom"
        let edge = try await WizardPreviewComposite.render(input)
        input.options.safeAreaOnly = true
        let safe = try await WizardPreviewComposite.render(input)
        let footer = CGRect(x: 0, y: 500, width: 360, height: 140)
        #expect(try changedPixels(plain, edge, in: footer) > 10)
        #expect(try changedPixels(plain, safe, in: footer) == 0)
        #expect(try changedPixels(plain, safe, in: CGRect(x: 0, y: 300, width: 360, height: 200)) > 10)
    }

    @Test func bottomCaptionsLeaveTheTopBandUntouched() async throws {
        var input = try input()
        let plain = try await WizardPreviewComposite.render(input)
        input.options.addCaptions = true
        input.options.captionPosition = "bottom"
        let captioned = try await WizardPreviewComposite.render(input)
        #expect(captioned.width == 640 && captioned.height == 360)
        #expect(try changedPixels(plain, captioned, in: CGRect(x: 0, y: 180, width: 640, height: 180)) > 100)
        #expect(try changedPixels(plain, captioned, in: CGRect(x: 0, y: 0, width: 640, height: 120)) == 0)
    }

    /// Bounding box of the pixels that differ between two same-size images, y down.
    private func changedBounds(_ a: CGImage, _ b: CGImage) throws -> CGRect {
        func pixels(_ image: CGImage) throws -> [UInt8] {
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = try #require(context.data)
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        try #require(a.width == b.width && a.height == b.height,
            "changedBounds needs equal sizes: \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
        let lhs = try pixels(a), rhs = try pixels(b)
        var minX = a.width, minY = a.height, maxX = -1, maxY = -1
        for y in 0..<a.height {
            for x in 0..<a.width {
                let offset = (y * a.width + x) * 4
                if lhs[offset..<offset + 3] != rhs[offset..<offset + 3] {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @Test func placedOverlayTextSelectorMatchesWhatThePreviewPaints() async throws {
        // The saved Subject design: centre and size only, no box (legacy single line).
        var subject = TextOverlayItem(text: "Subject asdasd sadasasd asdasda sda")
        subject.fontsize = 194
        subject.fontfamily = "Bebas Neue"
        subject.xFrac = 0.4988
        subject.yFrac = 0.7879
        subject.boxOpacity = 0.5
        subject.unbounded = true
        subject.isDynamic = true
        var input = try input()
        input.options.renderSettings = RenderSettings(preset: .custom, customWidth: 540, customHeight: 960)
        input.templates = [OverlayTemplate(name: "Subject", composition: OverlayComposition(texts: [subject]))]
        input.options.fixedOverlayTemplate = "Subject"
        let base = try await WizardPreviewComposite.prepareBase(input)
        let plain = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base.image)
        let legacy = try #require(plain.layout.overlayComponents.first)
        #expect(legacy.component == .text(0))
        let legacyPaint = try changedBounds(base.image, plain.image)
        #expect(abs(legacy.rect.minX - legacyPaint.minX) <= 1 && abs(legacy.rect.maxX - legacyPaint.maxX) <= 1, "legacy selector matches")
        #expect(abs(legacy.rect.minY - legacyPaint.minY) <= 1 && abs(legacy.rect.maxY - legacyPaint.maxY) <= 1)

        // Resized in the preview: the Express owner stores the box through the options.
        var settings = MiniWizardSettings()
        settings.overlay = true
        settings.overlayTemplate = "Subject"
        settings.overlayEdits.place(.text(0), at: CGRect(x: 0.42, y: 0.52, width: 0.48, height: 0.13))
        let key = PreviewKey(options: settings.previewOptions(profile: input.profile), scene: Fixtures.scene(),
                             profile: input.profile, contentRevision: 0, overlayTexts: [])
        #expect(key.visual.overlayEdits == settings.overlayEdits, "the key carries the edits so the cache cannot serve the old picture")
        input.options.fixedOverlayEdits = settings.previewOptions(profile: input.profile).fixedOverlayEdits
        #expect(input.options.fixedOverlayEdits != nil)
        let placed = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base.image)
        let selector = try #require(placed.layout.overlayComponents.first).rect
        let paint = try changedBounds(base.image, placed.image)
        #expect(abs(selector.minX - paint.minX) <= 1 && abs(selector.maxX - paint.maxX) <= 1, "placed selector shares the painted edges")
        #expect(abs(selector.minY - paint.minY) <= 1 && abs(selector.maxY - paint.maxY) <= 1)
        #expect(selector.width >= 0.48 * 540 - 1 && selector.midX > 0.3 * 540, "the placed width, widened only for a word that cannot fit")
        #expect(selector.height > 0.13 * 960 && selector.minY < 0.6 * 960, "rows wrap below the placed box at the design size")
        #expect(paint.minY < legacyPaint.minY - 100, "the text moved up into the placed box instead of staying on the legacy line")
    }

    @Test func layoutReportsWhereTheDraggableElementsLanded() async throws {
        var input = try input()
        input.options.addCaptions = true
        input.options.captionPosition = CustomPosition(x: 0.5, y: 0.25).string
        input.options.nameTags = true
        input.options.nameTagPosition = CustomPosition(x: 0.5, y: 0.75).string
        input.scene.person = PersonRecord(id: 1, key: "ann", name: "Ann Lee", descriptor: "Host")
        var text = TextOverlayItem()
        text.text = "Subscribe"
        text.unbounded = true
        text.xFrac = 0.5
        text.yFrac = 0.1
        text.wFrac = 0.5
        text.hFrac = 0.1
        input.templates = [OverlayTemplate(name: "Banner", composition: OverlayComposition(texts: [text]))]
        input.options.fixedOverlayTemplate = "Banner"
        input.options.fixedOverlayPosition = CustomPosition(x: 0.5, y: 0.6).string
        let base = try await WizardPreviewComposite.prepareBase(input)
        let rendered = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base.image)
        let caption = try #require(rendered.layout.captions.first?.rect)
        #expect(abs(caption.midX - 320) <= 2 && abs(caption.midY - 90) <= 2, "caption centred on the dragged point")
        let tag = try #require(rendered.layout.tags.first)
        #expect(abs(tag.midX - 320) <= 2, "tag centred on the dragged x")
        #expect(tag.midY > 180 && tag.maxY <= 360, "tag in the lower half, kept inside the canvas")
        let overlay = try #require(rendered.layout.overlay)
        #expect(abs(overlay.midX - 320) <= 1 && abs(overlay.midY - 216) <= 1, "overlay design moved to its point")
        // Without those features the layout is empty.
        var plain = try self.input()
        plain.options.addCaptions = false
        let empty = try WizardPreviewComposite.renderWithLayout(plain, baseFrame: base.image)
        var blank = WizardPreviewComposite.Layout()
        blank.sourceRect = empty.layout.sourceRect
        #expect(empty.layout == blank)
        #expect(empty.layout.sourceRect == CGRect(x: 0, y: 0, width: 640, height: 360))
    }

    @Test func topTrailingNameTagUsesThatCorner() async throws {
        var input = try input()
        let plain = try await WizardPreviewComposite.render(input)
        input.options.nameTags = true
        input.options.nameTagPosition = "topTrailing"
        let tagged = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, tagged, in: CGRect(x: 320, y: 0, width: 320, height: 180)) > 100)
        #expect(try changedPixels(plain, tagged, in: CGRect(x: 0, y: 180, width: 640, height: 180)) == 0)
    }

    @Test func disabledWatermarkLeavesLogoAreaUnchanged() async throws {
        var input = try input()
        let plain = try await WizardPreviewComposite.render(input)
        let logo = FileManager.default.temporaryDirectory.appendingPathComponent("preview-logo-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: logo) }
        try frameData(red: 1).write(to: logo)
        input.profile.logoPath = logo.path
        let disabled = try await WizardPreviewComposite.render(input)
        let corner = CGRect(x: 0, y: 0, width: 200, height: 120)
        #expect(try changedPixels(plain, disabled, in: corner) == 0)
        input.options.includeWatermark = true
        let enabled = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, enabled, in: corner) > 0)
    }

    @Test func portraitCanvasCropsLandscapeFrame() async throws {
        var input = try input()
        input.options.renderSettings.preset = .portrait1080
        let image = try await WizardPreviewComposite.render(input)
        #expect(image.width == 1080 && image.height == 1920)
    }

    @Test func faceCropIsClampedToSourceEdges() {
        let rect = WizardPreviewComposite.coverRect(source: CGSize(width: 640, height: 360),
            canvas: CGSize(width: 1080, height: 1920), face: CGRect(x: 0.9, y: 0.3, width: 0.1, height: 0.2))
        #expect(rect.maxX == 1080)
        #expect(rect.minX < 0 && rect.minY == 0 && rect.height == 1920)
    }

    @Test func expressOptionsUseProfileSafeAreaAndOwnChoices() {
        var profile = Fixtures.brand()
        profile.defaultRenderSettings = RenderSettings(preset: .landscape1080)
        var settings = MiniWizardSettings()
        settings.preset = .square1080
        settings.captions = true
        settings.captionPosition = "top"
        settings.nameTags = true
        settings.watermark = false
        let options = settings.previewOptions(profile: profile)
        #expect(options.renderSettings.preset == .square1080)
        #expect(options.renderSettings.platformSafeArea == profile.defaultRenderSettings.platformSafeArea)
        #expect(options.addCaptions && options.usesNameTags && !options.includeWatermark)
        #expect(options.captionPositionOverride == "top")
    }

    @Test func sourceWordClocksDoNotHideCaptions() async throws {
        var input = try input()
        input.options.addCaptions = true
        input.options.captionPosition = "bottom"
        let expected = try await WizardPreviewComposite.render(input)
        input.scene.words = [
            TranscriptWord(word: "A", start: 120, end: 120.2),
            TranscriptWord(word: "strong", start: 120.2, end: 120.5),
            TranscriptWord(word: "moment", start: 120.5, end: 121),
        ]
        let actual = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(expected, actual, in: CGRect(x: 0, y: 0, width: 640, height: 360)) == 0)
    }

    @Test func expressRememberedSettingsNeverInheritWizardBranding() throws {
        let suite = "WizardPreview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("none", forKey: "wizard.brandingMode")
        let profile = Fixtures.brand()
        #expect(MiniWizardSettings.remembered(profile: profile, defaults: defaults).watermark)
        var own = MiniWizardSettings()
        own.watermark = false
        own.remember(profileName: profile.profileName, defaults: defaults)
        #expect(!MiniWizardSettings.remembered(profile: profile, defaults: defaults).watermark)
    }

    @Test func overlayUsesItsStartAndWatermarkTemplateHonorsZeroOpacity() async throws {
        var input = try input()
        let plain = try await WizardPreviewComposite.render(input)
        var text = TextOverlayItem()
        text.text = "Preview overlay"
        text.unbounded = true
        input.templates = [OverlayTemplate(name: "Preview", composition: OverlayComposition(texts: [text]))]
        input.options.fixedOverlayTemplate = "Preview"
        input.options.fixedOverlayStart = 12
        let frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let overlay = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, overlay, in: frame) > 0)
        input.options.fixedOverlayDuration = 0
        let disabledOverlay = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, disabledOverlay, in: frame) == 0)
        input.options.fixedOverlayTemplate = nil
        input.options.includeWatermark = true
        input.options.watermarkOverlayTemplate = "Preview"
        input.options.watermarkOpacity = 0
        let invisibleWatermark = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, invisibleWatermark, in: frame) == 0)
    }

    @Test func previewKeyIgnoresAudioAndQualityButTracksVisuals() {
        var options = WizardOptions()
        let scene = Fixtures.scene()
        let profile = Fixtures.brand()
        let original = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        options.useMusic.toggle()
        options.muteSource.toggle()
        options.renderSettings.quality = .archival
        #expect(PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: []) == original)
        options.captionPosition = "top"
        #expect(PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: []) != original)
        #expect(PreviewKey(options: WizardOptions(), scene: scene, profile: profile,
                           contentRevision: 0, overlayTexts: ["Changed"]) != original)
    }

    @Test func originalFocusPixelsAndHandleUseTheSameSourceTransform() async throws {
        var input = try input()
        // Custom sizes clamp at 240 wide, so stay above that.
        input.options.renderSettings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        input.options.framing = Framing(subject: .original, focusFrame: FreeCropRect(xFrac: 0.5, wFrac: 0.5))
        input.scene.framing = .original
        input.scene.sourceSize = CGSize(width: 960, height: 540)
        let directory = try TempDirectory()
        let png = directory.url.appendingPathComponent("focus.png")
        // The left half is black; only the selected right half contributes pixels.
        let source = try FitTestImage.context(width: 960, height: 540)
        source.setFillColor(CGColor(gray: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
        source.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1))
        source.fill(CGRect(x: 480, y: 0, width: 480, height: 540))
        try FitTestImage.write(try #require(source.makeImage()), to: png)
        input.frameData = try Data(contentsOf: png)
        let base = try WizardPreviewComposite.croppedFrame(input)
        let rendered = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base)
        let whole = try #require(rendered.layout.sourceRect)
        let frame = try #require(input.options.framing?.focusFrame)
        let handle = CGRect(x: whole.minX + frame.xFrac * whole.width, y: whole.minY + frame.yFrac * whole.height,
            width: frame.wFrac * whole.width, height: frame.hFrac * whole.height)
        let black = try FitTestImage.context(width: 360, height: 640)
        black.setFillColor(CGColor(gray: 0, alpha: 1))
        black.fill(CGRect(x: 0, y: 0, width: 360, height: 640))
        let blackImage = try #require(black.makeImage())
        #expect(try changedBounds(base, blackImage) == handle)
        #expect(handle == CGRect(x: 0, y: 0, width: 360, height: 640))
    }

    @Test func changingFocusFrameInvalidatesBothPreviewCaches() async throws {
        var input = try input()
        input.options.lookPreset = "none"
        input.options.framing = Framing(subject: .original, focusFrame: FreeCropRect(xFrac: 0, wFrac: 0.5))
        input.scene.framing = .original
        input.frameData = try frameData(red: 1, split: true)
        let model = WizardPreviewModel(thumbnails: ThumbnailService())
        let record = Fixtures.scene()
        func key(_ value: WizardPreviewComposite.Input) -> PreviewKey {
            PreviewKey(options: value.options, scene: record, profile: value.profile, contentRevision: 1, overlayTexts: [])
        }
        let first = key(input)
        model.update(key: first) { input }
        for _ in 0..<200 where model.isRendering { try await Task.sleep(for: .milliseconds(25)) }
        let left = try #require(model.image)
        input.options.framing?.focusFrame = FreeCropRect(xFrac: 0.5, wFrac: 0.5)
        let second = key(input)
        #expect(second != first)
        model.update(key: second) { input }
        for _ in 0..<200 where model.isRendering { try await Task.sleep(for: .milliseconds(25)) }
        let right = try #require(model.image)
        #expect(model.error == nil && !model.isRendering)
        #expect(try changedPixels(left, right, in: CGRect(x: 0, y: 0, width: right.width, height: right.height)) > 100)
        model.cancel()
    }

    @Test func originalIgnoresFacesAndSavedPaths() async throws {
        var input = try input()
        input.frameData = try frameData(red: 1, split: true)
        input.options.renderSettings = RenderSettings(preset: .custom, customWidth: 180, customHeight: 320)
        input.scene.framing = .original
        let plain = try await WizardPreviewComposite.render(input)
        let face = CGRect(x: 0.8, y: 0.2, width: 0.1, height: 0.1)
        let path = SceneCameraPath(camera: "test", keyframes: [.init(t: 0, x: 0.5, y: 0, w: 0.5, h: 1)])
        input.scene.faceRect = face
        input.scene.framing = WizardPreviewFraming.talker(original: true, path: path, wide: true, time: 0, face: face)
        let original = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, original, in: CGRect(x: 0, y: 0, width: 180, height: 320)) == 0)
        input.scene.framing = WizardPreviewFraming.talker(original: false, path: nil, wide: true, time: 0, face: face)
        let talker = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(original, talker, in: CGRect(x: 0, y: 0, width: 180, height: 320)) > 0)
    }

    @Test func savedPathUsesSceneLocalTimeAndOnlyWideContent() {
        let early = CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.5, h: 1)
        let late = CameraPathKeyframe(t: 8, x: 0.5, y: 0, w: 0.5, h: 1)
        let path = SceneCameraPath(camera: "test", keyframes: [early, late])
        #expect(WizardPreviewFraming.talker(original: false, path: path, wide: true, time: 7, face: nil) == .path(late))
        #expect(WizardPreviewFraming.talker(original: false, path: path, wide: false, time: 7, face: nil) == .cover(face: nil))
    }

    @Test func gridDrawsEachFeedInItsOwnCell() async throws {
        var input = try input()
        input.frameData = try frameData(red: 1, split: true)
        var video = Fixtures.video()
        video.width = 640
        video.height = 360
        video.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        // A left/right Screen Crop makes each source colour directly observable.
        let layout = ScreenCropLayout(name: "Preview columns", areas: [
            ScreenCropArea(name: "Left", points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 0.5, y: 1), .init(x: 0, y: 1)]),
            ScreenCropArea(name: "Right", points: [.init(x: 0.5, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0.5, y: 1)]),
        ])
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .grid, layout: layout.name), video: video,
            range: 0...10, turns: [], roster: [], layouts: [layout], canvasAspect: 640.0 / 360)
        let cells = WizardPreviewFraming.cells(plan: plan, layouts: [layout], video: video,
            time: 1, rangeStart: 0, roster: [], people: [], canvasAspect: 640.0 / 360)
        #expect(cells.count == 2)
        input.scene.framing = .cells(cells)
        let grid = try await WizardPreviewComposite.render(input)
        let expected = try #require(CGImageSourceCreateWithData(input.frameData as CFData, nil))
        let source = try #require(CGImageSourceCreateImageAtIndex(expected, 0, nil))
        #expect(try changedPixels(source, grid, in: CGRect(x: 10, y: 10, width: 300, height: 340)) == 0)
        #expect(try changedPixels(source, grid, in: CGRect(x: 330, y: 10, width: 300, height: 340)) == 0)
        let geometry = WizardPreviewComposite.tagGeometry(scene: input.scene, canvas: CGSize(width: 640, height: 360))
        #expect(geometry.areas.map(\.rect) == [CGRect(x: 0, y: 0, width: 320, height: 360), CGRect(x: 320, y: 0, width: 320, height: 360)])
    }

    @Test func talkerOnTiledRecordingShowsTheTalkingFeedFullScreen() throws {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        var turn = SpeakerTurn(videoID: video.id, start: 5, end: 10, cluster: 1, confidence: 1)
        turn.tile = 1
        var scene = Fixtures.scene()
        scene.startTime = 4
        scene.endTime = 10
        var options = WizardOptions()
        options.framing = Framing(subject: .speakerFocus)
        let resolved = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
            turns: [turn], roster: [], people: [], layouts: ScreenCropStore.builtIn)
        #expect(resolved.warning == nil)
        guard case .cells(let cells) = resolved.framing else {
            Issue.record("talker on a tiled recording should use the recipe plan, got \(resolved.framing)")
            return
        }
        #expect(cells.count == 1)
        #expect(cells[0].area == WizardPreviewFraming.full)
        #expect(cells[0].source.midX > 0.5 && cells[0].source.width <= 0.5)
        // "Let AI choose" resolves the same way for the preview.
        options.framing = Framing()
        if case .cells = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
            turns: [turn], roster: [], people: [], layouts: ScreenCropStore.builtIn).framing {} else {
            Issue.record("nil framing should preview as talker on a tiled recording")
        }
        // Original keeps the whole recording.
        options.framing = Framing(subject: .original)
        if case .original = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
            turns: [turn], roster: [], people: [], layouts: ScreenCropStore.builtIn).framing {} else {
            Issue.record("original should keep the whole source")
        }
    }

    @Test func recipePathSwitchesAtTheCutAndFindsTalkingCell() throws {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        var turn = SpeakerTurn(videoID: video.id, start: 5, end: 10, cluster: 1, confidence: 1)
        turn.tile = 1
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .talkerAndPrevious), video: video,
            range: 4...10, turns: [turn], roster: [], layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
        let cells = WizardPreviewFraming.cells(plan: plan, layouts: ScreenCropStore.builtIn, video: video,
            time: 7, rangeStart: 4, roster: [], people: [], canvasAspect: 9.0 / 16)
        #expect(cells.count == 2)
        #expect(cells[0].source.midX > 0.5)
        #expect(cells[0].isTalking)
        #expect(cells[1].source.midX < 0.5)
    }

    @Test func unavailableRecipeFallsBackToTalkerWithReason() {
        var options = WizardOptions()
        options.framing = Framing(subject: .layout)
        let face = CGRect(x: 0.7, y: 0.1, width: 0.1, height: 0.2)
        let result = WizardPreviewFraming.resolve(options: options, record: Fixtures.scene(), video: Fixtures.video(),
            face: face, turns: [], roster: [], people: [], layouts: ScreenCropStore.builtIn)
        if case .cells(let cells) = result.framing { #expect(cells.count == 2) }
        else { Issue.record("A layout with no people still honors its areas") }
        #expect(result.warning?.contains("No VIP") == true)
        let missing = WizardPreviewFraming.resolve(options: options, record: Fixtures.scene(), video: nil,
            face: face, turns: [], roster: [], people: [], layouts: [])
        #expect(missing.framing == .cover(face: face))
        #expect(missing.warning?.contains("analyze it first") == true)
        var split = Fixtures.video()
        split.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        options.framing = Framing(subject: .speakerFocus)
        let noTurns = WizardPreviewFraming.resolve(options: options, record: Fixtures.scene(), video: split,
            face: face, turns: [], roster: [], people: [], layouts: ScreenCropStore.builtIn)
        #expect(noTurns.framing == .cover(face: face))
        #expect(noTurns.warning?.contains("No speaker turns") == true)
    }

    @Test func cellFacesMapToTheirOwnCanvasAreaAndTagTextDoesNotChangePixelsKey() {
        let cell = WizardPreviewComposite.Cell(source: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
            area: CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
            face: CGRect(x: 0.7, y: 0.2, width: 0.1, height: 0.2))
        var scene = WizardPreviewComposite.Scene(videoURL: URL(fileURLWithPath: "/tmp/preview.mp4"),
            time: 1, faceRect: nil, person: nil, captionText: nil, words: nil)
        scene.sourceSize = CGSize(width: 4000, height: 1000)
        scene.framing = .cells([cell])
        let geometry = WizardPreviewComposite.tagGeometry(scene: scene, canvas: CGSize(width: 1000, height: 1000))
        let face = geometry.areas.first?.spans.first?.faceBox
        #expect(abs((face?.minX ?? 0) - 400) < 0.001)
        #expect(face?.minY == 600 && face?.width == 200 && face?.height == 100)
        var talking = cell
        talking.isTalking = true
        #expect(WizardPreviewFraming.pixelFraming(.cells([cell])) == WizardPreviewFraming.pixelFraming(.cells([talking])))
    }

    @Test func noLookMatchesUngradedBase() async throws {
        var input = try input()
        input.frameData = try frameData(red: 1, split: true)
        input.options.lookPreset = "none"
        let ungraded = try WizardPreviewComposite.croppedFrame(input)
        let base = try await WizardPreviewComposite.prepareBase(input)
        #expect(base.error == nil)
        #expect(try changedPixels(ungraded, base.image, in: CGRect(x: 0, y: 0, width: 640, height: 360)) == 0)
    }

    @Test(.enabled(if: FFmpeg.isAvailable, "ffmpeg is required for Look grading"))
    func halfIntensityLookChangesPixels() async throws {
        var input = try input()
        input.frameData = try frameData(red: 1, split: true)
        let plain = try WizardPreviewComposite.croppedFrame(input)
        input.options.lookPreset = "bw"
        input.options.lookIntensity = 0.5
        #expect(WizardEngine.lookEffect(for: input.options) != nil)
        let base = try await WizardPreviewComposite.prepareBase(input)
        #expect(base.error == nil)
        #expect(try changedPixels(plain, base.image, in: CGRect(x: 0, y: 0, width: 640, height: 360)) > 1000)
        // A graded frame decoded lazily from a deleted scratch file draws black.
        #expect(try meanBrightness(base.image) > 40)
    }

    private func meanBrightness(_ image: CGImage) throws -> Double {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)
        var total = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            total += Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
        }
        return Double(total) / Double(image.width * image.height * 3)
    }

    @Test func previewKeyTracksLookStrengthAndCamera() {
        let scene = Fixtures.scene(), profile = Fixtures.brand()
        var options = WizardOptions()
        func key() -> PreviewKey {
            PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        }
        let plain = key()
        options.lookPreset = "bw"
        let look = key()
        #expect(look != plain)
        options.lookIntensity = 0.5
        #expect(key() != look)
        let graded = key()
        options.framing = Framing(subject: .layout)
        #expect(key() != graded)
    }

    @Test func threeStackPaintsThreeIndependentSourceBands() throws {
        var input = try input()
        input.options.framing = Framing(subject: .layout, layout: "Three stack")
        let layout = try #require(ScreenCropStore.builtIn.first { $0.name == "Three stack" })
        let cells = layout.areas.enumerated().map { index, area in
            let box = area.bounds
            return WizardPreviewComposite.Cell(source: CGRect(x: 0, y: 0, width: 1, height: 1),
                area: CGRect(x: box.x, y: box.y, width: box.w, height: box.h),
                sourcePath: "/tmp/area-\(index).mp4", sourceTime: 0, mask: area, role: area.role)
        }
        input.scene.framing = .cells(cells)
        for (index, cell) in cells.enumerated() {
            input.cellFrames[cell.frameKey] = try frameData(red: CGFloat(index + 1) / 3)
        }
        let painted = try WizardPreviewComposite.croppedFrame(input)
        let samples = try [60, 180, 300].map { y in try FitTestImage.pixel(painted, x: 320, y: y)[0] }
        #expect(Set(samples).count == 3)
        #expect(samples.max()! - samples.min()! >= 150)
    }

    private func input() throws -> WizardPreviewComposite.Input {
        var options = WizardOptions()
        options.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        options.includeWatermark = false
        return .init(scene: .init(videoURL: URL(fileURLWithPath: "/tmp/preview.mp4"), time: 1,
                                  faceRect: nil, person: nil, captionText: "A strong moment", words: nil),
                     options: options, profile: Fixtures.brand(), templates: [], frameData: try frameData())
    }

    private func frameData(red: CGFloat = 0.1, split: Bool = false) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        if split {
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 320, y: 0, width: 320, height: 360))
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Rasterize both into the same byte layout; y=0 is the top of the image.
    private func changedPixels(_ a: CGImage, _ b: CGImage, in rect: CGRect) throws -> Int {
        func pixels(_ image: CGImage) throws -> [UInt8] {
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = try #require(context.data)
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        let left = try #require(a.cropping(to: rect))
        let right = try #require(b.cropping(to: rect))
        let lhs = try pixels(left), rhs = try pixels(right)
        var count = 0
        var opaque = true
        for offset in stride(from: 0, to: lhs.count, by: 4) {
            if lhs[offset..<offset + 3] != rhs[offset..<offset + 3] {
                opaque = opaque && rhs[offset + 3] == 255
                count += 1
            }
        }
        #expect(opaque)
        return count
    }
}

extension WizardPreviewCompositeTests {
    @Test func interviewerPunchInPreviewCutsToTheQuestionAndBack() async throws {
        var video = Fixtures.video()
        video.width = 1920; video.height = 1080; video.duration = 30
        video.podcastLayout = PodcastLayout.singleCamera.rawValue
        let guest = VideoPersonRecord(videoID: video.id, personID: 1, key: "guest", name: "Guest",
            descriptor: "", portraitAt: 0, portraitBox: .init(x: 0.34, y: 0.2, w: 0.04, h: 0.1), vip: true)
        let host = VideoPersonRecord(videoID: video.id, personID: 2, key: "host", name: "Host",
            descriptor: "", portraitAt: 0, portraitBox: .init(x: 0.52, y: 0.2, w: 0.04, h: 0.1), vip: false)
        let turns = [SpeakerTurn(videoID: video.id, start: 0, end: 10, cluster: 0, confidence: 1, personKey: "guest", tile: 0),
                     SpeakerTurn(videoID: video.id, start: 10, end: 20, cluster: 1, confidence: 1, personKey: "host", tile: 1),
                     SpeakerTurn(videoID: video.id, start: 20, end: 30, cluster: 0, confidence: 1, personKey: "guest", tile: 0)]
        var scene = Fixtures.scene()
        scene.startTime = 0; scene.endTime = 30
        var options = WizardOptions()
        options.framing = Framing(subject: .speakerFocus)
        options.framing?.moves = .cuts
        func source(at time: Double) throws -> CGRect {
            let result = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
                turns: turns, roster: [guest, host], people: [], layouts: [], time: time)
            guard case .cells(let cells) = result.framing else {
                throw TestError.expectedCells
            }
            return try #require(cells.first).source
        }
        let opening = try source(at: 0)
        #expect(try source(at: 9.995) == opening)
        let question = try source(at: 10)
        #expect(abs(question.midX - 0.54) < 0.001 && question != opening)
        #expect(try source(at: 19.995) == question)
        #expect(try source(at: 20) == opening)
        let profile = Fixtures.brand()
        let cuts = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        options.framing?.moves = .smooth
        #expect(PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: []) != cuts)
        options.framing?.moves = .cuts
        options.framing?.pullBack = 0.4
        #expect(PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: []) != cuts)
        options.framing?.pullBack = 0
        let refiner: WizardPreviewFraming.RosterRefiner = { _, roster, _, _, punchIn, cuts in
            #expect(punchIn == .talker && cuts)
            return roster
        }
        let cached = await WizardPreviewFraming.resolveCached(options: options, record: scene, video: video, face: nil,
            turns: turns, roster: [guest, host], people: [], layouts: [], refine: refiner, time: 10)
        guard case .cells(let cells) = cached.framing else { throw TestError.expectedCells }
        #expect(cells.first?.source == question)
    }

    private enum TestError: Error { case expectedCells }
}

extension WizardPreviewCompositeTests {
    @Test func shownSpeakersHaveIndependentPositionsAndTalkingCaptionIsOnTop() throws {
        var input = try input()
        input.options.addCaptions = true
        input.options.nameTags = false
        input.options.captionPosition = "bottom"
        input.options.speakerCaptionPositions = ["speaker1": "top", "speaker2": "bottom"]
        input.scene.time = 1
        input.scene.speakerTurns = [
            .init(videoID: 1, start: 0, end: 2, cluster: 0, confidence: 1, personKey: "ana"),
            .init(videoID: 1, start: 2, end: 4, cluster: 1, confidence: 1, personKey: "bob")]
        input.scene.roster = ["ana": "Ana", "bob": "Bob"]
        input.shownSpeakers = ["ana", "bob", "missing"]
        let base = try WizardPreviewComposite.croppedFrame(input)
        let result = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base)
        #expect(result.layout.captions.count == 2)
        let ana = try #require(result.layout.captions.first { $0.personKey == "ana" })
        let bob = try #require(result.layout.captions.first { $0.personKey == "bob" })
        #expect(ana.isTalking && !bob.isTalking)
        #expect(ana.name == "Ana" && bob.name == "Bob")
        #expect(ana.rect.midY < bob.rect.midY)
        #expect(result.layout.captions.last?.personKey == "ana")
        input.shownSpeakers = nil
        let single = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base)
        #expect(single.layout.captions == [ana])
        // Chips decide: an unticked talker is hidden, an empty set hides every person.
        input.shownSpeakers = ["bob"]
        #expect(try WizardPreviewComposite.renderWithLayout(input, baseFrame: base).layout.captions == [bob])
        input.shownSpeakers = []
        #expect(try WizardPreviewComposite.renderWithLayout(input, baseFrame: base).layout.captions.isEmpty)
        input.shownSpeakers = ["ana", "bob"]
        input.options.speakerCaptionPositions = ["speaker1": "middle", "speaker2": "middle"]
        let overlapping = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base)
        #expect(overlapping.layout.captions.count == 2)
        #expect(overlapping.layout.captions.last?.personKey == "ana")
    }

    @Test func previewUsesWholeRunOrdinalsAndUnknownSpeechUsesRunCaption() throws {
        var input = try input()
        input.options.addCaptions = true
        input.options.nameTags = false
        input.options.captionPosition = "bottom"
        input.options.speakerCaptionPositions = ["speaker1": "bottom", "speaker3": "top"]
        input.scene.speakerTurns = [.init(videoID: 2, start: 0, end: 3, cluster: 0, confidence: 1, personKey: "ana")]
        input.scene.roster = ["ana": "Ana"]
        input.scene.captionOrdinals = ["earlier": 1, "another": 2, "ana": 3]
        let base = try WizardPreviewComposite.croppedFrame(input)
        let mapped = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base)
        input.scene.captionOrdinals = nil
        let local = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base)
        let mappedBox = try #require(mapped.layout.captions.first)
        let localBox = try #require(local.layout.captions.first)
        #expect(mappedBox.rect.midY < localBox.rect.midY)
        input.scene.speakerRows = [.init(id: 1, videoID: 2, language: "en", isTranslation: false,
            startTime: 0, endTime: 3, text: "Unknown", speakerKey: "")]
        let unknown = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base)
        #expect(unknown.layout.captions.count == 1)
        #expect(unknown.layout.captions.first?.personKey == nil)
        #expect(unknown.layout.captions.first?.name == "Caption")
    }

    @Test func positionsShownSpeakersAndSourceOrdinalsInvalidatePreviewCache() {
        let scene = Fixtures.scene(), profile = Fixtures.brand()
        var options = WizardOptions()
        let original = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        options.speakerCaptionPositions = ["speaker1": "top"]
        let positioned = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        #expect(original != positioned)
        let shown = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0,
            overlayTexts: [], shownSpeakers: ["ana", "bob"])
        #expect(shown != positioned)
        #expect(shown == PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0,
            overlayTexts: [], shownSpeakers: ["bob", "ana"]))
        #expect(shown != PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0,
            overlayTexts: [], shownSpeakers: ["ana", "bob"], captionOrdinals: ["ana": 2, "bob": 1]))
    }
}
