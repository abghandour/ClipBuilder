import Testing
@testable import Clip_Builder

@Suite("Builder assistant")
struct BuilderAssistantTests {
    @Test(arguments: ["put a duck face on the left fighter", "ADD a crown sticker", "draw glasses", "generate an image", "make a picture", "give him a hat", "put a\nmask on her",
                      "Add a sticker to the clip", "Make an image for the reel"])
    func imageRequests(_ text: String) {
        #expect(BuilderAssistant.route(text) == .image(text))
    }

    @Test(arguments: ["Make a 30-second reel", "Remove the image", "Face the camera", "Put the clip first", "Make a faceoff reel", "Makeup image", "",
                      "Make a 30-second reel of the face off", "Make a reel where he puts his glasses on", "Add the clip with the mask walkout"])
    func wizardRequests(_ text: String) {
        #expect(BuilderAssistant.route(text) == .wizard(text))
    }

    @Test func whitespaceIsTrimmed() {
        #expect(BuilderAssistant.route("  Put a sticker on him\n") == .image("Put a sticker on him"))
        #expect(BuilderAssistant.route("  trim the first clip  ") == .wizard("trim the first clip"))
    }
}
