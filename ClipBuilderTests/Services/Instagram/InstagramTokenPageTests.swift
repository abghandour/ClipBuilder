import Testing
@testable import Clip_Builder

@Suite("Instagram token page")
struct InstagramTokenPageTests {
    @Test("A numeric app id opens that app's Instagram Login setup page")
    func appPage() {
        #expect(InstagramTokenPage.url(metaAppID: " 1735136357977055\n").absoluteString
                == "https://developers.facebook.com/apps/1735136357977055/instagram-business/API-Setup/")
    }

    @Test("A missing or malformed app id opens the app list", arguments: ["", "  ", "abc", "12/../x", "１２３"])
    func appList(id: String) {
        #expect(InstagramTokenPage.url(metaAppID: id).absoluteString == "https://developers.facebook.com/apps/")
    }
}
