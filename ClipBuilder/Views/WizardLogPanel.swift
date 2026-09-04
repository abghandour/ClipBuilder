import AppKit
import SwiftUI

/// Isolated from the configuration view so live log appends do not rebuild the
/// form while a generation is running.
struct WizardLogPanel: View {
    @Environment(AppStore.self) private var store
    @AppStorage("log.verbose") private var verboseLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack {
                Text("Generation Log")
                    .font(.headline)
                Toggle("Verbose", isOn: $verboseLog)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Log the full prompt sent to the AI for every call")
                LogActions(lines: store.wizardLog) { store.wizardLog = [] }
                Spacer()
                if store.isWizardRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding([.top, .horizontal])

            if let status = store.wizardStatus {
                progressCard(status)
                    .padding(.horizontal)
            }

            if let failure = store.wizardFailureMessage {
                failureCard(failure)
                    .padding(.horizontal)
            }

            if store.wizardLog.isEmpty {
                ContentUnavailableView(
                    "Ready",
                    systemImage: "wand.and.stars",
                    description: Text("Describe the reel you want, then the wizard plans it from your analyzed scenes and renders it to the Library."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            let log = store.wizardLog
                            ForEach(log.indices, id: \.self) { index in
                                logLine(log[index])
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    }
                    .onChange(of: store.wizardLog.count) {
                        guard !store.wizardLog.isEmpty else { return }
                        proxy.scrollTo(store.wizardLog.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func logLine(_ line: String) -> some View {
        if let video = Self.videoReference(from: line) {
            Button {
                if let url = store.generatedVideoURL(named: video.name) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("\(video.name) · \(video.duration)s — click to watch",
                      systemImage: "play.rectangle.fill")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Open the generated video")
        } else {
            Text(line)
                .font(.caption.monospaced())
                .foregroundStyle(line.hasPrefix("DONE:error") || line.hasPrefix("Error") ? .red : .secondary)
                .textSelection(.enabled)
        }
    }

    private static func videoReference(from line: String) -> (name: String, duration: String)? {
        guard line.hasPrefix("VIDEO:") else { return nil }
        let parts = line.dropFirst("VIDEO:".count).split(separator: ":")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    @ViewBuilder
    private func progressCard(_ status: WizardRunStatus) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.stage)
                    .font(.subheadline.weight(.medium))
                Spacer()
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsedString(from: status.stageChangedAt, to: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: status.fraction)
            if !status.detail.isEmpty {
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.cardPadding)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            Label("Generation failed", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Try Again") {
                    store.wizardFailureMessage = nil
                    store.retryWizard()
                }
                .controlSize(.small)
                Spacer()
                Button("Dismiss") {
                    store.wizardFailureMessage = nil
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        }
        .padding(Theme.cardPadding)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private static func elapsedString(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }
}
