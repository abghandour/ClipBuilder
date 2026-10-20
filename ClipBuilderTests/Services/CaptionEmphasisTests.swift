import Testing
@testable import Clip_Builder

struct CaptionEmphasisTests {
    @Test func numbersMoneyAndPercentagesWinWithoutAdjacentEmphasis() {
        let page = CaptionPage(text: "Save $100 now and 50% later", start: 0, end: 3)
        #expect(CaptionEmphasis.indices(for: page, language: "en") == [1, 4])
        let adjacent = CaptionPage(text: "10 20 30 40", start: 0, end: 3)
        #expect(CaptionEmphasis.indices(for: adjacent, language: "en") == [0, 2])
    }

    @Test func portugueseKeywordsAndAccents() {
        let page = CaptionPage(text: "Ganhe R$100 agora com 50% de desconto", start: 0, end: 3)
        #expect(CaptionEmphasis.indices(for: page, language: "pt") == [1, 4])
        #expect(CaptionEmphasis.emoji(for: .init(text: "Uma vitória com força", start: 0, end: 2), language: "pt") == "🏆")
        #expect(CaptionEmphasis.emoji(for: .init(text: "Muito dinheiro", start: 0, end: 2), language: "pt") == "💰")
    }

    @Test func nounsAndNamesStayBoundedAndDeterministic() {
        for (text, language) in [("Maria visited Lisbon with a bicycle", "en"), ("Maria visitou Lisboa de bicicleta", "pt")] {
            let page = CaptionPage(text: text, start: 0, end: 3)
            let indices = CaptionEmphasis.indices(for: page, language: language)
            #expect(indices == CaptionEmphasis.indices(for: page, language: language))
            #expect(indices.count <= 2)
            #expect(zip(indices, indices.dropFirst()).allSatisfy { $1 - $0 > 1 })
            #expect(indices.allSatisfy { $0 < text.split(separator: " ").count })
        }
        #expect(CaptionEmphasis.indices(for: .init(text: "", start: 0, end: 1), language: "en").isEmpty)
        #expect(CaptionEmphasis.emoji(for: .init(text: "something ordinary", start: 0, end: 1), language: "en") == nil)
    }
}
