import Foundation
import CoreGraphics
import CoreText
import ImageIO
import Testing
@testable import Clip_Builder

@Suite("Persistent name tags")
struct NameTagPlannerTests {
    private let people = [NameTagPlanner.Person(key: "ann", name: "Ann", role: "Host"),
                          NameTagPlanner.Person(key: "bob", name: "Bob")]
    private let frame = CGRect(x: 0, y: 0, width: 1080, height: 1920)

    @Test func stillAreasKeepOneTagPerIdentifiedPersonThroughoutTheCut() {
        let areas = [
            NameTagPlanner.Area(rect: CGRect(x: 0, y: 0, width: 1080, height: 960),
                                spans: [.init(start: 0, end: 10, personKey: "ann")]),
            NameTagPlanner.Area(rect: CGRect(x: 0, y: 960, width: 1080, height: 960),
                                spans: [.init(start: 0, end: 10, personKey: "bob")]),
        ]
        let tags = NameTagPlanner.plan(areas: areas, people: people, settings: .init())
        #expect(tags.map(\.personKey) == ["ann", "bob"])
        #expect(tags.allSatisfy { $0.corner == .bottomLeading })
        #expect(tags.allSatisfy { $0.start == 0 && $0.end == 10 && $0.areaRect.contains($0.rect) })
    }

    @Test func rotatingCellSwitchesAtExactCutsAndUnnamedFeedsHaveNoTag() {
        let area = NameTagPlanner.Area(rect: frame, spans: [
            .init(start: 0, end: 3, personKey: "ann"), .init(start: 3, end: 5, personKey: "bob"),
            .init(start: 5, end: 6, personKey: nil), .init(start: 6, end: 8, personKey: "unknown"),
            .init(start: 8, end: 10, personKey: "ann"),
        ])
        let tags = NameTagPlanner.plan(areas: [area], people: people, settings: .init())
        #expect(tags.map(\.personKey) == ["ann", "bob", "ann"])
        #expect(tags.map(\.start) == [0, 3, 8] && tags.map(\.end) == [3, 5, 10])
    }

