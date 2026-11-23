import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Telestration figure stays")
struct TelestrationLingerTests {
    @Test func carriedClockPinsPausedBehaviorAndRunsMovingDrawStayFade() throws {
        let paused = drawing()
        #expect(TelestrationRules.carriedDuration(of: paused) == TelestrationRules.lingerDuration(of: paused))
        for time in [-1, 0, 0.125, 0.4, 0.8, 1, 1.2, 3, Double.nan, Double.infinity] {
            #expect(TelestrationRules.carriedState(of: paused, at: time) == TelestrationRules.lingerState(of: paused, at: time))
        }
        var moving = paused
        moving.motion = 0.5
        #expect(TelestrationRules.carriedDuration(of: moving) == moving.duration + 1.2)
        for time in [0, 0.125, 0.4, 0.8, moving.duration - 0.2] {
            #expect(TelestrationRules.carriedState(of: moving, at: time) == TelestrationRules.state(of: moving, at: time))
        }
        for time in [0.0, 0.6, 1] {
            #expect(TelestrationRules.carriedState(of: moving, at: moving.duration + time)
                == TelestrationRules.lingerState(of: moving, at: moving.duration + time - moving.duration))
        }
        #expect(TelestrationRules.carriedState(of: moving, at: moving.duration).figures.map(\.figure.kind) == [.oval])
        #expect(TelestrationRules.carriedState(of: moving, at: TelestrationRules.carriedDuration(of: moving)).figures.isEmpty)
    }

    private func drawing() -> Telestration {
        Telestration(figures: [.init(kind: .line), .init(kind: .oval, linger: 1.2)],
                     stay: 0.5, drawSpeed: 0.25, fade: 0.4)
    }

    @Test func mixedPauseKeepsOnlyStayingFigureAtFullOpacity() throws {
        let drawing = drawing()
        let early = TelestrationRules.state(of: drawing, at: 0.125)
        #expect(early.figures.count == 1)
        #expect(abs(early.figures[0].progress - 0.875) < 1e-9)
        let middle = TelestrationRules.state(of: drawing, at: 0.8)
        #expect(middle.figures.allSatisfy { abs($0.opacity - 1) < 1e-9 })
        let fade = TelestrationRules.state(of: drawing, at: drawing.duration - 0.2)
        #expect(abs(fade.opacity - 1) < 1e-9)
        #expect(abs(try #require(fade.figures.first).opacity - 0.5) < 1e-9)
        #expect(abs(try #require(fade.figures.last).opacity - 1) < 1e-9)
        // Past the animation the staying figure waits, fully drawn, for the motion to resume.
        #expect(TelestrationRules.state(of: drawing, at: drawing.duration).figures.map(\.figure.kind) == [.oval])
    }

    @Test func lingerClockAndIndividualEnds() throws {
        var drawing = drawing()
        drawing.figures.append(.init(linger: 0.1))
        #expect(abs(TelestrationRules.lingerDuration(of: drawing) - 1.2) < 1e-9)
        let start = TelestrationRules.lingerState(of: drawing, at: 0)
        #expect(start.figures.count == 2)
        #expect(start.figures.allSatisfy { abs($0.progress - 1) < 1e-9 && abs($0.opacity - 1) < 1e-9 })
        let shortFade = TelestrationRules.lingerState(of: drawing, at: 0.05)
        #expect(abs(try #require(shortFade.figures.last).opacity - 0.5) < 1e-9)
        let middle = TelestrationRules.lingerState(of: drawing, at: 0.6)
        #expect(middle.figures.count == 1)
        #expect(abs(try #require(middle.figures.first).opacity - 1) < 1e-9)
        let fade = TelestrationRules.lingerState(of: drawing, at: 1)
        #expect(abs(try #require(fade.figures.first).opacity - 0.5) < 1e-9)
        for time in [1.2, 2, -0.1, Double.nan] {
            #expect(TelestrationRules.lingerState(of: drawing, at: time).figures.isEmpty)
        }
        drawing.fade = 0
        #expect(abs(try #require(TelestrationRules.lingerState(of: drawing, at: 1.19).figures.first).opacity - 1) < 1e-9)
    }

    @Test func clampNormalizationAndCodable() throws {
        for (input, expected) in [(-1.0, 0.0), (0, 0), (1.7, 1.7), (4, 3), (Double.nan, 0), (Double.infinity, 0)] {
            let figure = Telestration.Figure(linger: input)
            #expect(abs((figure.linger ?? -1) - expected) < 1e-9)
            #expect(abs((figure.normalized.linger ?? -1) - expected) < 1e-9)
        }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let old = Telestration.Figure(kind: .line)
        let data = try encoder.encode(old)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["linger"] == nil)
        #expect(try decoder.decode(Telestration.Figure.self, from: data).linger == nil)
        for (input, expected) in [(-4.0, 0.0), (8, 3)] {
            var edited = object
            edited["linger"] = input
            let decoded = try decoder.decode(Telestration.Figure.self, from: JSONSerialization.data(withJSONObject: edited))
            #expect(abs((decoded.linger ?? -1) - expected) < 1e-9)
        }
        let note = drawing()
        #expect(try decoder.decode(Telestration.self, from: encoder.encode(note)) == note)
        var plain = note
        for index in plain.figures.indices { plain.figures[index].linger = nil }
        #expect(abs(plain.duration - note.duration) < 1e-9)
        #expect(TelestrationRules.lingerDuration(of: plain) == 0)
        #expect(TelestrationRules.lingerState(of: plain, at: 0).figures.isEmpty)
    }

    @Test("Stay uses screen frames at every speed and a part-way window", arguments: [1.0, 0.5, 2.0])
    func burnTimes(speed: Double) throws {
        let drawing = drawing()
        let whole = TelestrationBurn.lingerFrameTimes(drawing, offset: 0, duration: 4, speed: speed)
        #expect(whole.count == 36)
        for (index, frame) in whole.enumerated() {
            #expect(abs(frame.elapsed - Double(index) / 30) < 1e-9)
            #expect(abs(frame.sourceOffset - Double(index) * speed / 30) < 1e-9)
        }
        let window = TelestrationBurn.lingerFrameTimes(drawing, offset: 0.5, duration: 0.4, speed: speed)
        #expect(window.count == 12)
        #expect(abs(try #require(window.first).elapsed - 0.5) < 1e-9)
        #expect(abs(try #require(window.last).sourceOffset - 11 * speed / 30) < 1e-9)
        #expect(TelestrationBurn.lingerFrameTimes(drawing, offset: 1.2, duration: 1, speed: speed).isEmpty)
        let sequence = StrikeHighlightBurn.Sequence(offset: 0, frames: whole.count,
            pattern: "/tmp/d%04d.png", frameDuration: speed / 30)
        let graph = try StrikeHighlightBurn.inGraph([sequence], size: CGSize(width: 640, height: 360), input: "[v]", tag: "stay")
        #expect(graph[1].contains(String(format: "setpts=N*%.9f/TB", speed / 30)))
        #expect(graph[1].contains("settb=1/90000"))
        #expect(graph[2].contains("eof_action=pass:repeatlast=0"))
    }

    @Test func mixedDrawingPixelsAtLastPauseFrame() throws {
        let size = 400
        let drawing = Telestration(figures: [
            .init(kind: .line, points: [CGPoint(x: 0.1, y: 0.25), CGPoint(x: 0.9, y: 0.25)], width: 0.016),
            .init(kind: .line, points: [CGPoint(x: 0.1, y: 0.75), CGPoint(x: 0.9, y: 0.75)], width: 0.016, linger: 1)
        ], fade: 0.3)
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.setShouldAntialias(false)
        TelestrationPainter.draw(drawing, at: drawing.duration - 1.0 / 30, in: context,
            rect: CGRect(x: 0, y: 0, width: size, height: size), topLeftOrigin: false)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let fading = (100 * size + 200) * 4, staying = (300 * size + 200) * 4
        #expect(pixels[staying] == 255 && pixels[staying + 1] == 255 && pixels[staying + 3] == 255)
        #expect(pixels[fading + 3] > 20 && pixels[fading + 3] < 35)
    }

    @MainActor @Test func editorSelectionUndoAndPlaybackDuration() {
        let editor = TelestratorEditor(initialTime: 0, duration: 10, aspect: 1, existing: drawing())
        editor.select(0)
        #expect(editor.selectedLinger == 0)
        editor.controlEditing(true)
        editor.setLinger(0.5)
        editor.setLinger(2)
        editor.controlEditing(false)
        #expect(abs(editor.playbackDuration - editor.drawing.duration - 2) < 1e-9)
        editor.undo()
        #expect(editor.drawing.figures[0].linger == nil)
        #expect(abs(editor.playbackDuration - editor.drawing.duration - 1.2) < 1e-9)
    }

    @Test func stayingFigureWaitsThroughAPauseLongerThanItsDrawing() {
        var stays = Telestration.Figure(kind: .line, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.2)])
        stays.linger = 1
        let plain = Telestration.Figure(kind: .line, points: [CGPoint(x: 0.1, y: 0.6), CGPoint(x: 0.8, y: 0.6)])
        let drawing = Telestration(figures: [stays, plain], stay: 0.5, drawSpeed: 0.2, fade: 0.3)
        let after = TelestrationRules.state(of: drawing, at: drawing.duration + 1)
        #expect(after.figures.count == 1 && after.figures[0].progress == 1 && after.figures[0].opacity == 1 && after.opacity == 1)
        // Pictures cover the whole pause, not only the drawing's own animation.
        let times = TelestrationBurn.frameTimes(drawing, offset: 0, duration: drawing.duration + 1)
        #expect(times.count == Int(ceil((drawing.duration + 1) * 30)))
        // Without a staying figure nothing changes: the pictures end with the animation.
        let ordinary = Telestration(figures: [plain], stay: 0.5, drawSpeed: 0.2, fade: 0.3)
        #expect(TelestrationRules.state(of: ordinary, at: ordinary.duration + 1).figures.isEmpty)
        #expect(TelestrationBurn.frameTimes(ordinary, offset: 0, duration: ordinary.duration + 1).count
                == Int(ceil(ordinary.duration * 30)))
    }
}
