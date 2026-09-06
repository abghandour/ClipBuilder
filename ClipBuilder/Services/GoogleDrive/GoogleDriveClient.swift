import CryptoKit
import Foundation

actor GoogleDriveClient {
    let auth: GoogleDriveAuth
    let profile: String
    private let transport: any DriveTransport
    private let chunkSize = 4 * 1024 * 1024  // multiple of Drive's 256 KiB upload unit
    private let downloadChunkSize = 16 * 1024 * 1024
    static let fields =
        "id,name,mimeType,size,modifiedTime,thumbnailLink,webViewLink,shared,ownedByMe,md5Checksum,version"

    init(auth: GoogleDriveAuth, profile: String, transport: any DriveTransport = URLSessionDriveTransport()) {
        self.auth = auth
        self.profile = profile
        self.transport = transport
    }

    nonisolated static func escapedQuery(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    func list(
        folder: String? = "root", search: String = "", videosOnly: Bool = true,
        sharedWithMe: Bool = false, driveID: String? = nil, pageToken: String? = nil,
        foldersOnly: Bool = false
    ) async throws -> DrivePage {
        var clauses = ["trashed = false"]
        if !search.isEmpty {
            clauses.append("name contains '\(Self.escapedQuery(search))'")
        } else if let folder {
            clauses.append("'\(Self.escapedQuery(folder))' in parents")
        }
        if sharedWithMe { clauses.append("sharedWithMe = true") }
        if foldersOnly {
            clauses.append("mimeType = 'application/vnd.google-apps.folder'")
        } else if videosOnly {
            clauses.append("(mimeType contains 'video/' or mimeType = 'application/vnd.google-apps.folder')")
        }
        var query = [
            "q": clauses.joined(separator: " and "), "pageSize": "100",
            "fields": "nextPageToken,files(\(Self.fields))", "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true", "orderBy": folder == nil ? "modifiedTime desc" : "folder,name",
        ]
        query["pageToken"] = pageToken
        if let driveID {
            query["corpora"] = "drive"
            query["driveId"] = driveID
        }
        return try await json("files", query: query)
    }

    func sharedDrives(pageToken: String? = nil) async throws -> (drives: [DriveSharedDrive], next: String?) {
        struct Page: Decodable {
            var drives: [DriveSharedDrive]
            var nextPageToken: String?
        }
        var query = ["pageSize": "100", "fields": "nextPageToken,drives(id,name)"]
        query["pageToken"] = pageToken
        let page: Page = try await json("drives", query: query)
        return (page.drives, page.nextPageToken)
    }

    func metadata(id: String) async throws -> DriveFile {
        try await json("files/\(encodeID(id))", query: ["fields": Self.fields, "supportsAllDrives": "true"])
    }

    func createFolder(name: String, parent: String) async throws -> DriveFile {
        var request = URLRequest(url: endpoint("files", query: ["fields": Self.fields, "supportsAllDrives": "true"]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder", "parents": [parent],
        ])
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    func findOrCreateFolder(name: String, parent: String) async throws -> DriveFile {
        var pageToken: String?
        repeat {
            let page = try await list(folder: parent, videosOnly: false, pageToken: pageToken, foldersOnly: true)
            if let existing = page.files.first(where: { $0.name == name }) { return existing }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return try await createFolder(name: name, parent: parent)
    }

    /// Range requests bound memory and make the .partial file the resume checkpoint.
    /// Metadata pins the revision; we never append bytes from a different version.
    func download(
        id: String, to destination: URL, transferFiles: DriveTransferFiles? = nil,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> DriveFile {
        let file = try await metadata(id: id)
        guard !file.isFolder, file.size != nil else { throw GoogleDriveError.invalidResponse }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let files = transferFiles ?? DriveTransferFiles(for: destination)
        try files.prepare()
        let partial = files.partial
        let checkpoint = files.checkpoint
        let identity = "\(id)|\(file.version ?? file.modifiedTime ?? "")|\(file.size ?? "")|\(file.md5Checksum ?? "")"
        let previous = try? String(contentsOf: checkpoint, encoding: .utf8)
        if previous != identity {
            if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
            try Data(identity.utf8).write(to: checkpoint, options: .atomic)
        }
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forUpdating: partial)
        defer { try? handle.close() }
        var offset = Int64(try handle.seekToEnd())
        if offset > file.byteCount {
            try handle.truncate(atOffset: 0)
            offset = 0
        }
        while offset < file.byteCount {
            try Task.checkCancellation()
            let end = min(file.byteCount - 1, offset + Int64(downloadChunkSize) - 1)
            var request = URLRequest(
                url: endpoint("files/\(encodeID(id))", query: ["alt": "media", "supportsAllDrives": "true"]))
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (data, response) = try await send(request)
            guard response.statusCode == 206,
                response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(file.byteCount)",
                data.count == Int(end - offset + 1)
            else {
                // A server may ignore Range for a small complete response.
                if response.statusCode == 200, offset == 0, data.count == file.byteCount {
                    try handle.write(contentsOf: data)
                    offset = file.byteCount
                    break
                }
                throw GoogleDriveError.invalidResponse
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            offset += Int64(data.count)
            await progress(Double(offset) / Double(max(1, file.byteCount)))
        }
        let current = try await metadata(id: id)
        guard current.version == file.version, current.md5Checksum == file.md5Checksum,
            current.size == file.size, current.modifiedTime == file.modifiedTime
        else {
            try? fm.removeItem(at: checkpoint)
            throw GoogleDriveError.conflict
        }
        if let expected = file.md5Checksum, try checksum(partial) != expected {
            try? fm.removeItem(at: checkpoint)
            throw GoogleDriveError.conflict
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) { throw GoogleDriveError.conflict }
        try fm.moveItem(at: partial, to: destination)
        try? fm.removeItem(at: checkpoint)
        await progress(1)
        return file
    }

    private struct UploadCheckpoint: Codable {
        var session: URL
        var signature: String
        var completed: DriveFile?
    }

    func upload(
        file: URL, folder: String, checkpoint: URL,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> DriveFile {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw GoogleDriveError.invalidResponse }
        let signature =
            "\(file.path)|\(size)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(folder)"
        var saved = (try? Data(contentsOf: checkpoint)).flatMap {
            try? JSONDecoder().decode(UploadCheckpoint.self, from: $0)
        }
        if saved?.signature != signature { saved = nil }
        if let completed = saved?.completed { return completed }
        var offset: Int64 = 0
        if let existing = saved {
            guard existing.session.scheme == "https", existing.session.host == "www.googleapis.com" else {
                throw GoogleDriveError.invalidResponse
            }
            var probe = URLRequest(url: existing.session)
            probe.httpMethod = "PUT"
            probe.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
            probe.setValue("0", forHTTPHeaderField: "Content-Length")
            let (data, response) = try await send(probe, allowing: [308, 404, 410])
            if response.statusCode == 200 || response.statusCode == 201 {
                let result = try JSONDecoder().decode(DriveFile.self, from: data)
                saved?.completed = result
                try saveCheckpoint(saved!, at: checkpoint)
                return result
            }
            if response.statusCode == 404 || response.statusCode == 410 {
                saved = nil
            } else {
                offset = try uploadOffset(response, total: size)
            }
        }
        if saved == nil {
            var url = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
            url.queryItems = [
                URLQueryItem(name: "uploadType", value: "resumable"),
                URLQueryItem(name: "fields", value: Self.fields),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
            ]
            var request = URLRequest(url: url.url!)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("\(size)", forHTTPHeaderField: "X-Upload-Content-Length")
            request.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "name": file.lastPathComponent, "parents": [folder],
            ])
            let (_, response) = try await send(request)
            guard let location = response.value(forHTTPHeaderField: "Location"), let session = URL(string: location),
                session.scheme == "https", session.host == "www.googleapis.com"
            else { throw GoogleDriveError.invalidResponse }
            saved = UploadCheckpoint(session: session, signature: signature)
            try saveCheckpoint(saved!, at: checkpoint)
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while offset < size {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: min(chunkSize, Int(size - offset))) ?? Data()
            guard !data.isEmpty else { throw GoogleDriveError.conflict }
            var request = URLRequest(url: saved!.session)
            request.httpMethod = "PUT"
            request.httpBody = data
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "bytes \(offset)-\(offset + Int64(data.count) - 1)/\(size)", forHTTPHeaderField: "Content-Range")
            let (body, response) = try await send(request, allowing: [308])
            if response.statusCode == 200 || response.statusCode == 201 {
                let result = try JSONDecoder().decode(DriveFile.self, from: body)
                saved?.completed = result
                try saveCheckpoint(saved!, at: checkpoint)
                await progress(1)
                return result
            }
            let next = try uploadOffset(response, total: size)
            guard next > offset, next <= offset + Int64(data.count) else { throw GoogleDriveError.invalidResponse }
            offset = next
            await progress(Double(offset) / Double(size))
        }
        throw GoogleDriveError.invalidResponse
    }

    private func uploadOffset(_ response: HTTPURLResponse, total: Int64) throws -> Int64 {
        guard let range = response.value(forHTTPHeaderField: "Range") else { return 0 }
        guard range.hasPrefix("bytes=0-"), let last = Int64(range.dropFirst(8)), last >= 0, last < total else {
            throw GoogleDriveError.invalidResponse
        }
        return last + 1
    }
    private func saveCheckpoint(_ value: UploadCheckpoint, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let bytes = try handle.read(upToCount: chunkSize), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func encodeID(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }
    private func endpoint(_ path: String, query: [String: String]) -> URL {
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/\(path)")!
        url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    private func json<T: Decodable & Sendable>(_ path: String, query: [String: String]) async throws -> T {
        let (data, _) = try await send(URLRequest(url: endpoint(path, query: query)))
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func send(_ original: URLRequest, allowing: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        var request = original
        request.setValue("Bearer \(try await auth.accessToken(profile: profile))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        if (200..<300).contains(response.statusCode) || allowing.contains(response.statusCode) {
            return (data, response)
        }
        switch response.statusCode {
        case 401:
            await auth.invalidate(profile: profile)
            throw GoogleDriveError.reconnect
        case 403:
            let body = String(decoding: data, as: UTF8.self)
            if body.contains("rateLimitExceeded") || body.contains("storageQuotaExceeded")
                || body.contains("dailyLimitExceeded") || body.contains("userRateLimitExceeded")
            {
                throw GoogleDriveError.quota
            }
            if body.contains("insufficientPermissions") || body.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") {
                await auth.invalidate(profile: profile)
                throw GoogleDriveError.reconnect
            }
            throw GoogleDriveError.notFound
        case 404: throw GoogleDriveError.notFound
        case 429: throw GoogleDriveError.quota
        default: throw GoogleDriveError.server(response.statusCode)
        }
    }
}
