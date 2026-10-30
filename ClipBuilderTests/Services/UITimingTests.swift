import Testing
@testable import Clip_Builder

struct UITimingTests {
    @Test func navigationFormatting() {
        #expect(UITiming.changeLine(screen: "Sidebar", destination: "scenes", milliseconds: 125)
            == "Sidebar → scenes, 125 ms after mouse down")
        #expect(UITiming.changeLine(screen: "Express", destination: "transcript", milliseconds: nil)
            == "Express → transcript, no recent click")
        #expect(UITiming.readyLine(screen: "Express", destination: "transcript", milliseconds: 42)
            == "Express transcript ready 42 ms after selection")
    }
}
