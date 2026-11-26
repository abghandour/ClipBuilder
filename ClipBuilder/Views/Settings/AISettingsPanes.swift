import SwiftUI

/// The panes of Settings › AI that are not one assistant's own. An
/// assistant's pane is stored as "cli.<provider key>".
nonisolated enum AISettingsPane: String, CaseIterable, Identifiable, Sendable {
    case routing, onDevice, learning, elevenLabs, lipSync

    /// Where the open pane is remembered; other views write it to open one.
    static let storageKey = "settings.ai.pane"
    static let setup: [AISettingsPane] = [.routing, .onDevice, .learning]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .routing: "Task Routing"
        case .onDevice: "On-Device"
        case .learning: "Learning"
        case .elevenLabs: "ElevenLabs"
        case .lipSync: "Lip Sync"
        }
    }

    var symbol: String {
        switch self {
        case .routing: "arrow.triangle.branch"
        case .onDevice: "cpu"
        case .learning: "graduationcap"
        case .elevenLabs: "waveform"
        case .lipSync: "mouth"
        }
    }

    static func providerID(_ key: String) -> String { "cli." + key }

    static func providerKey(_ id: String) -> String? {
        id.hasPrefix("cli.") ? String(id.dropFirst(4)) : nil
    }
}

/// A service's vendor mark, or the symbol when it has none in the catalog.
struct AISettingsServiceMark: View {
    var brand: AIProviderBrand?
    let symbol: String
    let size: CGFloat
    /// Increased on the selected sidebar row, where a brand tint would
    /// fight the highlight.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let brand, let asset = brand.logoAsset {
            if prominence == .increased {
                Image(asset).renderingMode(.template).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                ProviderLogo(brand: brand, size: size)
            }
        } else {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(.secondary)
        }
    }
}

/// One row of the AI sidebar: the vendor's mark (a symbol for the app's
/// own panes), the service's name, and a quiet warning when it cannot be
/// used yet.
struct AISettingsSidebarRow: View {
    static let assistantSymbol = "apple.terminal"

    let title: String
    let symbol: String
    var brand: AIProviderBrand?
    /// Why the service cannot run ("No key", "Not installed"); nil when it can.
    var issue: String?

    var body: some View {
        HStack(spacing: 8) {
            AISettingsServiceMark(brand: brand, symbol: symbol, size: 14)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if let issue {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .help(issue)
                    .accessibilityLabel(issue)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Opens a service's pane: whose it is and what the app uses it for.
struct AISettingsServiceHeader: View {
    let title: String
    let symbol: String
    var brand: AIProviderBrand?
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AISettingsServiceMark(brand: brand, symbol: symbol, size: 22)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings › AI › Lip Sync: the Sync Labs key and the model a dubbed reel is synced with.
struct LipSyncSettingsPane: View {
    @Environment(AppStore.self) private var store
    @State private var key = ""
    @State private var result: String?
    @State private var busy = false
    @State private var action: Action?

    private enum Action: Equatable {
        case save(UUID), check(UUID), remove(UUID)
    }

    private var model: LipSync.Model { LipSync.model(store.settings.ai.lipSync?.model) }

    var body: some View {
        Section {
            AISettingsServiceHeader(title: "Sync Labs", symbol: AISettingsPane.lipSync.symbol,
                detail: "Redraws the speakers' mouths to match a dub. Billed by Sync Labs (sync.so) per second of video.")
        }
        Section("Account") {
            SecureField("API key", text: $key, prompt: Text("Sync Labs API key"))
                .onSubmit { action = .save(UUID()) }
                .disabled(busy)
            LabeledContent("Connection") {
                HStack(spacing: 8) {
                    Button(busy ? "Checking…" : "Check") { action = .check(UUID()) }
                        .lineLimit(1).fixedSize()
                    Button("Remove key") { action = .remove(UUID()) }
                        .lineLimit(1).fixedSize()
                }
                .disabled(busy)
            }
            FormCaption(result ?? "Create a key at sync.so › Settings › API Keys, paste it here and press Return. It is saved securely on this Mac.")
        }
        Section {
            Picker("Model", selection: Binding(
                get: { model },
                set: {
                    var settings = store.settings.ai.lipSync ?? LipSyncSettings()
                    settings.model = $0.rawValue
                    store.settings.ai.lipSync = settings
                    // The render reads the model from disk, off the main actor.
                    store.saveSettings()
                }
            )) {
                ForEach(LipSync.Model.allCases) { model in
                    Text("\(model.label), \(LipSync.rateLabel(model))").tag(model)
                }
            }
            FormCaption(model.detail)
        } header: {
            Text("Quality")
        } footer: {
            Text("Turn on Lip sync under Dub in a reel's Audio settings. The finished reel and its audio are uploaded as “reel.mp4” and “reel.wav”; no title or name is sent. Prices are Sync Labs' list rates at 25 frames a second and may differ on your plan.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            do { key = try SyncLabsKeychain().read() ?? "" } catch { result = error.localizedDescription }
        }
        .task(id: action) { await update() }
    }

    private func update() async {
        guard let action else { return }
        busy = true
        defer {
            busy = false
            if self.action == action { self.action = nil }
            NotificationCenter.default.post(name: LipSyncService.keyChanged, object: nil)
        }
        do {
            let keychain = SyncLabsKeychain()
            switch action {
            case .remove:
                try keychain.write(nil)
                key = ""
                result = "Key removed from this Mac."
            case .save, .check:
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                try keychain.write(trimmed.isEmpty ? nil : trimmed)
                key = trimmed
                guard !trimmed.isEmpty else {
                    result = nil
                    return
                }
                result = "Key saved securely on this Mac."
                if case .check = action {
                    let account = try await SyncLabsClient(apiKey: trimmed).account()
                    try Task.checkCancellation()
                    result = "Connected: \(account.summary)"
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            result = (error as? SyncLabsError)?.userMessage ?? error.localizedDescription
        }
    }
}
