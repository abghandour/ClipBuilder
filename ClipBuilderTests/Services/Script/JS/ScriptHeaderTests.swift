import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("JavaScript headers", .serialized)
struct ScriptHeaderTests {
    nonisolated static func source(_ body: String = "", params: String = "[]", requires: String = "[]", mode: String = "edit") -> String {
        """
        /** clipbuilder-script
        {"name":"Test script","description":"Fixture","mode":"\(mode)","params":\(params),"requires":\(requires)}
        */
        \(body)
        """
    }

    @Test func defaultsRangesStepsAndTime() throws {
        let model = ScriptFixtures.model()
        model.playhead = 2.5
        let capture = ScriptCapture(model: model, library: ScriptFixtures.library())
        let header = try ScriptHeader.parse(Self.source(params:
            #"[{"name":"n","type":"number","min":2,"max":12,"step":2,"default":6},{"name":"time","type":"time"},{"name":"choice","type":"choice","choices":["a","b"],"default":"a"}]"#))
        let (data, commands) = try header.resolve(capture: capture)
        let values = try JSONDecoder().decode([String: ScriptValue].self, from: data)
        #expect(values["n"] == .number(6))
        #expect(values["time"] == .number(2.5))
        #expect(commands.isEmpty)
        #expect(throws: (any Error).self) { try header.resolve(Data(#"{"n":3}"#.utf8), capture: capture) }
        #expect(throws: (any Error).self) { try header.resolve(Data(#"{"choice":"c"}"#.utf8), capture: capture) }
    }

    @Test(arguments: [
        "const a=1; /** clipbuilder-script {} */",
        "/** clipbuilder-script {\"name\":\"x\",\"name\":\"y\"} */",
        "/** clipbuilder-script { /* comment */ } */",
        source(params: #"[{"name":"x","type":"number"},{"name":"x","type":"number"}]"#),
        source(params: #"[{"name":"é","type":"string"}]"#),
        source(params: #"[{"name":"x","type":"number","step":0}]"#),
        source(params: #"[{"name":"x","type":"number","min":3,"max":2}]"#),
        source(params: #"[{"name":"x","type":"number","default":null}]"#),
        source(params: #"[{"name":"x","type":"boolean","min":0}]"#),
        source(params: #"[{"name":"x","type":"choice","choices":["a","a"]}]"#),
        source(requires: #"[{"kind":"transcript","video":1}]"#, mode: "find")
    ])
    func invalidGrammar(source: String) {
        #expect(throws: (any Error).self) { try ScriptHeader.parse(source) }
    }

    @Test func requiresAndLaterPageMembership() throws {
        let clips = (0..<210).map { _ in Fixtures.timelineClip() }
        let model = ScriptFixtures.model(clips: clips)
        var library = ScriptFixtures.library()
        var late = Fixtures.scene()
        late.id = 999
        library.scenes += [late]
        let capture = ScriptCapture(model: model, library: library)
        let header = try ScriptHeader.parse(Self.source(params:
            #"[{"name":"clip","type":"clip"},{"name":"scene","type":"scene"},{"name":"video","type":"number"}]"#,
            requires: #"[{"kind":"transcript","video":"$video"}]"#))
        let clip = try #require(clips.last)
        let video = try #require(library.videos.first)
        let params = try JSONEncoder().encode(ScriptValue.object([
            "clip": .string(clip.uid.uuidString), "scene": .number(999), "video": .number(Double(video.id))
        ]))
        let (_, commands) = try header.resolve(params, capture: capture)
        #expect(commands == [.ensureTranscript(video: video.id)])
        #expect(throws: (any Error).self) { try header.resolve(capture: capture) }
        #expect(capture.matches(model))
        model.document.textOverlays.append(TextOverlayItem(text: "Changed"))
        #expect(!capture.matches(model))
    }
}
