import Foundation
import Testing

@testable import Clip_Builder

/// The registry (`AITask`) and the routing tables (`AICatalog`) describe the
/// same set of tasks; these tests fail when one gains a key the other lacks.
struct AITaskRegistryTests {
    @Test func everyConfigurableTaskHasLabelDefaultAndChain() {
        for task in AITask.configurable {
            #expect(AICatalog.taskLabels[task.rawValue] != nil, Comment(rawValue: task.rawValue))
            #expect(AICatalog.taskDefaults[task.rawValue] != nil, Comment(rawValue: task.rawValue))
            #expect(AICatalog.recommendedChains[task.rawValue]?.isEmpty == false, Comment(rawValue: task.rawValue))
        }
        #expect(AICatalog.tasks == AITask.configurable.map(\.rawValue))
    }

    @Test func catalogTablesOnlyNameRegisteredTasks() {
        let known = Set(AITask.allCases.map(\.rawValue))
        for key in AICatalog.taskLabels.keys { #expect(known.contains(key), Comment(rawValue: key)) }
        for key in AICatalog.taskDefaults.keys { #expect(known.contains(key), Comment(rawValue: key)) }
        for key in AICatalog.recommendedChains.keys { #expect(known.contains(key), Comment(rawValue: key)) }
    }

    @Test func cameraFocusHasItsOwnRouteWithTheHighlightsChain() {
        #expect(AITask.framing.rawValue == "framing")
        #expect(AITask.framing.label == "Camera focus choice")
        #expect(AITask.configurable.contains(.framing))
        #expect(AICatalog.taskDefaults["framing"] == AICatalog.taskDefaults["highlights"])
        let camera = AICatalog.recommendedChains["framing"] ?? []
        let highlights = AICatalog.recommendedChains["highlights"] ?? []
        #expect(camera.map { $0.0 } == highlights.map { $0.0 })
        #expect(camera.map { $0.1 } == highlights.map { $0.1 })
    }

    @Test func rawValuesAreStableSettingsKeys() throws {
        // Keys stored in settings JSON and provenance; renaming a case must not change these.
        #expect(AITask.fightResearch.rawValue == "fight_research")
        #expect(AITask.builderAgent.rawValue == "builder_agent")
        #expect(AITask(rawValue: "critique") == .critique)
        let encoded = try JSONEncoder().encode([AITask.wizard, .fightResearch])
        #expect(String(data: encoded, encoding: .utf8) == #"["wizard","fight_research"]"#)
        #expect(AITask.critique.label == "Reel critique")
    }
}


extension AITaskRegistryTests {
    @Test func tagTextUsesTheCaptionRoute() {
        #expect(AITask.tagText.rawValue == "tag_text")
        #expect(AITask.tagText.label == "Name tag text")
        #expect(AITask.configurable.contains(.tagText))
        #expect(AICatalog.taskDefaults["tag_text"] == AICatalog.taskDefaults["captions"])
        let tags = AICatalog.recommendedChains["tag_text"] ?? []
        let captions = AICatalog.recommendedChains["captions"] ?? []
        #expect(tags.map { $0.0 } == captions.map { $0.0 })
        #expect(tags.map { $0.1 } == captions.map { $0.1 })
    }
}
