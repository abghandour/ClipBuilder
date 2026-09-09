import SwiftUI

struct ReelModelsLearnedSection: View {
  @Environment(AppStore.self) private var store
  @State private var reports: [ReelModelEvaluation] = []
  @State private var available: [LearnedModelArtifact] = []
  @State private var busy = false
  @State private var status = ""
  var body: some View {
    GroupBox("Trained models") {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          "Models rank and score your footage. Evaluate locally, then enable each model in Settings → AI."
        ).foregroundStyle(.secondary)
        ForEach(ReelModelItem.allCases, id: \.rawValue) { item in
          let report = reports.first { $0.item == item }
          Text(report?.summary ?? "\(item.rawValue): not evaluated")
          Text(
            item.isEnabled(config: store.settings.ai)
              ? "Enabled · publishes with learned preferences after passing local evaluation"
              : "Off · does not score or publish"
          )
          .font(.caption).foregroundStyle(.secondary)
          if let report {
            Text(
              report.origin.map {
                "Adopted from \($0) · \(report.localEvaluation ? "evaluated locally" : "local evaluation required")"
              } ?? "Trained on this profile"
            )
            .font(.caption)
            Text("Version \(report.version) · \(report.date.formatted())").font(.caption)
            if !report.importance.isEmpty {
              Text("What moves results for this account").font(.headline)
              ForEach(report.importance.sorted { $0.value > $1.value }.prefix(8), id: \.key) {
                feature in
                Text(
                  "\(feature.key): \(feature.value.formatted(.number.precision(.fractionLength(3))))"
                ).font(.caption)
              }
            }
          }
          Button("Evaluate \(item.rawValue)") {
            busy = true
            Task {
              defer { busy = false }
              do {
                status = try await store.evaluateReelModel(item).summary
                reload()
              } catch { status = error.localizedDescription }
            }
          }.disabled(busy)
        }
        ForEach(available) { model in
          HStack {
            Text("\(model.item.rawValue) v\(model.version) from \(model.contributor)")
            Button("Adopt and evaluate") { adopt(model) }.disabled(busy)
          }
        }
        if !status.isEmpty { Text(status).textSelection(.enabled) }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }.task(id: store.activeProfile.profileName) { reload() }
  }
  private func reload() {
    reports = ReelModelItem.allCases.compactMap { store.reelModelStore?.report($0) }
    let library = LearnedLibrary(profile: store.activeProfile.profileName)
    available = library.documents().filter {
      $0.contributor != LearnedPreferences.contributor(profile: store.activeProfile)
        && !store.activeProfile.learnedSharing.mutedContributors.contains($0.contributor)
    }.flatMap { document in
      ReelModelItem.allCases.compactMap { item -> LearnedModelArtifact? in
        let file = library.directory.appendingPathComponent(document.contributor)
          .appendingPathComponent("models/" + item.rawValue + ".json")
        guard let data = try? Data(contentsOf: file),
          let model = try? JSONDecoder().decode(LearnedModelArtifact.self, from: data),
          (try? model.validate()) != nil
        else { return nil }
        return model
      }
    }
  }
  private func adopt(_ model: LearnedModelArtifact) {
    guard let destination = store.reelModelStore else { return }
    let source = LearnedLibrary().directory.appendingPathComponent(model.contributor)
      .appendingPathComponent(
        "models/\(model.item.filename)-v\(model.version).\(model.item.artifactExtension)")
    busy = true
    Task {
      defer {
        busy = false
        reload()
      }
      do {
        try model.adopt(from: source, to: destination)
        status = try await store.evaluateReelModel(model.item).summary
      } catch { status = error.localizedDescription }
    }
  }
}
