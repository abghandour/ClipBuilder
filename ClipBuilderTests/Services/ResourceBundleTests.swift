import Testing
@testable import Clip_Builder

struct ResourceBundleTests {
    @Test func learnedCategoryIsExplicitAndShareable() {
        #expect(ResourceCategory.allCases.contains(.learned))
        #expect(ResourceCategory.learned.folderName == "learned")
        #expect(ResourceCategory.learned.allowedExtensions == ["json", "jpg"])
        #expect(ResourceCategory.learned.localRoot == nil)
    }

    @Test func bundledImageNamesStayDistinct() {
        #expect(ResourceBundle.uniqueName("logo.png", taken: []) == "logo.png")
        #expect(ResourceBundle.uniqueName("logo.png", taken: ["logo.png"]) == "logo 2.png")
        #expect(ResourceBundle.uniqueName("logo.png", taken: ["logo.png", "logo 2.png"]) == "logo 3.png")
        #expect(ResourceBundle.uniqueName("README", taken: ["README"]) == "README 2")
    }
}
