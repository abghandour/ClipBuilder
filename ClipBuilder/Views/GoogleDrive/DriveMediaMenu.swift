import SwiftUI

struct DriveMediaMenu: View {
    @Environment(AppStore.self) private var store
    let media: [DriveMedia]
    /// Icon only, and nothing at all for media with no Drive copy: the
    /// glyph alone says where the file is (outline cloud: Drive only;
    /// filled cloud: Drive and local). Used under scene cards.
    var compact = false
    @State private var uploading = false
    @State private var removing = false
    @State private var error: String?
    private var currentMedia: [DriveMedia] {
        media.map { item in
            if item.kind == .source { return store.videos.first(where: { $0.path == item.path })?.driveMedia ?? item }
            return store.generatedVideos.first(where: { $0.path == item.path })?.driveMedia ?? item
        }
    }
    private var uploadCandidates: [DriveMedia] { currentMedia.filter { $0.fileID == nil } }
    private var copies: [DriveMedia] { currentMedia.filter { $0.fileID != nil } }
    /// Every Drive copy is absent from disk, whether offloaded or simply gone.
    private var cloudOnly: Bool {
        copies.allSatisfy { $0.offloaded || !FileManager.default.fileExists(atPath: $0.path) }
    }
    var body: some View {
        if compact && copies.isEmpty {
            EmptyView()
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            if store.googleDrive.states[store.activeProfile.profileName]?.isConnected != true {
                Text(
                    store.googleDrive.states[store.activeProfile.profileName] == .notConfigured
                        ? "Google Drive isn't available in this copy of Clip Builder."
                        : "Connect Google Drive to use your videos.")
                OpenGoogleDriveSettingsButton()
                if !uploadCandidates.isEmpty { Button("Upload to Google Drive…") { uploading = true } }
            } else {
                if !uploadCandidates.isEmpty {
                    Button("Upload to Google Drive…") { uploading = true }
                }
                if let item = copies.first, copies.count == 1, let link = item.link, let url = URL(string: link) {
                    Link("Open in Drive", destination: url)
                }
                if !copies.isEmpty {
                    Button("Download Local Copy") {
                        let profile = store.activeProfile.profileName
                        Task {
                            do {
                                for item in copies { _ = try await store.googleDrive.fetch(item, profile: profile) }
                            } catch { self.error = GoogleDriveError.message(for: error) }
                        }
                    }
                    Button("Remove Local Copy…") { removing = true }
                        .disabled(
                            store.isAnalyzing || store.isBuilderRendering || store.isWizardRunning
                                || store.isPipelineRunning)
                }
            }
        } label: {
            let title = copies.isEmpty ? "Google Drive" : cloudOnly ? "In Drive" : "Local and Drive"
            let label = Label(title, systemImage: copies.isEmpty ? "icloud.and.arrow.up" : cloudOnly ? "cloud" : "cloud.fill")
            if compact {
                label.labelStyle(.iconOnly)
                    .help(cloudOnly ? "In Drive — no local copy" : "Local and Drive")
                    .accessibilityLabel(title)
            } else {
                label.labelStyle(.titleAndIcon)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact ? .hidden : .automatic)
        .fixedSize()
        .sheet(isPresented: $uploading) { GoogleDriveBrowserSheet(uploadMedia: uploadCandidates) }
        .confirmationDialog("Remove local media copies?", isPresented: $removing) {
            Button("Remove Local Copies", role: .destructive) {
                let profile = store.activeProfile.profileName
                Task {
                    do {
                        try await store.googleDrive.offload(copies, profile: profile)
                        store.refreshAll()
                    } catch { self.error = GoogleDriveError.message(for: error) }
                }
            }
        } message: {
            Text(
                copies.contains(where: \.shared)
                    ? "Shared files may become unavailable if their owner removes access. Scenes, transcripts, thumbnails and timelines stay on this Mac."
                    : "Only the media files are removed. Scenes, transcripts, thumbnails and timelines stay. Media downloads again when needed."
            )
        }
        .alert("Google Drive", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

/// Read-only Drive state for a list row: the cloud glyph without the menu.
/// Actions live in the screen's toolbar menu, which acts on the selection.
struct DriveMediaBadge: View {
    @Environment(AppStore.self) private var store
    let media: DriveMedia

    private var current: DriveMedia {
        if media.kind == .source { return store.videos.first(where: { $0.path == media.path })?.driveMedia ?? media }
        return store.generatedVideos.first(where: { $0.path == media.path })?.driveMedia ?? media
    }

    var body: some View {
        if current.fileID != nil {
            // The glyph reflects what is actually on disk: a copy the record
            // still calls local but that is gone shows the outline too.
            let cloudOnly = current.offloaded || !FileManager.default.fileExists(atPath: current.path)
            Image(systemName: cloudOnly ? "cloud" : "cloud.fill")
                .foregroundStyle(.secondary)
                .help(cloudOnly ? "In Drive — no local copy" : "Local and Drive")
                .accessibilityLabel(cloudOnly ? "In Drive" : "Local and Drive")
        }
    }
}

/// A small spinner beside the file name while its media is being fetched
/// from Drive.
struct DriveFetchIndicator: View {
    @Environment(AppStore.self) private var store
    let media: DriveMedia

    var body: some View {
        if let job = store.googleDrive.activeFetchJob(for: media, profile: store.activeProfile.profileName) {
            ProgressView()
                .controlSize(.mini)
                .help(job.status == .reconnect ? "Waiting for Google Drive to reconnect" : "Downloading from Drive…")
                .accessibilityLabel("Downloading from Drive")
        }
    }
}

struct DriveActivityRows: View {
    @Environment(AppStore.self) private var store
    var assetProfile: String? = nil
    var body: some View {
        let uploads = store.googleDrive.jobs.filter {
            $0.operation == .upload && ($0.status == .running || $0.status == .waiting)
        }
        if uploads.count > 1 { Text("Uploading \(uploads.count) files").font(.caption) }
        ForEach(
            store.googleDrive.jobs.filter { job in
                job.status != .complete && (assetProfile == nil || (job.isAsset && job.profile == assetProfile))
            }
        ) { job in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(job.projectName) · \(job.title)").lineLimit(1).help(job.title)
                if store.googleDrive.states[job.profile]?.isConnected != true {
                    GoogleDriveConnectionPrompt(profile: job.profile)
                    HStack {
                        Button("Stop") { store.googleDrive.stop(job.id) }
                        cancelButton(job)
                    }
                } else {
                    HStack {
                        Text(job.message).lineLimit(2)
                        Spacer(minLength: 0)
                        if job.status == .running || job.status == .reconnect || job.status == .waiting {
                            Button("Stop") { store.googleDrive.stop(job.id) }
                        } else {
                            if !job.isAsset {
                                Button("Resume") { store.googleDrive.resume(job.id) }
                            }
                            if job.message == GoogleDriveError.offline.localizedDescription {
                                Button("Stop") { store.googleDrive.stop(job.id) }
                            }
                        }
                        cancelButton(job)
                        if job.status == .reconnect {
                            OpenGoogleDriveSettingsButton()
                        }
                    }
                }
                if let total = job.totalBytes {
                    Text(
                        "\(Int(job.progress * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(Double(total) * job.progress), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
                    )
                    .monospacedDigit()
                }
                ProgressView(value: job.progress).accessibilityLabel("\(job.title) progress")
            }.font(.caption)
        }
    }

    private func cancelButton(_ job: DriveTransfer) -> some View {
        Button("Cancel") { store.googleDrive.cancel(job.id) }
            .help(job.operation == .upload
                  ? "Cancel this upload and forget its progress"
                    : job.isAsset
                        ? "Dismiss this report or stop this asset Refresh"
                        : "Cancel this download and delete the partial file")
    }
}
