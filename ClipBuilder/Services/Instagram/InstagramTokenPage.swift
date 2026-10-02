import Foundation

nonisolated enum InstagramTokenPage {
    /// The Meta dashboard page with Generate token for the app's Instagram
    /// accounts; without a numeric app id, the app list to pick one from.
    static func url(metaAppID: String) -> URL {
        let id = metaAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else {
            return URL(string: "https://developers.facebook.com/apps/")!
        }
        return URL(string: "https://developers.facebook.com/apps/\(id)/instagram-business/API-Setup/")!
    }
}
