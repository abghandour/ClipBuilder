import Testing
@testable import Clip_Builder

@Suite("Instagram token flavor")
struct InstagramTokenFlavorTests {
    @Test("Instagram prefixes select Instagram Login", arguments: ["IGabcdef", "IG"])
    func instagram(token: String) {
        #expect(InstagramTokenFlavor.detect(token) == .instagram)
    }

    @Test("Facebook and unknown prefixes probe Facebook first", arguments: ["EAAtoken", "garbage", "", "igtoken"])
    func facebook(token: String) {
        #expect(InstagramTokenFlavor.detect(token) == .facebook)
    }

    @Test("Existing provider construction defaults to Facebook")
    func defaultProvider() {
        #expect(GraphAPIProvider(token: "IGtoken", igUserID: nil).flavor == .facebook)
    }
}
