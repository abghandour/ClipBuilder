import Foundation

/// Closed model manifest: no training examples, local paths, IG rows or machine switches.
nonisolated struct LearnedModelArtifact: Codable, Sendable, Identifiable {
  var item: ReelModelItem
  var version: Int
  var contributor: String
  var files: [String]
  var hash: String
  var evaluation: ReelModelEvaluation
  var id: String { contributor + ":" + item.rawValue }

  static var importanceKeys: Set<String> {
    Set(ReelTraits().features.keys).union([
      "position", "score", "excitement", "personPresence", "tagCount", "bRoll", "action",
      "highlight",
    ])
  }
  static var metricKeys: Set<String> {
    Set(ReelOutcome.targets).union([
      "rankCorrelation", "agreement", "topTenPrecision", "preferenceAgreement",
    ])
  }

  func validate() throws {
    guard !contributor.isEmpty, contributor == LearnedRedaction.text(contributor),
      !contributor.contains("/"), !contributor.contains("\\"), contributor != ".",
      contributor != "..",
      version > 0, evaluation.traitsVersion == ReelTraits.version, evaluation.item == item,
      evaluation.version == version,
      evaluation.artifactHash == hash,
      Set(evaluation.importance.keys).isSubset(of: Self.importanceKeys),
      Set(evaluation.metrics.keys).isSubset(of: Self.metricKeys),
      evaluation.origin == evaluation.origin.map { LearnedRedaction.text($0) },
      files.count > 0, files.count <= 500,
      Set(files).count == files.count,
      files.allSatisfy(Self.safePath), hash.count == 64
    else { throw LearnedRedaction.Failure.invalidDocument }
  }
  static func safePath(_ path: String) -> Bool {
    !path.isEmpty && path.count < 400 && !path.contains("\\") && !path.contains(":")
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
      }
  }
  static func build(
    item: ReelModelItem, store: ReelModelStore, contributor: String, config: AIConfig
  ) throws -> LearnedModelArtifact? {
    guard item.isEnabled(config: config),
      let report = store.report(item),
      report.passed, report.localEvaluation
    else { return nil }
    let artifact = store.artifact(item, version: report.version)
    guard try ReelModelStore.hash(artifact) == report.artifactHash else { return nil }
    let enumerator = FileManager.default.enumerator(
      at: artifact, includingPropertiesForKeys: [.isRegularFileKey])
    var paths: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        paths.append(String(url.path.dropFirst(artifact.path.count + 1)))
      }
    }
    var publicReport = report
    publicReport.localEvaluation = false
    publicReport.importance = report.importance.filter { Self.importanceKeys.contains($0.key) }
    publicReport.metrics = report.metrics.filter { Self.metricKeys.contains($0.key) }
    publicReport.origin = report.origin.map { LearnedRedaction.text($0) }
    let result = LearnedModelArtifact(
      item: item, version: report.version, contributor: contributor,
      files: paths.sorted(), hash: report.artifactHash, evaluation: publicReport)
    try result.validate()
    return result
  }
  func adopt(from downloaded: URL, to store: ReelModelStore) throws {
    try validate()
    guard try ReelModelStore.hash(downloaded) == hash else {
      throw LearnedRedaction.Failure.invalidDocument
    }
    let destination = store.artifact(item, version: version)
    // An explicit adoption preserves any existing local artifact under a backup name.
    try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.moveItem(
        at: destination, to: store.root.appendingPathComponent("backup-\(UUID()).mlmodelc"))
    }
    try FileManager.default.copyItem(at: downloaded, to: destination)
    var report = evaluation
    report.origin = contributor
    report.localEvaluation = false
    report.passed = false
    report.metrics = [:]
    report.holdoutCount = 0
    try store.save(report)
  }
}