    @Test func autoAvoidsBothExpandedFaceAndCaptionBand() throws {
        let face = CGRect(x: 0, y: 0, width: 600, height: 400)
        let captions = CGRect(x: 0, y: 1650, width: 1080, height: 270)
        let area = NameTagPlanner.Area(rect: frame, spans: [.init(start: 0, end: 5, personKey: "ann", faceBox: face)])
        let tag = try #require(NameTagPlanner.plan(areas: [area], people: people,
            settings: .init(captionBand: captions)).first)
        #expect(tag.corner == .topTrailing)
        #expect(!tag.rect.intersects(captions))
        let smallFace = CGRect(x: 30, y: 30, width: 160, height: 200)
        let clearArea = NameTagPlanner.Area(rect: frame, spans: [.init(start: 0, end: 5, personKey: "ann", faceBox: smallFace)])
        let clear = try #require(NameTagPlanner.plan(areas: [clearArea], people: people,
            settings: .init(captionBand: captions)).first)
        #expect(!clear.rect.intersects(smallFace.insetBy(dx: -24, dy: -30)))
        #expect(!clear.rect.intersects(captions) && clear.corner == .topTrailing)
    }

    @Test func explicitCornersAreRelativeToAreaAndWidthIsCapped() throws {
        let rect = CGRect(x: 400, y: 600, width: 500, height: 700)
        let area = NameTagPlanner.Area(rect: rect, spans: [.init(start: 0, end: 5, personKey: "ann")])
        for corner in NameTagPlanner.Corner.allCases {
            let tag = try #require(NameTagPlanner.plan(areas: [area], people: people,
                settings: .init(position: corner.rawValue)).first)
            #expect(tag.corner == corner && rect.contains(tag.rect))
            #expect(tag.rect.width <= rect.width * 0.6)
            if corner == .topLeading || corner == .bottomLeading { #expect(tag.rect.minX == rect.minX + 20) }
            else { #expect(abs(tag.rect.maxX - (rect.maxX - 20)) < 0.001) }
            if corner == .topLeading || corner == .topTrailing { #expect(tag.rect.minY == rect.minY + 20) }
            else { #expect(abs(tag.rect.maxY - (rect.maxY - 20)) < 0.001) }
        }
    }

    @Test func onlyAutoClampsIntoThePlatformSafeRectangle() throws {
        let safe = CGRect(x: 0, y: 250, width: 896, height: 1170)
        let area = NameTagPlanner.Area(rect: frame, spans: [.init(start: 0, end: 5, personKey: "ann")])
        for corner in NameTagPlanner.Corner.allCases {
            let tag = try #require(NameTagPlanner.plan(areas: [area], people: people,
                settings: .init(position: corner.rawValue, safeRect: safe)).first)
            let withoutPlatforms = try #require(NameTagPlanner.plan(areas: [area], people: people,
                settings: .init(position: corner.rawValue)).first)
            #expect(tag.rect == withoutPlatforms.rect)
            #expect(!safe.contains(tag.rect) && frame.contains(tag.rect))
        }
        for position in [nil, "auto"] {
            let tag = try #require(NameTagPlanner.plan(areas: [area], people: people,
                settings: .init(position: position, safeRect: safe)).first)
            #expect(safe.contains(tag.rect) && frame.contains(tag.rect))
        }
    }

    @Test func contentAndTemplateStyleProduceHardCutLiteralText() throws {
        let area = NameTagPlanner.Area(rect: frame, spans: [.init(start: 0, end: 5, personKey: "ann")])
        let name = try #require(NameTagPlanner.plan(areas: [area], people: people, settings: .init()).first)
        let role = try #require(NameTagPlanner.plan(areas: [area], people: people,
            settings: .init(content: "nameAndRole")).first)
        #expect(name.lines == ["Ann"] && role.lines == ["Ann", "Host"])
        let bob = NameTagPlanner.Area(rect: frame, spans: [.init(start: 0, end: 5, personKey: "bob")])
        #expect(NameTagPlanner.plan(areas: [bob], people: people, settings: .init(content: "nameAndRole")).first?.lines == ["Bob"])
        var template = TextOverlayItem(text: "Replace")
        template.fontfamily = "Menlo"
        template.fontcolor = "#ABCDEF"
        template.bgcolor = "#123456"
        template.strokeColor = "black"
        template.strokeWidthEm = 0.04
        let styled = try #require(NameTagPlanner.plan(areas: [area], people: people,
            settings: .init(content: "nameAndRole"), template: template).first)
        let overlay = NameTagPlanner.overlay(styled, canvas: frame.size, template: template)
        #expect(overlay.text == "Ann\nHost" && overlay.design == "nameTag")
        #expect(overlay.fontfamily == template.fontfamily && overlay.fontcolor == template.fontcolor)
        #expect(overlay.bgcolor == template.bgcolor && overlay.strokeWidthEm == template.strokeWidthEm)
        #expect(overlay.transIn == "cut" && overlay.transOut == "cut" && overlay.endTime == 5)
    }

    @Test func actualRecipeSlotsDriveStillAndMovingTags() throws {
        let video = try CropRecipeTests.video(tiles: [
            PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "ann"),
            PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "bob"),
        ])
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 4, cluster: 0, confidence: 1, tile: 0),
                     SpeakerTurn(videoID: 1, start: 4, end: 10, cluster: 1, confidence: 1, tile: 1)]
        for kind in [CropRecipe.Kind.grid, .talker, .talkerAndPrevious, .talkerAndRotation] {
            let plan = try CropRecipePlanner.plan(CropRecipe(kind: kind), video: video, range: 0...10,
                turns: turns, roster: [], layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
            let areas = NameTagPlanner.areas(plan: plan, tiles: video.podcastTiles, roster: [],
                layouts: ScreenCropStore.builtIn, canvas: frame.size, duration: 10)
            let tags = NameTagPlanner.plan(areas: areas, people: people, settings: .init())
            if kind == .grid {
                #expect(tags.count == 2 && tags.allSatisfy { $0.start == 0 && $0.end == 10 })
            } else {
                let firstArea = tags.filter { $0.areaRect == areas[0].rect }
                #expect(firstArea.map(\.personKey) == ["ann", "bob"])
                #expect(firstArea.map(\.start) == [0, 4] && firstArea.map(\.end) == [4, 10])
            }
        }
    }
}

