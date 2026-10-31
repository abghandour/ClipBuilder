import Testing

@testable import Clip_Builder

struct LearnedRichTextTests {
    @Test("House style text becomes headings, bullets and paragraphs without changing the source")
    func structure() {
        let source = """
            HOOK:
            - Establish within 0–2 seconds
              - nested detail
            DURATION & PACING:
            1. Optimal range 8.9–39.1 seconds
            Plain sentence. Another one.
            second line of the same paragraph

            New paragraph
            """
        let blocks = LearnedRichText.blocks(source)
        #expect(blocks == [
            .heading("HOOK"),
            .bullet("Establish within 0–2 seconds", level: 0),
            .bullet("nested detail", level: 1),
            .heading("DURATION & PACING"),
            .numbered("Optimal range 8.9–39.1 seconds", number: "1"),
            .paragraph("Plain sentence. Another one.\nsecond line of the same paragraph"),
            .paragraph("New paragraph"),
        ])
    }

    @Test("Ordinary lessons stay single paragraphs")
    func plainLesson() {
        #expect(LearnedRichText.blocks("Keep the knockout in the first two seconds.")
            == [.paragraph("Keep the knockout in the first two seconds.")])
        #expect(LearnedRichText.blocks("Note: this is a sentence, not a heading.")
            == [.paragraph("Note: this is a sentence, not a heading.")])
        #expect(LearnedRichText.blocks("") == [])
        #expect(LearnedRichText.blocks("MMA") == [.paragraph("MMA")])
        #expect(LearnedRichText.blocks("KEEP THE KO.") == [.paragraph("KEEP THE KO.")])
        #expect(LearnedRichText.blocks("TEXT & OVERLAYS") == [.heading("TEXT & OVERLAYS")])
    }

    @Test("Inline markdown is optional and never throws")
    func inline() {
        #expect(String(LearnedRichText.inline("no markup").characters) == "no markup")
        #expect(String(LearnedRichText.inline("**bold** and *it*").characters) == "bold and it")
        #expect(String(LearnedRichText.inline("a * b").characters) == "a * b")
    }

    @Test("Markdown headings and pipe tables from AI reports become titled blocks and tables")
    func markdownReport() {
        let source = """
            # Peace Grappler: What Worked
            ## Highest-Performing Posts
            | Post | Reach |
            |------|-------|
            | Lazy Boy | 89,833 |
            | Walkout | 80,953 |
            Reels are the core engine.
            #hashtag is text
            """
        let blocks = LearnedRichText.blocks(source)
        #expect(blocks == [
            .titled("Peace Grappler: What Worked", level: 1),
            .titled("Highest-Performing Posts", level: 2),
            .table([["Post", "Reach"], ["Lazy Boy", "89,833"], ["Walkout", "80,953"]]),
            .paragraph("Reels are the core engine.\n#hashtag is text"),
        ])
    }
}
