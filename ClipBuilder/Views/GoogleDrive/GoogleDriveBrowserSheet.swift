import SwiftUI

/// The same browser serves downloads and the upload folder picker.
struct GoogleDriveBrowserSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var uploadMedia: [DriveMedia] = []
    @State private var profile = ""
    @State private var projectID: Int64?
    @State private var projectName = ""
    @State private var location = "My Drive"
    @State private var breadcrumbs: [DriveFile] = []
    @State private var files: [DriveFile] = []
    @State private var drives: [DriveSharedDrive] = []
    @State private var driveID: String?
    @State private var search = ""
    @State private var videosOnly = true
    @State private var selection: Set<String> = []
    @State private var alreadyHere: Set<String> = []
    @State private var nextPage: String?
    @State private var loading = false
    @State private var offline = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var newFolder = ""
    @State private var uploadFolderLoaded = false
    private var isUpload: Bool { !uploadMedia.isEmpty }
    private var client: GoogleDriveClient? { store.googleDrive.client(profile: profile) }

    var body: some View {
        VStack {
            if store.googleDrive.states[profile]?.isConnected == true {
                browserContents
            } else {
                GoogleDriveConnectionPrompt(
                    profile: profile, allowsInlineConnect: true, beforeOpeningSettings: { dismiss() })
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 740, idealWidth: 860, minHeight: 480, idealHeight: 580)
        .task {
            profile = store.activeProfile.profileName
            projectID = store.activeProjectID
            projectName = store.activeProject?.name ?? "Home"
            if let database = store.database {
                await store.googleDrive.attach(profile: store.activeProfile, database: database)
                alreadyHere = Set((try? await database.fetchVideos())?.compactMap(\.driveFileID) ?? [])
            }
            await load()
        }
        .onChange(of: location) {
            breadcrumbs = []
            driveID = nil
            reload()
        }
        .onChange(of: videosOnly) { reload() }
        .task(id: search) {
            guard !profile.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                await load()
            } catch {}
        }
        .onChange(of: store.googleDrive.states[profile]) { reload() }
        .task(id: offline) {
            guard offline else { return }
            while offline && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await load()
            }
        }
    }

    private var browserContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isUpload ? "Upload to Google Drive" : "Add from Google Drive").font(.headline)
                Spacer()
                Text(projectName).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Location", selection: $location) {
                    ForEach(["My Drive", "Shared with me", "Shared drives", "Recent"], id: \.self) { Text($0) }
                }.labelsHidden().frame(width: 180)
                TextField("Search Drive", text: $search).textFieldStyle(.roundedBorder)
                if !isUpload { Toggle("Videos only", isOn: $videosOnly) }
            }
            HStack {
                Button(location) {
                    breadcrumbs = []
                    driveID = nil
                    reload()
                }
                ForEach(Array(breadcrumbs.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    Button(folder.name) {
                        breadcrumbs = Array(breadcrumbs.prefix(index + 1))
                        reload()
                    }
                }
            }.buttonStyle(.plain).lineLimit(1)
            if let error {
                HStack {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Retry") { reload() }
                    OpenGoogleDriveSettingsButton(beforeOpening: { dismiss() })
                }
            }
            if location == "Shared drives", breadcrumbs.isEmpty {
                List(drives) { drive in
                    Button {
                        driveID = drive.id
                        breadcrumbs = [
                            DriveFile(id: drive.id, name: drive.name, mimeType: "application/vnd.google-apps.folder")
                        ]
                        reload()
                    } label: {
                        Label(drive.name, systemImage: "externaldrive")
                    }.buttonStyle(.plain)
                }
            } else {
                List(files, selection: $selection) { file in
                    HStack(spacing: 10) {
                        if file.isFolder {
                            Image(systemName: "folder.fill").frame(width: 44)
                        } else {
                            AsyncImage(url: file.thumbnailLink.flatMap(URL.init(string:))) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                Image(systemName: "film")
                            }
                            .frame(width: 44, height: 32).accessibilityHidden(true)
                        }
                        VStack(alignment: .leading) {
                            Text(file.name).lineLimit(1)
                            if alreadyHere.contains(file.id) {
                                Label("Already here", systemImage: "cloud.fill").font(.caption).foregroundStyle(
                                    .secondary)
                            }
                        }
                        Spacer()
                        if !file.isFolder {
                            Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                                .monospacedDigit()
                        }
                        Text(
                            file.modifiedTime.flatMap { ISO8601DateFormatter().date(from: $0) }?.formatted(
                                date: .abbreviated, time: .omitted) ?? ""
                        )
                        .foregroundStyle(.secondary)
                        if file.isFolder {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Folder")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if file.isFolder { open(file) } }
                    .tag(file.id)
                }
                .overlay {
                    if files.isEmpty && !loading && error == nil {
                        ContentUnavailableView(
                            "No files", systemImage: "folder",
                            description: Text("Choose another folder or change your search."))
                    }
                }
            }
            HStack {
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                if nextPage != nil { Button("Load More") { Task { await load(append: true) } }.disabled(loading) }
                Spacer()
                if isUpload {
                    TextField("New folder name", text: $newFolder).frame(width: 180)
                    Button("Create Folder") { Task { await createFolder() } }.disabled(
                        newFolder.trimmingCharacters(in: .whitespaces).isEmpty || loading || currentFolder == nil)
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isUpload ? "Upload Here" : "Download \(selectedFiles.count) Files") { Task { await accept() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || (isUpload ? currentFolder == nil : selectedFiles.isEmpty))
            }
        }
    }

    private var selectedFiles: [DriveFile] {
        files.filter {
            selection.contains($0.id) && !$0.isFolder
                && ($0.mimeType.hasPrefix("video/")
                    || Analyzer.videoExtensions.contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()))
        }
    }
    private var currentFolder: DriveFile? {
        breadcrumbs.last
            ?? (location == "My Drive"
                ? DriveFile(id: "root", name: "My Drive", mimeType: "application/vnd.google-apps.folder") : nil)
    }
    private func open(_ folder: DriveFile) {
        breadcrumbs.append(folder)
        selection = []
        reload()
    }
    private func reload() { Task { await load() } }
    private func load(append: Bool = false) async {
        guard store.googleDrive.states[profile]?.isConnected == true, let client else { return }
        let token = UUID()
        requestID = token
        loading = true
        error = nil
        defer { if requestID == token { loading = false } }
        do {
            if isUpload && !uploadFolderLoaded {
                breadcrumbs = [try await store.googleDrive.uploadFolder(profile: profile, project: projectName)]
                uploadFolderLoaded = true
            }
            if location == "Shared drives", breadcrumbs.isEmpty {
                let page = try await client.sharedDrives(pageToken: append ? nextPage : nil)
                guard requestID == token else { return }
                drives = append ? drives + page.drives : page.drives
                nextPage = page.next
            } else {
                let page = try await client.list(
                    folder: currentFolder?.id, search: search, videosOnly: videosOnly,
                    sharedWithMe: location == "Shared with me" && breadcrumbs.isEmpty,
                    driveID: driveID, pageToken: append ? nextPage : nil, foldersOnly: isUpload)
                guard requestID == token else { return }
                files =
                    append
                    ? files + page.files.filter { item in !files.contains(where: { $0.id == item.id }) } : page.files
                nextPage = page.nextPageToken
                if !append { selection = [] }
            }
            offline = false
        } catch {
            guard requestID == token else { return }
            offline = error as? GoogleDriveError == .offline
            self.error = GoogleDriveError.message(for: error)
            await store.googleDrive.refreshState(profile: profile)
        }
    }
    private func createFolder() async {
        guard let client, let folder = currentFolder else { return }
        do {
            let created = try await client.createFolder(
                name: newFolder.trimmingCharacters(in: .whitespaces), parent: folder.id)
            newFolder = ""
            breadcrumbs.append(created)
            await load()
        } catch { self.error = GoogleDriveError.message(for: error) }
    }
    private func accept() async {
        do {
            if isUpload, let folder = currentFolder {
                try await store.googleDrive.rememberFolder(folder, profile: profile)
                store.googleDrive.enqueueUpload(
                    uploadMedia, folder: folder.id, profile: profile, projectID: projectID, projectName: projectName)
            } else {
                store.googleDrive.enqueue(
                    files: selectedFiles, profile: profile, projectID: projectID, projectName: projectName)
            }
            dismiss()
        } catch { self.error = GoogleDriveError.message(for: error) }
    }
}