extension NameTagPlannerTests {
    @Test func ordinaryClipsRequireExactlyOneIdentifiedPerson() {
        var scene = Fixtures.scene()
        var options = WizardOptions()
        options.nameTags = true
        options.enableTextOverlays = false
        let people = [PersonRecord(id: 1, key: "ann", name: "Ann", descriptor: "Host"),
                      PersonRecord(id: 2, key: "bob", name: "Bob", descriptor: "")]
        scene.tags = ["person:ann"]
        #expect(WizardNameTags.ordinary(scene: scene, duration: 10, people: people,
            options: options, captionStyle: CaptionStyle()).count == 1)
        scene.tags += ["person:bob"]
        #expect(WizardNameTags.ordinary(scene: scene, duration: 10, people: people,
            options: options, captionStyle: CaptionStyle()).isEmpty)
        scene.tags = []
        #expect(WizardNameTags.ordinary(scene: scene, duration: 10, people: people,
            options: options, captionStyle: CaptionStyle()).isEmpty)
    }

    @Test func explicitOffOverridesLegacyMiniNameTagsOnlyAndIntroductionsStayInOldPlans() {
        var options = WizardOptions()
        options.nameTagsOnly = true
        options.enableTextOverlays = true
        var clip = Fixtures.planClip()
        clip.speakerIntroductions = [TextOverlayItem(text: "Old introduction")]
        let plan = Fixtures.plan(clips: [clip])
        #expect(WizardNameTags.renderPlan(plan, options: options).clips[0].speakerIntroductions.isEmpty)
        #expect(plan.clips[0].speakerIntroductions.count == 1)
        options.nameTags = false
        #expect(!options.usesNameTags)
        #expect(WizardNameTags.renderPlan(plan, options: options).clips[0].speakerIntroductions.count == 1)
    }
}

extension NameTagPlannerTests {
    @Test func rotatingSecondaryAreaUsesItsOwnCutsRatherThanSpeakerTurns() throws {
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.33, h: 1, personKey: "ann"),
                     PodcastTile(index: 1, x: 0.33, y: 0, w: 0.33, h: 1, personKey: "bob"),
                     PodcastTile(index: 2, x: 0.66, y: 0, w: 0.34, h: 1, personKey: "cam")]
        let video = try CropRecipeTests.video(tiles: tiles)
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .talkerAndRotation), video: video,
            range: 0...10, turns: [SpeakerTurn(videoID: 1, start: 0, end: 10, cluster: 0, confidence: 1, tile: 0)],
            roster: [], layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
        let areas = NameTagPlanner.areas(plan: plan, tiles: tiles, roster: [], layouts: ScreenCropStore.builtIn,
            canvas: frame.size, duration: 10, sourceAspect: 16.0 / 9)
        let tags = NameTagPlanner.plan(areas: areas, people: people + [.init(key: "cam", name: "Cam")], settings: .init())
        let rotating = tags.filter { $0.areaRect == areas[1].rect }
        #expect(rotating.map(\.personKey) == ["bob", "cam"])
        #expect(rotating.map(\.start) == [0, 5] && rotating.map(\.end) == [5, 10])
    }

    @Test func windowAndRegionSlotsMapFacesIntoTheirOwnArea() throws {
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "ann", faceX: 0.25, faceY: 0.3),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "bob", faceX: 0.75, faceY: 0.3)]
        let video = try CropRecipeTests.video(tiles: tiles)
        for tracking in [false, true] {
            var recipe = CropRecipe(kind: .grid)
            recipe.tracking = tracking
            let plan = try CropRecipePlanner.plan(recipe, video: video, range: 0...10,
                turns: [], roster: [], layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
            let areas = NameTagPlanner.areas(plan: plan, tiles: tiles, roster: [], layouts: ScreenCropStore.builtIn,
                canvas: frame.size, duration: 10, sourceAspect: 16.0 / 9)
            #expect(areas.map { $0.spans.first?.personKey } == ["ann", "bob"])
            for area in areas {
                let face = try #require(area.spans.first?.faceBox)
                #expect(area.rect.intersects(face))
            }
        }
    }

    @Test func allOverlappingCornersChooseTheLeastCoveredOne() throws {
        let area = NameTagPlanner.Area(rect: frame, spans: [.init(start: 0, end: 5, personKey: "ann",
            faceBox: CGRect(x: 0, y: 0, width: 900, height: 1920))])
        let tag = try #require(NameTagPlanner.plan(areas: [area], people: people,
            settings: .init(captionBand: CGRect(x: 0, y: 1500, width: 1080, height: 420))).first)
        #expect(tag.corner == .topTrailing)
    }
}

