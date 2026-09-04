import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// File ▸ Export Resources…: pick categories, then save one zip.
struct ResourceExportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<ResourceCategory> = Set(ResourceCategory.allCases)
    @State private var inventory: [ResourceCategory: [ResourceItem]] = [:]
    @State private var status: String?
    @State private var isRunning = false
    @State private var exportedURL: URL?

    private var selectedBytes: Int64 {
        selected.reduce(0) { $0 + (inventory[$1] ?? []).reduce(0) { $0 + $1.bytes } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceL) {
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                Text("Export Resources")
                    .font(.headline)
                Text("Bundles the chosen items into one zip you can import on another Mac or keep as a backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Theme.spaceS) {
                ForEach(ResourceCategory.allCases) { category in
                    let items = inventory[category] ?? []
                    let count = category == .preferences ? ResourceBundle.preferences().count : items.count
                    Toggle(isOn: Binding(
                        get: { selected.contains(category) },
                        set: { on in if on { selected.insert(category) } else { selected.remove(category) } })) {
                        HStack(spacing: Theme.spaceS) {
                            Image(systemName: category.systemImage)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            Text(category.title)
                            Spacer()
                            Text(countLabel(count: count, bytes: items.reduce(0) { $0 + $1.bytes }, category: category))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(count == 0 || isRunning)
                }
            }

            if let status {
                HStack(spacing: Theme.spaceS) {
                    if isRunning { ProgressView().controlSize(.small) }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if let exportedURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                    }
                }
                Spacer()
                Text(selectedBytes > 0 ? ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file) : "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(exportedURL == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || isRunning || exportedURL != nil)
            }
        }
        .padding(Theme.spaceL)
        .frame(width: 460)
        .onAppear {
            inventory = ResourceBundle.inventory()
            selected = Set(ResourceCategory.allCases.filter { category in
                category == .preferences ? !ResourceBundle.preferences().isEmpty : !(inventory[category] ?? []).isEmpty
            })
        }
    }

    private func countLabel(count: Int, bytes: Int64, category: ResourceCategory) -> String {
        guard count > 0 else { return "none" }
        let noun: String
        switch category {
        case .preferences: noun = count == 1 ? "setting" : "settings"
        case .profiles: noun = count == 1 ? "profile" : "profiles"
        default: noun = count == 1 ? "item" : "items"
        }
        let size = bytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : ""
        return "\(count) \(noun)\(size)"
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "ClipBuilder Resources.zip"
        panel.canCreateDirectories = true
        panel.title = "Export Resources"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isRunning = true
        status = "Preparing…"
        let categories = selected
        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    try ResourceBundle.export(categories: categories, to: destination) { message in
                        Task { @MainActor in status = message }
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            isRunning = false
            switch result {
            case .success:
                status = "Exported to \(destination.lastPathComponent)."
                exportedURL = destination
            case .failure(let error):
                status = nil
                store.presentError("Export failed", error)
            }
        }
    }
}

/// File ▸ Import Resources…: preview a bundle, choose what to bring in and
/// how conflicts resolve, then import.
struct ResourceImportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let zipURL: URL

    @State private var preview: ResourceBundlePreview?
    @State private var selected: Set<ResourceCategory> = []
    @State private var policy: ResourceImportPolicy = .skip
    @State private var status: String?
    @State private var isRunning = false
    @State private var summary: ResourceImportSummary?
    @State private var loadError: String?

    private var hasConflicts: Bool {
        guard let preview else { return false }
        return selected.contains { (preview.conflicts[$0] ?? 0) > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceL) {
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                Text("Import Resources")
                    .font(.headline)
                Text(zipURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let preview {
                    Text("Exported \(preview.manifest.exportedAt.formatted(date: .abbreviated, time: .shortened)) by Clip Builder \(preview.manifest.appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            } else if let preview {
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    ForEach(preview.manifest.categories) { category in
                        let count = category == .preferences ? preview.preferenceKeys : (preview.items[category] ?? []).count
                        let conflicts = preview.conflicts[category] ?? 0
                        Toggle(isOn: Binding(
                            get: { selected.contains(category) },
                            set: { on in if on { selected.insert(category) } else { selected.remove(category) } })) {
                            HStack(spacing: Theme.spaceS) {
                                Image(systemName: category.systemImage)
                                    .frame(width: 18)
                                    .foregroundStyle(.secondary)
                                Text(category.title)
                                Spacer()
                                Text(count == 0 ? "none"
                                     : conflicts > 0 ? "\(count) · \(conflicts) already here" : "\(count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(conflicts > 0 ? .orange : .secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(count == 0 || isRunning || summary != nil)
                    }
                }

                if summary == nil {
                    VStack(alignment: .leading, spacing: Theme.spaceXS) {
                        Picker("When an item already exists", selection: $policy) {
                            ForEach(ResourceImportPolicy.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .disabled(isRunning)
                        Text(policy.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if selected.contains(.preferences) {
                            Text("Preferences always replace the current values.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                HStack(spacing: Theme.spaceS) {
                    ProgressView().controlSize(.small)
                    Text("Reading the bundle…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let status {
                HStack(spacing: Theme.spaceS) {
                    if isRunning { ProgressView().controlSize(.small) }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button(summary == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(summary == nil ? .cancelAction : .defaultAction)
                if summary == nil {
                    Button("Import") { runImport() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview == nil || selected.isEmpty || isRunning)
                }
            }
        }
        .padding(Theme.spaceL)
        .frame(width: 480)
        .task { await load() }
        .onDisappear {
            if let preview { ResourceBundle.discard(preview) }
        }
    }

    private func load() async {
        let url = zipURL
        let result: Result<ResourceBundlePreview, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try ResourceBundle.inspect(url)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let loaded):
            preview = loaded
            selected = Set(loaded.manifest.categories.filter { category in
                category == .preferences ? loaded.preferenceKeys > 0 : !(loaded.items[category] ?? []).isEmpty
            })
        case .failure(let error):
            loadError = error.userMessage
        }
    }

    private func runImport() {
        guard let preview else { return }
        isRunning = true
        status = "Importing…"
        let categories = selected
        let chosenPolicy = policy
        Task {
            let result: Result<ResourceImportSummary, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try ResourceBundle.importBundle(preview, categories: categories,
                                                                   policy: chosenPolicy) { message in
                        Task { @MainActor in status = message }
                    })
                } catch {
                    return .failure(error)
                }
            }.value
            isRunning = false
            switch result {
            case .success(let done):
                summary = done
                status = done.message
                store.resourcesDidChange(done)
            case .failure(let error):
                status = nil
                store.presentError("Import failed", error)
            }
        }
    }
}
