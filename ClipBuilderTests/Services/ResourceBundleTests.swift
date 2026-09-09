import Testing
@testable import Clip_Builder

struct ResourceBundleTests {
    @Test func learnedCategoryIsExplicitAndShareable() {
        #expect(ResourceCategory.allCases.contains(.learned))
        #expect(ResourceCategory.learned.folderName == "learned")
        #expect(ResourceCategory.learned.allowedExtensions == ["json", "jpg"])
        #expect(ResourceCategory.learned.localRoot == nil)
    }
}
