import Testing
@testable import Clip_Builder

struct WordTimingRulesTests {
    @Test func portugueseOffersBothTimingsPreferredFirst() {
        #expect(WordTimingRules.options(languages: ["en-US", "pt-BR"], modelInstalled: true, preferred: .recognizer)
                == [.recognizer, .precise])
        #expect(WordTimingRules.options(languages: ["pt"], modelInstalled: true, preferred: .precise)
                == [.precise, .recognizer])
    }

    @Test func nothingToChooseWithoutTheModelOrTheLanguage() {
        #expect(WordTimingRules.options(languages: ["pt-BR"], modelInstalled: false, preferred: .precise) == [.recognizer])
        #expect(WordTimingRules.options(languages: ["en-US", "es-ES"], modelInstalled: true, preferred: .precise) == [.recognizer])
        #expect(WordTimingRules.options(languages: [], modelInstalled: true, preferred: .precise) == [.recognizer])
    }

    @Test func autoInstallOnlyForAPortugueseProjectThatLacksTheModel() {
        func wanted(spoken: [String] = ["en-US", "pt-BR"], installed: Bool = false, declined: Bool = false,
                    running: Bool = false, attempted: Bool = false) -> Bool {
            WordTimingRules.shouldAutoInstall(spoken: spoken, installed: installed, declined: declined,
                                              running: running, attempted: attempted)
        }
        #expect(wanted())
        #expect(wanted(spoken: ["pt-PT"]))
        #expect(!wanted(spoken: ["en-US"]))
        #expect(!wanted(spoken: []))
        #expect(!wanted(installed: true))
        #expect(!wanted(declined: true))
        #expect(!wanted(running: true))
        #expect(!wanted(attempted: true))
    }
}
