import Foundation
import Testing
@testable import Clip_Builder

struct TranslationBatchTests {
    @Test func threeFailuresUseOneCall() async throws {
        let stub = try StubAI(response: "1. Olá\n2. Tchau\n3. Obrigado")
        let result = try await TranslationBatch.perform(texts: ["Hello", "Goodbye", "Thanks"], language: "pt-BR", ai: stub.service)
        #expect(TranslationBatch.parse(result.text, count: 3) == [0: "Olá", 1: "Tchau", 2: "Obrigado"])
        #expect(try String(contentsOf: stub.calls, encoding: .utf8) == "call\n")
        let prompt = try String(contentsOf: stub.prompts, encoding: .utf8)
        #expect(prompt.contains("1. Hello"))
        #expect(prompt.contains("2. Goodbye"))
        #expect(prompt.contains("3. Thanks"))
    }
    @Test func numberedBatch() {
        let prompt = TranslationBatch.prompt(texts: ["Hello", "Goodbye", "Thanks"], language: "pt-BR")
        #expect(prompt.contains("1. Hello\n2. Goodbye\n3. Thanks"))
        #expect(TranslationBatch.parse("1. Olá\n2. Tchau\n3. Obrigado", count: 3)
            == [0: "Olá", 1: "Tchau", 2: "Obrigado"])
    }
    @Test func missingRowsDoNotShift() {
        #expect(TranslationBatch.parse("1. Olá\n3. Obrigado", count: 3) == [0: "Olá", 2: "Obrigado"])
        #expect(TranslationBatch.parse("1. Olá", count: 3)[1] == nil)
    }
}

extension TranslationBatchTests {
    @Test func parseToleratesFormattingAndIgnoresStrays() {
        let answer = "Here you go:\n1) Olá \n  2.   Tchau\n0. nada\n4. extra\nnot a row\n3. "
        #expect(TranslationBatch.parse(answer, count: 3) == [0: "Olá", 1: "Tchau"])
        #expect(TranslationBatch.parse("1. Olá", count: 0).isEmpty)
        // A later duplicate row wins, and a caption starting with a number keeps its number.
        #expect(TranslationBatch.parse("1. Olá\n1. Oi", count: 1) == [0: "Oi"])
        #expect(TranslationBatch.parse("1. 2 lutadores", count: 1) == [0: "2 lutadores"])
    }
}
