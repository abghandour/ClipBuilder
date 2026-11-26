import Foundation

nonisolated enum SyncLabsError: LocalizedError, Equatable {
    /// No key saved on this Mac.
    case missingKey
    /// 401 or 403: the key is wrong or revoked.
    case keyRejected(String?)
    /// 402: no subscription, or the plan cannot start another generation.
    case billing(String?)
    case tooLong(seconds: Double, limit: Double)
    case tooManyRequests
    case rejected(String)
    case http(Int, String?)
    /// The generation ended without a usable video.
    case failed(String)
    case timedOut

    var userMessage: String {
        switch self {
        case .missingKey:
            "Add your Sync Labs key in Settings > AI > Lip Sync"
        case .keyRejected(let message):
            "Sync Labs rejected this key" + (message.map { ": \($0)" } ?? ".")
                + " Copy it again from sync.so › Settings › API Keys and paste the whole key."
        case .billing(let message):
            "Sync Labs will not start this video" + (message.map { ": \($0)" } ?? ".")
                + " Check your plan and billing at sync.so."
        case .tooLong(let seconds, let limit):
            "This reel is \(LipSync.length(seconds)) long and your Sync Labs plan allows \(LipSync.length(limit)). "
                + "Shorten the reel or change plan at sync.so."
        case .tooManyRequests:
            "Sync Labs is busy with other videos from this account. Wait for them to finish and try again."
        case .rejected(let message):
            "Sync Labs rejected this video: \(message)"
        case .http(let status, let message):
            "Sync Labs returned HTTP \(status)" + (message.map { ": \($0)" } ?? ". Try again in a moment.")
        case .failed(let message):
            message
        case .timedOut:
            "Sync Labs did not finish in time. The video may still complete on sync.so; the reel was kept without lip sync."
        }
    }

    var errorDescription: String? { userMessage }
}

/// The Sync Labs calls a lip-sync pass makes. Every network touch goes
/// through one of three closures, so tests answer for the server.
nonisolated struct SyncLabsClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias Uploader = @Sendable (URLRequest, URL) async throws -> HTTPURLResponse
    typealias Downloader = @Sendable (URL, URL) async throws -> Void

    static let base = URL(string: "https://api.sync.so")!

    let apiKey: String
    var transport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
    var uploader: Uploader = { request, file in
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return response
    }
    var downloader: Downloader = { source, destination in
        let (temporary, response) = try await URLSession.shared.download(from: source)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw SyncLabsError.failed("The synced video could not be downloaded from Sync Labs.")
        }
        try FileManager.default.copyItemReplacing(at: temporary, to: destination)
        try? FileManager.default.removeItem(at: temporary)
    }

    /// Who the key belongs to and what its plan allows. The cheap key check.
    func account() async throws -> LipSync.Account {
        try JSONDecoder().decode(LipSync.Account.self, from: await send(path: "/v2/account"))
    }

    /// Sends a local file to Sync Labs' storage and returns its asset id:
    /// a presigned address, the bytes, then the registration.
    @concurrent
    func upload(_ file: URL, as name: String, contentType: String, type: String) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw SyncLabsError.failed("There is nothing to upload: \(name) is empty.") }
        let presigned = try JSONDecoder().decode(LipSync.Upload.self, from: await send(path: "/v2/assets/upload",
            body: JSONEncoder().encode(LipSync.UploadRequest(fileName: name, contentType: contentType, size: size))))
        guard let address = URL(string: presigned.uploadUrl), address.scheme == "https" else {
            throw SyncLabsError.failed("Sync Labs gave no address to upload to.")
        }
        // The presigned address carries its own authority: no API key here.
        var put = URLRequest(url: address)
        put.httpMethod = "PUT"
        put.timeoutInterval = 1800
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let response = try await uploader(put, file)
        guard (200..<300).contains(response.statusCode) else {
            throw SyncLabsError.http(response.statusCode, "The upload of \(name) was refused.")
        }
        let asset = try JSONDecoder().decode(LipSync.Asset.self, from: await send(path: "/v2/assets",
            body: JSONEncoder().encode(LipSync.AssetRequest(url: presigned.url, type: type, name: name))))
        guard !asset.id.isEmpty else { throw SyncLabsError.failed("Sync Labs did not register \(name).") }
        return asset.id
    }

    /// Starts a generation. `idempotencyKey` makes a resent request the same job, never a second bill.
    func generate(_ request: LipSync.GenerateRequest, idempotencyKey: String) async throws -> LipSync.Generation {
        try JSONDecoder().decode(LipSync.Generation.self, from: await send(path: "/v2/generate",
            body: JSONEncoder().encode(request), headers: ["Idempotency-Key": idempotencyKey]))
    }

    func generation(_ id: String) async throws -> LipSync.Generation {
        // One path component, never a path or query a server answer chose.
        guard !id.isEmpty, let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_"))) else {
            throw SyncLabsError.failed("Sync Labs returned no generation id.")
        }
        return try JSONDecoder().decode(LipSync.Generation.self, from: await send(path: "/v2/generate/" + escaped))
    }

    func download(_ source: URL, to destination: URL) async throws {
        try await downloader(source, destination)
    }

    private func send(path: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        guard !apiKey.isEmpty else { throw SyncLabsError.missingKey }
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await transport(request)
        guard !(200..<300).contains(response.statusCode) else { return data }
        throw Self.error(status: response.statusCode, body: data)
    }

    static func error(status: Int, body: Data) -> SyncLabsError {
        let message = (try? JSONDecoder().decode(LipSync.Failure.self, from: body))?.text
        switch status {
        case 401, 403: return .keyRejected(message)
        case 402: return .billing(message)
        case 429: return .tooManyRequests
        case 400, 413, 422: return .rejected(message ?? "the request was not accepted (HTTP \(status)).")
        default: return .http(status, message)
        }
    }
}
