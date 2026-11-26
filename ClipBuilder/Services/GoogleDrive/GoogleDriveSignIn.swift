import AppKit
import Network
import Security

/// Google Desktop OAuth uses a loopback redirect: the consent page opens as
/// an ordinary tab of the default browser, and the listener owns the
/// callback. Only a matching state completes it.
///
/// Not ASWebAuthenticationSession: with a loopback redirect it never ends by
/// itself, its window outlives the attempt that opened it, and a second
/// attempt then shows no window while the old one redirects to a port
/// nobody listens on (seen 2026-11-25).
@MainActor
final class GoogleDriveSignIn {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(String, String), Error>?
    private var timeout: Task<Void, Never>?
    private var state = ""
    private var redirectURI = ""
    /// The token exchange that follows the browser's callback.
    private var exchange: Task<Void, Error>?
    private var gaveUp = false

    /// Ends a sign-in the user gave up on, in the browser wait or in the
    /// exchange after it; `connect` throws `cancelled`.
    func cancel() {
        gaveUp = true
        exchange?.cancel()
        finish(.failure(GoogleDriveError.cancelled))
    }

    func connect(auth: GoogleDriveAuth, profile: String) async throws {
        let configuration = await auth.configuration
        guard configuration.isConfigured else { throw GoogleDriveError.notConfigured }
        guard continuation == nil, exchange == nil else { return }
        gaveUp = false
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
        // Cancel between the browser's callback and here: nothing is exchanged.
        if gaveUp { throw GoogleDriveError.cancelled }
        let exchange = Task {
            try await auth.completeSignIn(code: code, verifier: verifier, redirectURI: redirect, profile: profile)
        }
        self.exchange = exchange
        defer { self.exchange = nil }
        do {
            try await withTaskCancellationHandler { try await exchange.value } onCancel: { exchange.cancel() }
        } catch {
            if gaveUp { throw GoogleDriveError.cancelled }
            throw error
        }
        // A cancel that arrives after the exchange saved the account is too
        // late: the profile is connected, and the caller shows it that way.
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
            finish(.failure(GoogleDriveError.signInTimedOut))
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
                let code = url.queryItems?.first(where: { $0.name == "code" })?.value
                // Google names what was granted: say so here, where the user is looking.
                let granted = url.queryItems?.first(where: { $0.name == "scope" })?.value
                let withoutDrive = code != nil && granted.map { !GoogleDriveAuth.hasDriveScopes($0) } == true
                let body = withoutDrive
                    ? "Google signed you in, but without access to Google Drive. Return to Clip Builder, choose Connect again and tick the Google Drive box on Google's permission page."
                    : code == nil ? "Google sign-in was not completed. You can close this tab and return to Clip Builder."
                    : "You can close this tab and return to Clip Builder."
                let response =
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(
                    content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if withoutDrive {
                    self.finish(.failure(GoogleDriveError.driveAccessNotGranted))
                } else if let code {
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
        if !NSWorkspace.shared.open(url.url!) { finish(.failure(GoogleDriveError.invalidResponse)) }
    }

    private func finish(_ result: Result<(String, String), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        continuation.resume(with: result)
    }
}
