import Foundation
import Testing
@testable import Clip_Builder

@Suite("Reel recipes")
struct ReelRecipeTests {
    @Test("Every recipe has a unique id, a title, and a summary; all but Custom carry a format block")
    func catalogInvariants() {
        let ids = ReelRecipe.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ReelRecipe.all.first?.id == ReelRecipe.customID)
        for recipe in ReelRecipe.all {
            #expect(!recipe.title.isEmpty)
            #expect(!recipe.summary.isEmpty, "\(recipe.id) needs a summary for the Wizard caption")
            #expect(!recipe.summary.hasSuffix(" "))
            if recipe.id == ReelRecipe.customID {
                #expect(recipe.promptBlock.isEmpty)
            } else {
                #expect(recipe.promptBlock.contains("## FORMAT:"), "\(recipe.id) needs a planner format block")
                #expect(recipe.promptBlock.contains("hard requirements"))
            }
        }
    }

    @Test("The picker sections cover the persisted ids the app has always used")
    func knownIDs() {
        let expected = ["custom", "mma-finish", "mma-submission", "mma-exchange", "mma-technique",
                        "recap", "compilation", "interview", "podcast"]
        #expect(ReelRecipe.all.map(\.id) == expected)
        #expect(ReelRecipe.menuSections.count == 3)
    }

    @Test("Prompt block lookup is empty for Custom, learned types, and unknown ids")
    func promptLookup() {
        #expect(ReelRecipe.promptBlock(for: "custom").isEmpty)
        #expect(ReelRecipe.promptBlock(for: "cat:walkouts").isEmpty)
        #expect(ReelRecipe.promptBlock(for: "nope").isEmpty)
        #expect(ReelRecipe.promptBlock(for: "recap").contains("## FORMAT: FIGHT RECAP"))
        #expect(ReelRecipe.recipe(id: "mma-exchange")?.title == "MMA exchange")
    }
}
