import Foundation
import Testing
@testable import Clip_Builder

@Suite("Sources table sort")
struct SourcesTableSortTests {
    private func row(_ id: Int64, name: String, created: String, duration: Double, type: VideoType?, language: String?) -> SourceRow {
        var video = Fixtures.video(id: id)
        video.filename = name
        video.createdAt = created
        video.duration = duration
        video.videoType = type?.rawValue
        video.language = language
        return SourceRow(video: video)
    }

    @Test("the chosen sort survives a relaunch as text and sorts the rows the same way")
    func roundTrip() {
        let chosen = [SourcesTableSort.Column.created.comparator(ascending: false),
                      SourcesTableSort.Column.file.comparator(ascending: true)]
        let text = SourcesTableSort.encode(chosen)
        #expect(text == "created:desc,file:asc")
        let restored = SourcesTableSort.decode(text)
        let rows = [
            row(1, name: "b.mp4", created: "2026-01-10T10:00:00Z", duration: 5, type: .fight, language: "en"),
            row(2, name: "a.mp4", created: "2026-01-10T10:00:00Z", duration: 9, type: nil, language: nil),
            row(3, name: "c.mp4", created: "2026-01-20T10:00:00Z", duration: 1, type: .podcast, language: "pt"),
        ]
        #expect(rows.sorted(using: restored).map(\.id) == [3, 2, 1])
        #expect(rows.sorted(using: chosen).map(\.id) == rows.sorted(using: restored).map(\.id))
        #expect(rows.sorted(using: SourcesTableSort.decode("type:asc")).map(\.id) == [2, 1, 3])
        #expect(rows.sorted(using: SourcesTableSort.decode("lang:desc")).map(\.id) == [3, 1, 2])
    }

    @Test("unknown or malformed entries are dropped, not crashed on")
    func garbage() {
        #expect(SourcesTableSort.decode("").isEmpty)
        #expect(SourcesTableSort.decode("status:asc,,nonsense").isEmpty)
        #expect(SourcesTableSort.decode("duration").count == 1)
        #expect(SourcesTableSort.encode([KeyPathComparator(\SourceRow.id)]).isEmpty)
    }
}
