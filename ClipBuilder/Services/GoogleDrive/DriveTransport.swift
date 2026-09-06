import Foundation

/// Injected by tests; production requests run on URLSession, outside the UI actor.
nonisolated protocol DriveTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionDriveTransport: DriveTransport {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw GoogleDriveError.invalidResponse }
            return (data, response)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw GoogleDriveError.offline
        }
    }
}