extension NameTagPlannerTests {
    @Test func longNamesStayUnderTheAreaWidthCapAndBlankNamesAreOmitted() throws {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 600)
        let area = NameTagPlanner.Area(rect: rect, spans: [.init(start: 0, end: 5, personKey: "ann")])
        let tag = try #require(NameTagPlanner.plan(areas: [area],
            people: [.init(key: "ann", name: String(repeating: "Long name ", count: 20))], settings: .init()).first)
        #expect(tag.rect.width == 240 && rect.contains(tag.rect))
        #expect(NameTagPlanner.plan(areas: [area], people: [.init(key: "ann", name: " \n ")], settings: .init()).isEmpty)
    }
}

extension NameTagPlannerTests {
    @Test func explicitBottomRightStacksAboveBottomCaptionsAtTheAreaRightInset() throws {
        let safe = try #require(PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: 9.0 / 16))
        let band = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(), safeArea: safe)
            .twoRowBand(positionOverride: "bottom")
        let area = NameTagPlanner.Area(rect: frame, spans: [.init(start: 0, end: 5, personKey: "ann")])
        let tag = try #require(NameTagPlanner.plan(areas: [area], people: people,
            settings: .init(content: "nameAndRole", position: "bottomTrailing", captionBand: band)).first)
        #expect(tag.rect.maxY <= band.minY - 19.2 + 0.001)
        #expect(abs(tag.rect.maxX - (1080 - 43.2)) < 0.001)
        #expect(frame.contains(tag.rect))
        let overlay = NameTagPlanner.overlay(tag, canvas: frame.size)
        #expect(overlay.keptClear(of: safe) == overlay)
    }

    @Test func topCornersStackBelowTopCaptions() throws {
        let band = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(), safeArea: nil)
            .twoRowBand(positionOverride: "top")
        let area = NameTagPlanner.Area(rect: frame, spans: [.init(start: 0, end: 5, personKey: "ann")])
        for corner in [NameTagPlanner.Corner.topLeading, .topTrailing] {
            let tag = try #require(NameTagPlanner.plan(areas: [area], people: people,
                settings: .init(content: "nameAndRole", position: corner.rawValue, captionBand: band)).first)
            #expect(tag.rect.minY >= band.maxY + 19.2 - 0.001)
            #expect(frame.contains(tag.rect))
        }
    }

    @Test func gridCellStacksInsideItsAreaWhenItsBottomIsCovered() throws {
        let rect = CGRect(x: 540, y: 960, width: 540, height: 960)
        let band = CGRect(x: 0, y: 1760, width: 1080, height: 120)
        let area = NameTagPlanner.Area(rect: rect, spans: [.init(start: 0, end: 5, personKey: "ann")])
        let tag = try #require(NameTagPlanner.plan(areas: [area], people: people,
            settings: .init(content: "nameAndRole", position: "bottomTrailing", captionBand: band)).first)
        #expect(rect.contains(tag.rect))
        #expect(tag.rect.maxY <= band.minY - 19.2 + 0.001)
        #expect(abs(tag.rect.maxX - (rect.maxX - 21.6)) < 0.001)
    }

    @Test func fullyCoveredCellUsesTheNearestFreeStripOfTheFrameForEveryPosition() throws {
        let band = CGRect(x: 0, y: 850, width: 1080, height: 250)
        for y in [860.0, 990.0] {
            let rect = CGRect(x: 540, y: y, width: 540, height: 100)
            let area = NameTagPlanner.Area(rect: rect, spans: [.init(start: 0, end: 5, personKey: "ann")])
            for position in ["auto"] + NameTagPlanner.Corner.allCases.map(\.rawValue) {
                let tag = try #require(NameTagPlanner.plan(areas: [area], people: people,
                    settings: .init(position: position, captionBand: band)).first)
                #expect(frame.contains(tag.rect) && !tag.rect.intersects(band))
                if y < 900 { #expect(tag.rect.maxY <= band.minY - 19.2 + 0.001) }
                else { #expect(tag.rect.minY >= band.maxY + 19.2 - 0.001) }
            }
        }
    }

    @Test func autoStacksClearWhenAllCornersIntersectTheCaptionBand() throws {
        let rect = CGRect(x: 100, y: 900, width: 600, height: 160)
        let band = CGRect(x: 0, y: 930, width: 1080, height: 100)
        let safe = CGRect(x: 0, y: 250, width: 896, height: 1170)
        let area = NameTagPlanner.Area(rect: rect, spans: [.init(start: 0, end: 5, personKey: "ann")])
        let tag = try #require(NameTagPlanner.plan(areas: [area], people: people,
            settings: .init(content: "nameAndRole", safeRect: safe, captionBand: band)).first)
        #expect(safe.contains(tag.rect))
        #expect(tag.rect.maxY <= band.minY - 19.2 + 0.001 || tag.rect.minY >= band.maxY + 19.2 - 0.001)
    }

    @Test func measuredTemplateFontsIgnoreAbsoluteTemplateSizeAndScaleWithCanvas() throws {
        var template = TextOverlayItem(text: "Template")
        template.fontsize = 6
        template.fontfamily = "Menlo"
        template.boxRadius = 12
        template.strokeColor = "black"
        template.strokeWidthEm = 0.04
        for scale in [0.5, 1.0, 2.0] {
            let canvas = CGSize(width: 1080 * scale, height: 1920 * scale)
            for shortSide in [200.0, 540.0, 1080.0] {
                let area = NameTagPlanner.Area(rect: CGRect(x: 0, y: 0, width: shortSide * scale, height: 1920 * scale),
                    spans: [.init(start: 0, end: 5, personKey: "ann")])
                let settings = NameTagPlanner.Settings(content: "nameAndRole", canvas: canvas)
                let tag = try #require(NameTagPlanner.plan(areas: [area], people: people,
                    settings: settings, template: template).first)
                var largeTemplate = template
                largeTemplate.fontsize = 180
                let large = try #require(NameTagPlanner.plan(areas: [area], people: people,
                    settings: settings, template: largeTemplate).first)
                #expect(tag == large)
                let overlay = NameTagPlanner.overlay(tag, canvas: canvas, template: template)
                #expect(overlay.fontsize == Int(min(64, max(30, shortSide * 0.075))))
                #expect(overlay.boxRadius == 12 && overlay.fontfamily == "Menlo")
                let renderer = TextOverlayRenderer(videoWidth: Int(canvas.width), videoHeight: Int(canvas.height), safeArea: nil)
                let measured = renderer.nameTagLayout(overlay, maxWidth: tag.rect.width)
                #expect(measured.size == tag.rect.size)
                #expect(abs(CTFontGetSize(measured.fonts[1]) / CTFontGetSize(measured.fonts[0]) - 0.72) < 0.001)
                #expect(tag.rect.width <= area.rect.width * 0.6)
            }
        }
    }

    @Test func longNamesShrinkToTheFloorThenTruncateWithEllipsis() throws {
        let area = NameTagPlanner.Area(rect: CGRect(x: 0, y: 0, width: 400, height: 600),
            spans: [.init(start: 0, end: 5, personKey: "ann")])
        let tag = try #require(NameTagPlanner.plan(areas: [area],
            people: [.init(key: "ann", name: String(repeating: "Long name ", count: 20))], settings: .init()).first)
        let item = NameTagPlanner.overlay(tag, canvas: frame.size)
        let layout = TextOverlayRenderer(safeArea: nil).nameTagLayout(item, maxWidth: tag.rect.width)
        #expect(item.fontsize == 22)
        #expect(layout.lines[0].hasSuffix("…"))
        #expect(layout.size == tag.rect.size && layout.size.width <= 240)
    }

    @Test func fullFrameTagRendersAtLeastThirtyPixelsOfInkPerLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var template = TextOverlayItem(text: "Template")
        template.fontsize = 6
        template.fontfamily = "Helvetica Neue"
        template.boxOpacity = 0
        let area = NameTagPlanner.Area(rect: frame, spans: [.init(start: 0, end: 5, personKey: "ann")])
        let tag = try #require(NameTagPlanner.plan(areas: [area],
            people: [.init(key: "ann", name: "ANN", role: "HOST")],
            settings: .init(content: "nameAndRole", position: "bottomTrailing"), template: template).first)
        let item = NameTagPlanner.overlay(tag, canvas: frame.size, template: template)
        let renderer = TextOverlayRenderer(safeArea: nil)
        let url = try renderer.render(item, to: directory)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: frame)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var lineHeights: [Int] = []
        var run = 0
        for y in 0..<image.height {
            let ink = (0..<image.width).contains { x in bytes[y * context.bytesPerRow + x * 4 + 3] > 127 }
            if ink { run += 1 }
            else if run > 0 { lineHeights.append(run); run = 0 }
        }
        if run > 0 { lineHeights.append(run) }
        #expect(lineHeights.count == 2)
        #expect(lineHeights.allSatisfy { $0 >= 30 })
        #expect(tag.fontSize == 64)
    }
}
