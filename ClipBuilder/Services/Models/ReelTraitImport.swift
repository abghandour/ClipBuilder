import Foundation

extension InstagramService {
  /// Called after imports, and explicitly with downloadMissing=true from the Instagram UI.
  /// Report-only media are downloaded through the same service as grid media.
  func computeReelTraits(
    account: IGAccountRecord, database: Database,
    settings: InstagramSettings? = nil, downloadMissing: Bool = false,
    log: @escaping @Sendable (String) -> Void
  ) async throws {
    let inputs = try await database.fetchIGReportInputs(account: account)
    var grid = try await database.fetchIGMedia(accountID: account.id)
    var downloaded = 0
    var computed = 0
    for report in inputs.media where report.isReel {
      try Task.checkCancellation()
      if let cached = try await database.reelTraits(kind: "imported", videoID: String(report.id)) {
        try await database.saveReelTraits(
          cached, kind: "imported", videoID: String(report.id), reference: !account.isOwn)
        continue
      }
      var media = grid.first {
        $0.mediaID == report.mediaID || $0.mediaID == report.shortcode
          || $0.permalink == report.permalink && report.permalink != nil
      }
      let external = try await database.importedReelPath(externalIDs: [
        report.mediaID ?? "", report.shortcode,
      ])
      var url = media?.localVideoURL ?? external.map { URL(fileURLWithPath: $0.path) }
      if url == nil, downloadMissing, let settings {
        if media == nil {
          var upsert = IGMediaUpsert(
            accountID: account.id, mediaID: report.mediaID ?? report.shortcode)
          upsert.caption = report.caption
          upsert.permalink = report.permalink
          upsert.postedAt = report.postedAt
          upsert.source = report.source
          _ = try await database.upsertIGMedia(upsert)
          grid = try await database.fetchIGMedia(accountID: account.id)
          media = grid.first { $0.mediaID == upsert.mediaID }
        }
        if let media {
          url = try await ensureDownloaded(
            media: media, account: account, database: database, settings: settings, log: log)
          downloaded += 1
          log("Downloaded \(downloaded) reels for traits")
        }
      }
      guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
      do {
        let transcript = try await Self.traitTranscript(
          videoID: external?.videoID, database: database)
        let detectors = try await Self.traitDetectors(
          url: url, videoID: external?.videoID, database: database)
        _ = try await ReelTraitCache.traits(
          kind: "imported", videoID: String(report.id), database: database,
          reference: !account.isOwn
        ) {
          try await ReelTraitExtractor.traits(
            for: url, caption: report.caption,
            transcript: transcript, cachedDetectors: detectors)
        }
        computed += 1
      } catch is CancellationError { throw CancellationError() } catch {
        log("Traits unavailable for reel \(report.id): \(error.localizedDescription)")
      }
    }
    // Grid reels can be references with no report-media or insight rows at all.
    for media in grid {
      if let cached = try await database.reelTraits(kind: "instagram", videoID: String(media.id)) {
        try await database.saveReelTraits(
          cached, kind: "instagram", videoID: String(media.id), reference: !account.isOwn)
        continue
      }
      var local = media.localVideoURL
      if local == nil, downloadMissing, let settings {
        local = try await ensureDownloaded(
          media: media, account: account, database: database, settings: settings, log: log)
        downloaded += 1
        log("Downloaded \(downloaded) reels for traits")
      }
      guard let url = local else { continue }
      do {
        let traits = try await ReelTraitExtractor.traits(
          for: url, caption: media.caption, transcript: nil)
        try await database.saveReelTraits(
          traits, kind: "instagram", videoID: String(media.id), reference: !account.isOwn)
        computed += 1
      } catch is CancellationError { throw CancellationError() } catch {
        log("Traits unavailable for reel \(media.id): \(error.localizedDescription)")
      }
    }
    // Historical imports can exist only in imported_externals. With no
    // account/report join their ownership is unknown: references only.
    for external in try await database.importedReelFiles() {
      if try await database.reelTraits(kind: "external", videoID: external.id) != nil { continue }
      do {
        let url = URL(fileURLWithPath: external.path)
        let transcript = try await Self.traitTranscript(
          videoID: external.videoID, database: database)
        let detectors = try await Self.traitDetectors(
          url: url, videoID: external.videoID, database: database)
        let traits = try await ReelTraitExtractor.traits(
          for: url, caption: nil, transcript: transcript, cachedDetectors: detectors)
        try await database.saveReelTraits(
          traits, kind: "external", videoID: external.id, reference: true)
        computed += 1
      } catch is CancellationError { throw CancellationError() } catch {
        log("Imported reel traits unavailable: \(error.localizedDescription)")
      }
    }
    try await database.rebuildReelOutcomes(account: account)
    log("Computed traits for \(computed) reels; downloaded \(downloaded)")
  }

  /// Also covers an individual template/reference download, without waiting for another Refresh.
  func cacheDownloadedReelTraits(
    media: IGMediaRecord, account: IGAccountRecord, file: URL,
    database: Database, log: @escaping @Sendable (String) -> Void
  ) async throws {
    do {
      let traits = try await ReelTraitCache.traits(
        kind: "instagram", videoID: String(media.id), database: database, reference: !account.isOwn
      ) {
        try await ReelTraitExtractor.traits(for: file, caption: media.caption, transcript: nil)
      }
      let inputs = try await database.fetchIGReportInputs(account: account)
      if let report = inputs.media.first(where: {
        $0.mediaID == media.mediaID || $0.shortcode == media.mediaID
          || ($0.permalink != nil && $0.permalink == media.permalink)
      }), report.isReel {
        try await database.saveReelTraits(
          traits, kind: "imported", videoID: String(report.id), reference: !account.isOwn)
        try await database.rebuildReelOutcomes(account: account)
      }
      try await database.saveReelTraits(
        traits, kind: "external", videoID: media.mediaID, reference: !account.isOwn)
    } catch is CancellationError { throw CancellationError() } catch {
      log("Downloaded reel traits unavailable: \(error.localizedDescription)")
    }
  }

  private static func traitTranscript(videoID: Int64?, database: Database) async throws
    -> [TranscriptSegment]?
  {
    guard let videoID else { return nil }
    let rows = try await database.fetchTranscripts(videoID: videoID).filter { !$0.isTranslation }
    return rows.isEmpty
      ? nil : rows.map { TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text) }
  }

  private static func traitDetectors(url: URL, videoID: Int64?, database: Database) async throws
    -> VideoDetectors?
  {
    guard let videoID else { return nil }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    // Same fingerprint as AppStore.cachedDetectors, so imported library files reuse its cache.
    let fingerprint =
      "1:\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    if let cached = try await database.cachedDetectors(videoID: videoID, fingerprint: fingerprint) {
      return cached
    }
    let fresh = try await FFmpeg.detectors(of: url, duration: FFmpeg.duration(of: url))
    try await database.cacheDetectors(fresh, videoID: videoID, fingerprint: fingerprint)
    return fresh
  }
}
