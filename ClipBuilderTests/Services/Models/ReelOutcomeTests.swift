import Foundation
import Testing

@testable import Clip_Builder

@Suite struct ReelOutcomeTests {
  @Test func postingMonthAndMissingMetrics() async throws {
    let fixture = try TempDatabase()
    let database = fixture.database
    let accountID = try await database.upsertIGAccount(
      username: "test", kind: "own", displayName: nil, igUserID: nil, followers: nil)
    let account = try #require(try await database.fetchIGAccounts().first { $0.id == accountID })
    let august = try #require(Database.parseISODate("2026-08-15T12:00:00Z"))
    let september = try #require(Database.parseISODate("2026-09-15T12:00:00Z"))
    var ids: [Int64] = []
    for (index, date) in [august, august, september, september, september].enumerated() {
      let id = try await database.upsertIGReportMedia(
        IGReportMediaUpsert(
          accountID: accountID,
          shortcode: "reel-\(index)", mediaID: "m\(index)", mediaType: "VIDEO",
          productType: "REELS",
          caption: "", captionTruncated: false, permalink: nil, postedAt: date,
          likeCount: nil, commentsCount: nil, thumbnailURL: nil, source: "graph"))
      ids.append(id)
      var traits = ReelTraits()
      traits.duration = 10
      try await database.saveReelTraits(traits, kind: "imported", videoID: String(id))
      if index < 4 {
        let count = index < 2 ? 10.0 + Double(index) * 10 : 100 + Double(index - 2) * 100
        try await database.insertIGMediaInsightSnapshots([
          IGMediaInsightSnapshot(
            reportMediaID: id, metric: "saved", value: count, fetchedAt: "2026-09-20T00:00:00Z",
            source: "graph"),
          IGMediaInsightSnapshot(
            reportMediaID: id, metric: "shares", value: count, fetchedAt: "2026-09-20T00:00:00Z",
            source: "graph"),
          IGMediaInsightSnapshot(
            reportMediaID: id, metric: "comments", value: count, fetchedAt: "2026-09-20T00:00:00Z",
            source: "graph"),
          IGMediaInsightSnapshot(
            reportMediaID: id, metric: "ig_reels_avg_watch_time", value: 5000,
            fetchedAt: "2026-09-20T00:00:00Z", source: "graph"),
        ])
      }
    }
    try await database.rebuildReelOutcomes(account: account)
    let rows = try await database.reelOutcomes(accountID: accountID)
    #expect(rows.count == 4)
    let first = try #require(rows.first { $0.videoID == String(ids[0]) })
    let third = try #require(rows.first { $0.videoID == String(ids[2]) })
    #expect(abs((first.lift["saves"] ?? 0) - 10.0 / 15) < 0.000001)
    #expect(abs((third.lift["saves"] ?? 0) - 100.0 / 150) < 0.000001)
    #expect(first.lift["watchFraction"] == 1)
    #expect(!rows.contains { $0.videoID == String(ids[4]) })
    var publicAccount = account
    publicAccount.kind = "public"
    let inputs = try await database.fetchIGReportInputs(account: account)
    let media = try #require(inputs.media.first)
    #expect(
      ReelOutcome.joined(
        media: media, traits: ReelTraits(), account: publicAccount, insights: inputs.accountInsights
      ) == nil)
  }

  actor Computations {
    var count = 0
    func next() -> ReelTraits {
      count += 1
      var value = ReelTraits()
      value.duration = Double(count)
      return value
    }
  }

  @Test func versionInvalidatesCachedTraits() async throws {
    let fixture = try TempDatabase()
    let calls = Computations()
    let first = try await ReelTraitCache.traits(
      kind: "candidate", videoID: "test", database: fixture.database, version: 1
    ) { await calls.next() }
    let cached = try await ReelTraitCache.traits(
      kind: "candidate", videoID: "test", database: fixture.database, version: 1
    ) { await calls.next() }
    #expect(first == cached)
    #expect(await calls.count == 1)
    let updated = try await ReelTraitCache.traits(
      kind: "candidate", videoID: "test", database: fixture.database, version: 2
    ) { await calls.next() }
    #expect(updated.duration == 2)
    #expect(await calls.count == 2)
    #expect(
      try await fixture.database.reelTraits(kind: "candidate", videoID: "test", version: 1) == nil)
    try await fixture.database.saveReelTraits(
      first, kind: "instagram", videoID: "reference", reference: true)
    #expect(
      try await fixture.database.reelTraitIsReference(kind: "instagram", videoID: "reference"))
  }
}
