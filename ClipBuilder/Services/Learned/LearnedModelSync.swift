import Foundation

@MainActor extension AssetSyncExecutor {
  func syncLearnedModels(
    contributor: String, database: Database, library: LearnedLibrary,
    config: AIConfig
  ) async throws {
    let store = ReelModelStore(
      databasePath: database.path,
      reports: database.path.deletingLastPathComponent().appendingPathComponent(
        "on-device-agreement"))
    let builds = try ReelModelItem.allCases.compactMap {
      try LearnedModelArtifact.build(
        item: $0, store: store, contributor: contributor, config: config)
    }
    let learned = try await client.findOrCreateFolder(name: "learned", parent: journal.homeID)
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(
      "learned-model-\(UUID())")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let key =
      "learnedModelReceipts." + LearnedPreferences.stableID(journal.homeID + "|" + contributor)
    let stored = try await database.driveSetting(key) ?? "{}"
    var receipts =
      (try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8))) ?? [:]
    if !builds.isEmpty {
      let own = try await client.findOrCreateFolder(name: contributor, parent: learned.id)
      let models = try await client.findOrCreateFolder(name: "models", parent: own.id)
      for manifest in builds {
        let name =
          "\(manifest.item.filename)-v\(manifest.version).\(manifest.item.artifactExtension)"
        let modelFolder = try await client.findOrCreateFolder(name: name, parent: models.id)
        var folders = ["": modelFolder.id]
        for relative in manifest.files {
          try Task.checkCancellation()
          let parts = relative.split(separator: "/").map(String.init)
          var parent = ""
          for part in parts.dropLast() {
            let path = parent.isEmpty ? part : parent + "/" + part
            if folders[path] == nil {
              guard let parentID = folders[parent] else { throw LearnedRedaction.Failure.invalidDocument }
              let folder = try await client.findOrCreateFolder(name: part, parent: parentID)
              folders[path] = folder.id
            }
            parent = path
          }
          guard let folder = folders[parent], let filename = parts.last else {
            throw LearnedRedaction.Failure.invalidDocument
          }
          let receipt = name + "/" + relative
          receipts[receipt] = try await publishModelFile(
            store.artifact(manifest.item, version: manifest.version).appendingPathComponent(
              relative),
            filename: filename, folder: folder, receipt: receipts[receipt],
            path: contributor + "/models/" + receipt, database: database)
          try await database.setDriveSetting(
            key, value: String(decoding: JSONEncoder().encode(receipts), as: UTF8.self))
        }
        let manifestName = manifest.item.rawValue + ".json"
        let file = staging.appendingPathComponent(manifestName)
        try JSONEncoder().encode(manifest).write(to: file)
        receipts[manifestName] = try await publishModelFile(
          file, filename: manifestName, folder: models.id,
          receipt: receipts[manifestName], path: contributor + "/models/" + manifestName,
          database: database)
        try await database.setDriveSetting(
          key, value: String(decoding: JSONEncoder().encode(receipts), as: UTF8.self))
      }
    }
    // Only registered contributors from the Phase D merge, never arbitrary home folders.
    let folders = try await learnedFiles(in: learned.id)
    for peer in library.documents() where peer.contributor != contributor {
      guard let owner = folders.first(where: { $0.isFolder && $0.name == peer.contributor }),
        let models = try await learnedFiles(in: owner.id).first(where: {
          $0.isFolder && $0.name == "models"
        })
      else { continue }
      let files = try await learnedFiles(in: models.id)
      for item in ReelModelItem.allCases {
        guard let file = files.first(where: { !$0.isFolder && $0.name == item.rawValue + ".json" })
        else { continue }
        let data = try await learnedDownload(file, staging: staging)
        let manifest = try JSONDecoder().decode(LearnedModelArtifact.self, from: data)
        try manifest.validate()
        guard manifest.item == item, manifest.contributor == peer.contributor else {
          throw LearnedRedaction.Failure.invalidDocument
        }
        let artifactName = "\(item.filename)-v\(manifest.version).\(item.artifactExtension)"
        guard let remote = files.first(where: { $0.isFolder && $0.name == artifactName }) else {
          throw GoogleDriveError.notFound
        }
        let local = staging.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for path in manifest.files {
          var parent = remote.id
          let parts = path.split(separator: "/").map(String.init)
          for part in parts.dropLast() {
            guard
              let folder = try await learnedFiles(in: parent).first(where: {
                $0.isFolder && $0.name == part
              })
            else { throw GoogleDriveError.notFound }
            parent = folder.id
          }
          guard let part = parts.last,
            let payload = try await learnedFiles(in: parent).first(where: {
              !$0.isFolder && $0.name == part
            })
          else { throw GoogleDriveError.notFound }
          let target = local.appendingPathComponent(path)
          try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
          try await learnedDownload(payload, staging: staging).write(to: target)
        }
        guard try ReelModelStore.hash(local) == manifest.hash else {
          throw LearnedRedaction.Failure.invalidDocument
        }
        let destination = library.directory.appendingPathComponent(peer.contributor)
          .appendingPathComponent("models")
        guard
          destination.resolvingSymlinksInPath().path.hasPrefix(
            library.directory.resolvingSymlinksInPath().path + "/")
        else {
          throw LearnedRedaction.Failure.invalidDocument
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(artifactName)
        if FileManager.default.fileExists(atPath: target.path) {
          try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: local, to: target)
        try data.write(
          to: destination.appendingPathComponent(item.rawValue + ".json"), options: .atomic)
      }
    }
  }

  private func publishModelFile(
    _ source: URL, filename: String, folder: String, receipt: String?,
    path: String, database: Database
  ) async throws -> String {
    let files = try await learnedFiles(in: folder)
    let owned = files.first { $0.id == receipt && $0.name == filename && !$0.isFolder }?.id
    guard !files.contains(where: { $0.name == filename && $0.id != owned }) else {
      throw GoogleDriveError.conflict
    }
    let checkpoint = database.path.deletingLastPathComponent().appendingPathComponent(
      "drive-transfers"
    )
    .appendingPathComponent("model-\(LearnedPreferences.stableID(path)).json")
    let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let uploaded = try await transfers.assetTransfer(
      profile: profile, group: group, path: "learned/" + path, upload: true, size: Int64(size)
    ) { [self] progress in
      try await client.upload(
        file: source, folder: folder, checkpoint: checkpoint, replacingID: owned,
        verifyChecksum: true, progress: progress)
    }
    return uploaded.id
  }
}
