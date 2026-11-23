import Foundation
import SwiftUI

/// A visible control; metadata reads are cancellable and never start rendering.
/// On a row it shows only where a drawing exists and opens it; the list's
/// own Draw button (`.toolbar`) starts a new one on the selected clip.
struct TelestrationRowMenu: View {
    enum Style { case row, toolbar }

    @Environment(AppStore.self) private var store
    @Environment(\.requestTelestration) private var present
    let videoID: Int64
    let videoURL: URL
    let range: ClosedRange<Double>
    var areaName: String? = nil
    var companions: [TelestrationSource] = []
    var style = Style.row
    @State private var records: [Int64: [TelestrationRecord]] = [:]
    @State private var opening = false
    @State private var openingTask: Task<Void, Never>?

    private var sources: [TelestrationSource] {
        // Keep distinct areas even when they show the same file and range.
        var seen = Set<TelestrationSource>()
        return ([.init(videoID: videoID, videoURL: videoURL, name: videoURL.lastPathComponent, range: range, areaName: areaName)] + companions)
            .filter { source in
                seen.insert(TelestrationSource(videoID: source.videoID, videoURL: source.videoURL, name: "", range: source.range, areaName: source.areaName)).inserted
            }
    }
    private func local(_ source: TelestrationSource) -> Bool {
        store.videos.first { $0.id == source.videoID }?.isLocal ?? FootageAvailability.isLocal(path: source.videoURL.path)
    }
    private func drawings(_ source: TelestrationSource) -> [TelestrationRecord] {
        return (records[source.videoID] ?? []).filter { record in
            source.range.contains(record.drawing.time)
        }
    }
    private var count: Int { Set(sources.flatMap { drawings($0).map(\.id) }).count }
    private struct LoadKey: Equatable {
        var profile: Int
        var revision: Int
        var sources: [TelestrationSource]
    }

    private func tooShort(_ source: TelestrationSource) -> Bool {
        source.range.upperBound - source.range.lowerBound < 2 * StrikeFreezeRules.minimumPiece
    }

    var body: some View {
        if present != nil {
            switch style {
            // The stack is there with no drawing too: it is what loads them.
            case .row: control(ZStack { if count > 0 { rowMenu } })
            case .toolbar: control(newButton)
            }
        }
    }

    private func control(_ view: some View) -> some View {
        view
            .disabled(!sources.contains(where: local) || opening)
            .onDisappear { openingTask?.cancel(); openingTask = nil; opening = false }
            .task(id: LoadKey(profile: store.profileGeneration, revision: store.telestrationRevision, sources: sources)) {
                records = [:]
                guard let database = store.database else { return }
                do {
                    let loaded = try await database.fetchTelestrations(videoIDs: Array(Set(sources.map(\.videoID))))
                    guard !Task.isCancelled else { return }
                    records = loaded
                } catch { ErrorLog.record("Drawings", error.localizedDescription) }
            }
    }

    /// The list's Draw button: a new drawing on the selected clip, or a
    /// choice of picture when the clip shows several.
    @ViewBuilder private var newButton: some View {
        let label = Label("Draw", systemImage: "pencil.tip").labelStyle(.iconOnly)
        if sources.count == 1, let source = sources.first {
            Button { open(nil, on: source) } label: { label }
                .fixedSize()
                .disabled(tooShort(source))
                .accessibilityLabel("Draw on the selected clip")
                .help(!local(source) ? "The video must be on this Mac to draw on it"
                      : tooShort(source) ? "This clip is under half a second: too short to draw on"
                      : "Draw on the selected clip: pause or slow the picture and draw on it")
        } else {
            Menu {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    Button { open(nil, on: source) } label: {
                        Text("New drawing on \(source.menuName)").lineLimit(1).fixedSize()
                    }
                    .disabled(tooShort(source) || !local(source))
                }
            } label: { label }
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Draw on the selected clip")
            .help(sources.contains(where: local) ? "Draw on the selected clip: choose the picture to draw on"
                  : "The video must be on this Mac to draw on it")
        }
    }

    /// On a row that has drawings: their count, and a menu to open one.
    private var rowMenu: some View {
            Menu {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    let tooShort = tooShort(source)
                    Button { open(nil, on: source) } label: {
                        Text(companions.isEmpty
                            ? (tooShort ? "New drawing (clip under half a second)" : "New drawing")
                            : "New drawing on \(source.menuName)")
                            .lineLimit(1).fixedSize()
                    }
                    .disabled(tooShort || !local(source))
                    ForEach(drawings(source)) { record in
                        Button { open(record, on: source) } label: {
                            Text((companions.isEmpty ? "" : "Edit drawing on \(source.menuName) · ")
                                + TelestrationSource.drawingSummary(record.drawing))
                                .lineLimit(1).fixedSize()
                        }
                        .disabled(!local(source))
                        if !companions.isEmpty {
                            Button(role: .destructive) {
                                opening = true
                                openingTask = Task {
                                    defer { opening = false }
                                    if let error = await store.deleteTelestration(id: record.id) { failed(error) }
                                }
                            } label: {
                                Text("Delete drawing on \(source.menuName) · \(TelestrationSource.drawingTime(record.drawing.time))")
                                    .lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "pencil.tip")
                    Text("\(count)").font(.caption2).monospacedDigit()
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 4).background(.quaternary, in: Capsule())
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Drawings")
            .help(sources.contains(where: local) ? "This clip's drawings: open one to change it"
                  : "The video must be on this Mac to draw on it")
    }

    private func open(_ existing: TelestrationRecord?, on source: TelestrationSource) {
        guard local(source), !opening else { return }
        opening = true
        let generation = store.profileGeneration
        openingTask = Task {
            defer { opening = false }
            // Shared with the Reel player; applies the source's preferred transform.
            guard let aspect = await KeptClipsPlayer.displayAspect(of: source.videoURL) else {
                guard !Task.isCancelled, generation == store.profileGeneration else { return }
                failed("Could not read this video's picture size.")
                return
            }
            let duration = await FFmpeg.duration(of: source.videoURL)
            guard !Task.isCancelled, generation == store.profileGeneration, duration > 0 else { return }
            present?(TelestratorRequest(videoURL: source.videoURL, videoID: source.videoID, duration: duration,
                aspect: aspect, range: TelestratorRequest.drawable(source.range, keeping: existing?.drawing.time),
                clipRange: source.range,
                initialTime: existing?.drawing.time ?? TelestratorRequest.initialTime(source.range),
                existing: existing, profileGeneration: generation))
        }
    }

    private func failed(_ message: String) {
        ErrorLog.record("Drawings", message)
        store.presentNotice("Drawing", message)
    }
}
