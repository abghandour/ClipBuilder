import SwiftUI

/// The same browser serves downloads and the upload folder picker.
struct GoogleDriveBrowserSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var uploadMedia: [DriveMedia] = []
    var pickFolder: ((DriveFile, String) async throws -> Void)? = nil
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
    @State private var filter = DriveBrowserFilter()
    @State private var flat = false
    @State private var subtree: DriveSubtreeWalker.Result?
    @State private var subtreeProgress: DriveSubtreeWalker.Progress?
    @State private var subtreeError: String?
    @State private var subtreeToken = UUID()
    @State private var folderCache: CachingDriveFolderLister?
    /// Derived from `subtree` and `filter`; rebuilt only when either changes
    /// so rows never recompute them.
    @State private var folderMatches: [String: Int]?
    @State private var flatPaths: [String: String] = [:]
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
    private var isFolderPicker: Bool { isUpload || pickFolder != nil }
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
            folderCache = nil
            reload()
        }
        .onChange(of: videosOnly) { reload() }
        .task(id: subtreeKey) { await scanSubtree() }
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
                Text(
                    pickFolder != nil
                        ? "Choose asset library folder" : isUpload ? "Upload to Google Drive" : "Add from Google Drive"
                ).font(.headline)
                Spacer()
                Text(projectName).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Location", selection: $location) {
                    ForEach(["My Drive", "Shared with me", "Shared drives", "Recent"], id: \.self) { Text($0) }
                }.labelsHidden().frame(width: 180)
                TextField("Search Drive", text: $search).textFieldStyle(.roundedBorder)
                if !isFolderPicker { Toggle("Videos only", isOn: $videosOnly) }
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
            if !isFolderPicker { filterBar }
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
                List(shownFiles, selection: $selection) { file in
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
                            HStack(spacing: 8) {
                                if alreadyHere.contains(file.id) {
                                    Label("Already here", systemImage: "cloud.fill")
                                }
                                if flat, let path = flatPaths[file.id], !path.isEmpty {
                                    Label(path, systemImage: "folder").lineLimit(1)
                                }
                                if let detail = Self.videoDetail(file) { Text(detail) }
                                if file.isFolder, let count = folderMatches?[file.id] {
                                    Text("\(count) matching")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
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
                    if shownFiles.isEmpty && !loading && error == nil {
                        if files.isEmpty {
                            ContentUnavailableView(
                                "No files", systemImage: "folder",
                                description: Text("Choose another folder or change your search."))
                        } else {
                            ContentUnavailableView(
                                "No matching videos", systemImage: "line.3.horizontal.decrease.circle",
                                description: Text(filterEmptyHint))
                                .opacity(scanning ? 0 : 1)
                        }
                    }
                }
            }
            HStack {
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                if nextPage != nil { Button("Load More") { Task { await load(append: true) } }.disabled(loading) }
                if scanning, let progress = subtreeProgress {
                    ProgressView().controlSize(.small)
                    Text("Scanning subfolders… \(progress.foldersScanned) folders, \(progress.filesFound) files")
                        .foregroundStyle(.secondary).lineLimit(1)
                } else if let subtreeError {
                    Text(subtreeError).foregroundStyle(.secondary).lineLimit(1)
                } else if filter.isActive || flat, !loading {
                    Text(filterSummary).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isFolderPicker {
                    if let folder = currentFolder, !folder.canAddChildren {
                        Text("View only").foregroundStyle(.secondary)
                            .help("You can't add folders here. Ask the owner for edit access.")
                    }
                    TextField("New folder name", text: $newFolder).frame(width: 180)
                    Button("Create Folder") { Task { await createFolder() } }.disabled(
                        newFolder.trimmingCharacters(in: .whitespaces).isEmpty || loading
                            || currentFolder?.canAddChildren != true)
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(
                    pickFolder != nil
                        ? "Choose Folder" : isUpload ? "Upload Here" : "Download \(selectedFiles.count) Files"
                ) { Task { await accept() } }
                .keyboardShortcut(.defaultAction)
                .disabled(loading || (isFolderPicker ? currentFolder == nil : selectedFiles.isEmpty))
            }
        }
    }

    private var filterBar: some View {
        HStack {
            Picker("Shape", selection: $filter.shape) {
                ForEach(DriveBrowserFilter.Shape.allCases, id: \.self) { Text($0.label) }
            }.labelsHidden().frame(width: 150)
            Picker("Size", selection: $filter.minimumSize) {
                ForEach(DriveBrowserFilter.MinimumSize.allCases, id: \.self) { Text($0.label) }
            }.labelsHidden().frame(width: 130)
            Picker("Sort", selection: $filter.sort) {
                ForEach(DriveBrowserFilter.Sort.allCases, id: \.self) { Text($0.label) }
            }.frame(width: 160)
            if filter.isActive {
                Button("Clear") { filter = DriveBrowserFilter() }
            }
            Spacer()
            Toggle("All files in subfolders", isOn: $flat)
                .disabled(!search.isEmpty)
                .help(search.isEmpty
                    ? "List every file below this folder in one flat list, with its folder path."
                    : "Search already looks across all of Drive.")
        }
        .onChange(of: filter) { refreshDerived() }
        .onChange(of: flat) { refreshDerived() }
    }

    // MARK: - Filtering, flat view, and folder hiding

    /// The scan runs when the flat view is on or a filter must decide which
    /// folders to hide. Any change to what is listed restarts it.
    private struct SubtreeKey: Equatable {
        var enabled: Bool
        var seedIDs: [String]
        var videosOnly: Bool
        var driveID: String?
    }
    private var needsSubtree: Bool { !isFolderPicker && search.isEmpty && (flat || filter.isActive) }
    private var subtreeKey: SubtreeKey {
        SubtreeKey(enabled: needsSubtree, seedIDs: files.map(\.id), videosOnly: videosOnly, driveID: driveID)
    }
    private var scanning: Bool { needsSubtree && subtree == nil && subtreeError == nil }
    /// Recomputes the per-folder match counts and flat-view paths, then drops
    /// any selected file the new view no longer shows.
    private func refreshDerived() {
        if filter.isActive, !flat, let subtree {
            folderMatches = DriveSubtreeWalker.matchesByTopFolder(subtree.files, filter: filter)
        } else {
            folderMatches = nil
        }
        if flat, let subtree {
            flatPaths = Dictionary(subtree.files.map { ($0.id, $0.pathLabel) }, uniquingKeysWith: { a, _ in a })
        } else {
            flatPaths = [:]
        }
        selection = selection.filter { id in shownFiles.contains { $0.id == id } }
    }
    /// What the filter and sort see: the flat subtree, or the current folder.
    private var candidateFiles: [DriveFile] {
        if flat, let subtree { return subtree.files.map(\.file) }
        if flat { return files.filter { !$0.isFolder } }
        return files
    }
    private var filtered: DriveBrowserFilter.Result { filter.apply(to: candidateFiles) }
    private var shownFiles: [DriveFile] {
        let result = filtered.files
        // A filtered folder view hides folders with nothing below them that
        // matches. A truncated scan proves nothing about unscanned folders,
        // so every folder stays visible and only the counts are shown.
        guard let folderMatches, subtree?.truncated == false else { return result }
        return result.filter { !$0.isFolder || folderMatches[$0.id, default: 0] > 0 }
    }
    private var filterSummary: String {
        let videos = shownFiles.filter(\.isVideo).count
        let total = candidateFiles.filter(\.isVideo).count
        var text = flat ? "\(videos) of \(total) videos in subfolders" : "\(videos) of \(total) loaded videos"
        if let folderMatches {
            let inside = folderMatches.values.reduce(0, +)
            let hidden = files.filter(\.isFolder).count - folderMatches.count
            text += " · \(inside) more in \(folderMatches.count) folders"
            if hidden > 0, subtree?.truncated == false { text += " · \(hidden) folders hidden" }
        }
        if filtered.unknownShapeHidden > 0 {
            text += " · \(filtered.unknownShapeHidden) without dimensions yet"
        }
        if let subtree, subtree.truncated {
            text += " · stopped after \(subtree.foldersScanned) folders (all folders kept), open a smaller folder"
        }
        if nextPage != nil { text += " · Load More to search further" }
        return text
    }
    private var filterEmptyHint: String {
        var hint = "No videos match the shape or size filter."
        if filtered.unknownShapeHidden > 0 {
            hint += " \(filtered.unknownShapeHidden) hidden because Drive hasn't reported their dimensions yet."
        }
        if nextPage != nil { hint += " Load More may find some." }
        return hint
    }
    /// `.task(id:)` bodies keep running after the id changes, so every write
    /// back checks the token taken at the start.
    private func scanSubtree() async {
        let token = UUID()
        subtreeToken = token
        subtree = nil
        subtreeProgress = nil
        subtreeError = nil
        refreshDerived()
        guard needsSubtree, let client else { return }
        if folderCache == nil { folderCache = CachingDriveFolderLister(base: client) }
        guard let lister = folderCache else { return }
        let seed = files
        let walker = DriveSubtreeWalker()
        let videosOnly = videosOnly
        let driveID = driveID
        subtreeProgress = DriveSubtreeWalker.Progress()
        do {
            let result = try await walker.walk(seed: seed, lister: lister, videosOnly: videosOnly, driveID: driveID) {
                progress in
                Task { @MainActor in
                    guard subtreeToken == token else { return }
                    subtreeProgress = progress
                }
            }
            guard subtreeToken == token else { return }
            subtree = result
            subtreeProgress = nil
            refreshDerived()
        } catch is CancellationError {
        } catch {
            guard subtreeToken == token else { return }
            subtreeProgress = nil
            subtreeError = "Couldn't read subfolders: \(GoogleDriveError.message(for: error))"
        }
    }
    static func videoDetail(_ file: DriveFile) -> String? {
        guard file.isVideo, let metadata = file.videoMediaMetadata else { return nil }
        var parts: [String] = []
        if let width = metadata.width, let height = metadata.height, width > 0, height > 0 {
            parts.append("\(width)×\(height) \(metadata.shape.label.lowercased())")
        }
        if let seconds = metadata.durationSeconds {
            parts.append(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var selectedFiles: [DriveFile] {
        candidateFiles.filter { selection.contains($0.id) && $0.isVideo }
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
                    driveID: driveID, pageToken: append ? nextPage : nil, foldersOnly: isFolderPicker)
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
            if let pickFolder, let folder = currentFolder {
                let breadcrumb = ([location] + breadcrumbs.map(\.name)).joined(separator: " › ")
                try await pickFolder(folder, breadcrumb)
            } else if isUpload, let folder = currentFolder {
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
