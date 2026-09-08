import AppKit
import AuthenticationServices
import Network
import Security

/// Google Desktop OAuth uses a loopback redirect. ASWebAuthenticationSession owns
/// the browser; the listener owns the callback. Only a matching state completes it.
@MainActor
final class GoogleDriveSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(String, String), Error>?
    private var timeout: Task<Void, Never>?
    private var state = ""
    private var redirectURI = ""

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    func connect(auth: GoogleDriveAuth, profile: String) async throws {
        let configuration = await auth.configuration
        guard configuration.isConfigured else { throw GoogleDriveError.notConfigured }
        guard continuation == nil else { return }
        let verifier = try randomToken()
        state = try randomToken()
        let (code, redirect) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do { try start(configuration: configuration, verifier: verifier) } catch { finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
        try await auth.completeSignIn(code: code, verifier: verifier, redirectURI: redirect, profile: profile)
    }

    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GoogleDriveError.invalidResponse
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func start(configuration: GoogleOAuthConfiguration, verifier: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] status in
            // Bind the weak captures to lets before hopping actors: a weak
            // capture is a mutable box the task closure may not share.
            guard let self else { return }
            let listener = listener
            Task { @MainActor in
                switch status {
                case .ready:
                    guard let port = listener?.port else {
                        self.finish(.failure(GoogleDriveError.invalidResponse))
                        return
                    }
                    self.openBrowser(configuration: configuration, verifier: verifier, port: port.rawValue)
                case .failed(let error): self.finish(.failure(error))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            guard let self else { return }
            Task { @MainActor in self.receiveCallback(connection, buffered: Data()) }
        }
        listener.start(queue: .main)
        // A strong capture is fine: finish() cancels this task, so the
        // sign-in object lives at most until the callback or the timeout.
        timeout = Task {
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            finish(.failure(GoogleDriveError.cancelled))
        }
    }

    private func receiveCallback(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            // Same weak-capture rule as the listener handlers: bind first.
            guard let self else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                guard let data, error == nil, self.continuation != nil else {
                    connection.cancel()
                    return
                }
                let combined = buffered + data
                guard combined.count <= 16_384 else {
                    connection.cancel()
                    return
                }
                guard let request = String(data: combined, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if complete { connection.cancel() } else { self.receiveCallback(connection, buffered: combined) }
                    return
                }
                guard request.hasPrefix("GET "),
                    let target = request.components(separatedBy: " ").dropFirst().first,
                    let url = URLComponents(string: "http://127.0.0.1\(target)"),
                    url.path == "/oauth2callback",
                    url.queryItems?.first(where: { $0.name == "state" })?.value == self.state
                else {
                    connection.cancel()
                    return
                }
                let body = "You can close this window and return to Clip Builder."
                let response =
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(
                    content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if let code = url.queryItems?.first(where: { $0.name == "code" })?.value {
                    self.finish(.success((code, self.redirectURI)))
                } else {
                    self.finish(.failure(GoogleDriveError.cancelled))
                }
            }
        }
    }

    private func openBrowser(configuration: GoogleOAuthConfiguration, verifier: String, port: UInt16) {
        redirectURI = "http://127.0.0.1:\(port)/oauth2callback"
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            "client_id": configuration.clientID, "redirect_uri": redirectURI,
            "response_type": "code", "scope": GoogleDriveAuth.scopes.joined(separator: " "),
            "state": state, "code_challenge": GoogleDriveAuth.challenge(verifier),
            "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent",
        ]
        .map { URLQueryItem(name: $0.key, value: $0.value) }
        let session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: nil) { [weak self] _, error in
            Task { @MainActor in
                if error != nil { self?.finish(.failure(GoogleDriveError.cancelled)) }
            }
        }
        self.session = session
        session.presentationContextProvider = self
        if !session.start() { finish(.failure(GoogleDriveError.cancelled)) }
    }

    private func finish(_ result: Result<(String, String), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        session?.cancel()
        session = nil
        continuation.resume(with: result)
    }
}
