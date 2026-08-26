import SwiftUI

/// Fight research for one video, opened from the Analyze page's column:
/// confirm the guessed fight identity, run the crawl + summarize, then read
/// and EDIT the distilled story that the wizards will inject.
struct FightResearchSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let video: VideoRecord

    // Identity (user-confirmable before crawling).
    @State private var fighters = ""
    @State private var event = ""
    @State private var fightDate = ""
    // Editable story fields, flattened from the summary JSON.
    @State private var sentiment = ""
    @State private var angle = ""
    @State private var arc = ""
    @State private var hookLine = ""
    @State private var overlayLinesText = ""       // one per line
    @State private var controversy = ""
    @State private var talkingPointsText = ""      // "moment | why fans care" per line
    @State private var sources: [String] = []
    @State private var researchedAt: Date?

    @State private var running = false
    @State private var progress: [String] = []
    @State private var errorMessage: String?
    @State private var loadedRecord = false

    private var hasResearch: Bool { loadedRecord }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Fight Research", systemImage: "text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Text(video.filename)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(16)
            Divider()

            Form {
                Section("Fight") {
                    TextField("Fighters", text: $fighters,
                              prompt: Text("Jan Blachowicz vs Carlos Ulberg"))
                    TextField("Event", text: $event, prompt: Text("UFC 330 — optional"))
                    TextField("Date", text: $fightDate, prompt: Text("March 2026 — optional"))
                    if !hasResearch {
                        Text("Guessed from the video's named people, extracted outcome, and filename — correct it before running. Fighters must be named in the People section for good guesses.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        run()
                    } label: {
                        if running {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Researching…")
                            }
                        } else {
                            Label(hasResearch ? "Refresh Research" : "Run Research",
                                  systemImage: "globe")
                        }
                    }
                    .disabled(running || fighters.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Crawl the sources configured in Settings → Profile → Fight Research Sources (plain web requests — Reddit's public API, site-scoped search), then summarize fan reactions with the Fight research model from Settings → AI")
                    if !progress.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(progress.suffix(6).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                if hasResearch {
                    Section("Story — editable, the wizards use exactly this") {
                        LabeledContent("Researched") {
                            Text(researchedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                                .foregroundStyle(.secondary)
                        }
                        if !sources.isEmpty {
                            LabeledContent("Sources fetched") {
                                Text(Set(sources).sorted().joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        editor("Fan sentiment", text: $sentiment, height: 44)
                        editor("Story angle", text: $angle, height: 44)
                        editor("Arc (setup → escalation → payoff)", text: $arc, height: 60)
                        TextField("Hook line (ALL CAPS)", text: $hookLine)
                        editor("Overlay lines — one per line", text: $overlayLinesText, height: 70)
                        editor("Talking points — one per line: moment | why fans care",
                               text: $talkingPointsText, height: 80)
                        editor("Controversy (empty = none)", text: $controversy, height: 44)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                if hasResearch {
                    Button("Save Edits") {
                        store.saveFightResearchEdits(videoID: video.id,
                                                     fightLabel: fighters,
                                                     event: event,
                                                     fightDate: fightDate,
                                                     summaryJSON: rebuiltSummaryJSON())
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 640)
        .modalCloseButton { dismiss() }
        .task { await load() }
    }

    private func editor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.body)
                .frame(height: height)
        }
    }

    private func load() async {
        if let record = store.fightResearch[video.id] {
            apply(record)
        } else {
            let identity = await store.guessFightIdentity(video: video)
            fighters = identity.fighters
            event = identity.event
            fightDate = identity.date
        }
    }

    private func apply(_ record: FightResearchRecord) {
        loadedRecord = true
        fighters = record.fightLabel
        event = record.event
        fightDate = record.fightDate
        sources = record.sources
        researchedAt = record.researchedAt
        let summary = record.summary
        sentiment = summary["sentiment"] as? String ?? ""
        controversy = summary["controversy"] as? String ?? ""
        let story = summary["story"] as? [String: Any] ?? [:]
        angle = story["angle"] as? String ?? ""
        arc = story["arc"] as? String ?? ""
        hookLine = story["hook_line"] as? String ?? ""
        overlayLinesText = (story["overlay_lines"] as? [String] ?? []).joined(separator: "\n")
        talkingPointsText = (summary["talking_points"] as? [[String: Any]] ?? [])
            .compactMap { point in
                guard let moment = point["moment"] as? String else { return nil }
                let why = point["why_fans_care"] as? String ?? ""
                return why.isEmpty ? moment : "\(moment) | \(why)"
            }
            .joined(separator: "\n")
    }

    /// The edited fields back into the summary JSON shape the wizards read.
    private func rebuiltSummaryJSON() -> String {
        let overlayLines = overlayLinesText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let talkingPoints: [[String: Any]] = talkingPointsText.split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let moment = parts.first, !moment.isEmpty else { return nil }
                var point: [String: Any] = ["moment": moment]
                if parts.count > 1 { point["why_fans_care"] = parts[1] }
                return point
            }
        var summary: [String: Any] = [
            "fight": fighters + (event.isEmpty ? "" : " (\(event))"),
            "sentiment": sentiment,
            "talking_points": talkingPoints,
            "story": [
                "angle": angle,
                "arc": arc,
                "hook_line": hookLine,
                "overlay_lines": overlayLines,
            ],
        ]
        summary["controversy"] = controversy.isEmpty ? NSNull() : controversy
        let data = (try? JSONSerialization.data(withJSONObject: summary,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func run() {
        errorMessage = nil
        progress = []
        running = true
        let identity = FightResearchService.Identity(fighters: fighters, event: event,
                                                     date: fightDate)
        Task {
            do {
                let record = try await store.runFightResearch(video: video,
                                                              identity: identity) { message in
                    Task { @MainActor in progress.append(message) }
                }
                apply(record)
            } catch {
                errorMessage = error.userMessage
            }
            running = false
        }
    }
}
