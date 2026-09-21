import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

/// Each session has its own route table; parallel tests never touch the network or Keychain.
nonisolated final class InstagramTestTransport: @unchecked Sendable {
    enum Reply: Sendable {
        case json(String)
        case failure(URLError.Code)
    }

    let token = UUID().uuidString
    let replies: [String: Reply]
    private let recorded = Mutex<[URLRequest]>([])
    var requests: [URLRequest] { recorded.withLock { $0 } }

    init(_ replies: [String: Reply]) { self.replies = replies }

    func provider(id: String? = "ig-123") -> GraphAPIProvider {
        InstagramTestURLProtocol.transports.withLock { $0[token] = self }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InstagramTestURLProtocol.self]
        return GraphAPIProvider(token: token, igUserID: id, session: URLSession(configuration: config))
    }

    func finish(_ provider: GraphAPIProvider) {
        provider.session.invalidateAndCancel()
        _ = InstagramTestURLProtocol.transports.withLock { $0.removeValue(forKey: token) }
    }

    func respond(to request: URLRequest) throws -> Data {
        recorded.withLock { $0.append(request) }
        let path = request.url?.path.replacingOccurrences(of: "/v23.0/", with: "") ?? ""
        switch replies[path] {
        case .json(let json): return Data(json.utf8)
        case .failure(let code): throw URLError(code)
        case nil:
            Issue.record("Unexpected Graph request: \(path)")
            throw URLError(.unsupportedURL)
        }
    }
}

nonisolated private final class InstagramTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let transports = Mutex<[String: InstagramTestTransport]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try #require(request.url)
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "access_token" }?.value ?? ""
            let transport = try #require(Self.transports.withLock { $0[token] })
            let data = try transport.respond(to: request)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                                                       httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
