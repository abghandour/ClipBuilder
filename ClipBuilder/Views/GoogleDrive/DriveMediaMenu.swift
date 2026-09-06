import SwiftUI

struct DriveMediaMenu: View {
    @Environment(AppStore.self) private var store
    let media: [DriveMedia]
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
    var body: some View {
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
            Label(
                copies.isEmpty ? "Google Drive" : copies.allSatisfy(\.offloaded) ? "In Drive" : "Local and Drive",
                systemImage: copies.isEmpty
                    ? "icloud.and.arrow.up" : copies.allSatisfy(\.offloaded) ? "cloud" : "cloud.fill")
        }
        .menuStyle(.borderlessButton)
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

struct DriveActivityRows: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        let uploads = store.googleDrive.jobs.filter {
            $0.operation == .upload && ($0.status == .running || $0.status == .waiting)
        }
        if uploads.count > 1 { Text("Uploading \(uploads.count) files").font(.caption) }
        ForEach(store.googleDrive.jobs.filter { $0.status != .complete }) { job in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(job.projectName) · \(job.title)").lineLimit(1).help(job.title)
                if store.googleDrive.states[job.profile]?.isConnected != true {
                    GoogleDriveConnectionPrompt(profile: job.profile)
                    Button("Stop") { store.googleDrive.stop(job.id) }
                } else {
                    HStack {
                        Text(job.message).lineLimit(2)
                        Spacer(minLength: 0)
                        if job.status == .running || job.status == .reconnect || job.status == .waiting {
                            Button("Stop") { store.googleDrive.stop(job.id) }
                        } else {
                            Button("Resume") { store.googleDrive.resume(job.id) }
                            if job.message == GoogleDriveError.offline.localizedDescription {
                                Button("Stop") { store.googleDrive.stop(job.id) }
                            }
                        }
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
}
