import Foundation
import Testing
@testable import Clip_Builder

struct MiniBRollLibraryTests {
    @Test func localSearchIncludesOwnSourceAndMatchesNameTagsPeopleAndFile() async {
        var scene = Fixtures.scene(id: 2, start: 50, end: 60)
        scene.narrative = "Training camp — sparring"
        scene.tags = ["person:guest", "southpaw"]
        let person = PersonRecord(id: 1, key: "guest", name: "Alex Pereira", descriptor: "Guest")
        let catalog = await MiniBRollLibrary.catalog(scenes: [scene], people: [person])
        #expect(catalog.map(\.id) == [2])
        for query in ["Training", "SOUTHPAW", "Pereira", scene.videoFilename, "camp southpaw"] {
            #expect(await MiniBRollLibrary.search(catalog, query: query).map(\.id) == [2])
        }
        #expect(await MiniBRollLibrary.search(catalog, query: "unrelated").isEmpty)
    }
}
