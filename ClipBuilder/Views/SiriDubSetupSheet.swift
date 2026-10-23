import AppKit
import SwiftUI

/// One-time setup for dubbing with Siri voices in one language. macOS keeps
/// Siri voices away from third-party apps, so each voice needs its download
/// (System Settings) and a shortcut (Shortcuts app) that speaks for the app.
/// The sheet watches both and shows what is still missing; nothing long runs
/// here, and tool installs go through the store's job.
struct SiriDubSetupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let language: String
    @State private var status: SiriDubVoices.Status?
    @State private var openedShortcut: Set<String> = []
    @State private var showSteps: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up Siri voices for \(DubLanguageChoices.name(language))").font(.title3.bold())
            Text("Siri voices are not available to apps directly. Clip Builder speaks each dub line through a small shortcut in the Shortcuts app, one per voice. This is done once per voice.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let status {
                toolsStep(status)
                Divider()
                voicesStep(status)
                Divider()
                shortcutsStep(status)
            } else {
                ProgressView("Checking…").controlSize(.small)
            }
            HStack {
                if let status {
                    Text(status.isReady ? "Ready: \(status.ready.map(\.name).joined(separator: ", "))" : "Not ready yet")
                        .font(.caption).foregroundStyle(status.isReady ? .green : .secondary).lineLimit(1)
                }
                Spacer()
                Button("Check again") { Task { await refresh() } }
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await refresh()
            }
        }
    }

    private func step(_ number: Int, _ title: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? .green : .secondary)
            Text(title).font(.headline).lineLimit(1)
        }
    }

    private func toolsStep(_ status: SiriDubVoices.Status) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            step(1, "ffmpeg", done: status.ffmpegInstalled)
            if !status.ffmpegInstalled {
                HStack {
                    Text("Converts the spoken audio for the mixer.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(store.isInstallingTools ? "Installing…" : "Install") { store.installMissingTools() }
                        .disabled(store.isInstallingTools).controlSize(.small)
                }
            }
        }
    }

    private func voicesStep(_ status: SiriDubVoices.Status) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            step(2, "Siri voices downloaded", done: !status.downloaded.isEmpty)
            if status.downloaded.isEmpty {
                Text("None yet for \(DubLanguageChoices.name(language)).").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(status.downloaded.map { "\($0.name) (\(genderLabel($0.gender)))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Text("System voice ⓘ › \(DubLanguageChoices.name(language)) › Voice › search “Siri” › download.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open Spoken Content") { NSWorkspace.shared.open(SiriDubVoices.spokenContentSettingsURL) }
                    .controlSize(.small).lineLimit(1).fixedSize()
            }
        }
    }

    private func shortcutsStep(_ status: SiriDubVoices.Status) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            step(3, "Shortcuts", done: !status.downloaded.isEmpty && status.missingShortcuts.isEmpty)
            if status.downloaded.isEmpty {
                Text("Download a voice first.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(status.downloaded) { voice in
                let installed = status.shortcuts.contains(SiriDubVoices.shortcutName(for: voice.identifier))
                HStack {
                    Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(installed ? .green : .secondary)
                    Text(SiriDubVoices.shortcutName(for: voice.identifier)).lineLimit(1)
                    Spacer()
                    if !installed {
                        Button(openedShortcut.contains(voice.identifier) ? "Show steps" : "Add shortcut") { add(voice) }
                            .controlSize(.small).lineLimit(1).fixedSize()
                    }
                }
                if !installed, showSteps.contains(voice.identifier) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(SiriDubVoices.manualSteps(for: voice).enumerated()), id: \.offset) { item in
                            Text("\(item.offset + 1). \(item.element)")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 24)
                }
            }
        }
    }

    private func genderLabel(_ gender: DubVoiceGender) -> String {
        switch gender {
        case .male: "male"
        case .female: "female"
        case .unknown: "voice"
        }
    }

    /// A bundled signed shortcut imports with one click in Shortcuts. Without
    /// one, Shortcuts opens on a new shortcut and the steps appear here.
    private func add(_ voice: DubSynthesizer.Voice) {
        openedShortcut.insert(voice.identifier)
        if let bundled = SiriDubVoices.bundledShortcut(for: voice) {
            NSWorkspace.shared.open(bundled)
        } else {
            showSteps.insert(voice.identifier)
            if let url = URL(string: "shortcuts://create-shortcut") { NSWorkspace.shared.open(url) }
        }
    }

    private func refresh() async {
        let code = language
        status = await SiriDubVoices.status(language: code)
    }
}
