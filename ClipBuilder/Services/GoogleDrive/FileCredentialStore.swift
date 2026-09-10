import Foundation
import CryptoKit
import Security

/// Credential storage for processes that must stay out of the login
/// keychain: the ad-hoc–signed test host (a new code identity on every
/// build, so "Always Allow" can never stick and macOS asks again on every
/// run) and any build launched at a scratch data folder.
///
/// The file lives beside the scratch data it belongs to, readable only by
/// its owner. It is deliberately not a security boundary — it exists so a
/// throwaway run never touches the user's real secrets.
nonisolated struct FileCredentialStore: DriveCredentialStore {
    let service: String
    /// The data root this store is bound to, captured once: a store handed
    /// to a client must not follow a later data-folder change.
    let root: URL

    init(service: String, root: URL? = nil) {
        self.service = service
        self.root = root ?? SettingsStore.dataDirectory
    }

    enum StoreError: Error, CustomStringConvertible {
        case invalidProfile(String)
        case deleteFailed(String, any Error)

        var description: String {
            switch self {
            case .invalidProfile(let name): "\"\(name)\" is not a usable profile name"
            case .deleteFailed(let path, let error): "Could not delete \(path): \(error)"
            }
        }
    }

    /// Folder for this service, and the file one profile lands in — the
    /// names are digests, so tests and eyes need this to find them.
    var folderName: String { digest(service) }

    func fileName(for profile: String) -> String { digest(profile) }

    private var directory: URL {
        root.appendingPathComponent(".credentials", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// File names are the SHA-256 of the exact name, so two names that
    /// differ only in characters an escape would fold together ("A B" and
    /// "A_B") can never share a file, and no name can escape the directory.
    private func digest(_ name: String) -> String {
        SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ profile: String) throws -> URL {
        guard !profile.isEmpty, profile != ".", profile != "..",
              !profile.contains("/"), !profile.contains(":") else {
            throw StoreError.invalidProfile(profile)
        }
        return directory.appendingPathComponent(digest(profile))
    }

    func read(profile: String) throws -> Data? {
        let url = try file(profile)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data?, profile: String) throws {
        let url = try file(profile)
        guard let data else {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // Disconnecting must report a token it could not remove.
                throw StoreError.deleteFailed(url.path, error)
            }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // A readable sidecar, so a scratch folder can be understood by eye.
        let names = directory.appendingPathComponent("names.json")
        var readable = (try? JSONDecoder().decode([String: String].self,
                                                  from: Data(contentsOf: names))) ?? [:]
        if readable[digest(profile)] != profile {
            readable[digest(profile)] = profile
            try? JSONEncoder().encode(readable).write(to: names, options: [.atomic])
        }
    }
}

/// Which credential store this process should use. The login keychain asks
/// the user for permission per code signature; a test host or a scratch-data
/// run has a throwaway signature, so it would ask forever.
nonisolated enum DriveCredentialStores {
    /// The keychain, unless this process must stay out of it.
    static func store(service: String = "com.clipbuilder.google-drive") -> any DriveCredentialStore {
        usesFileStore ? FileCredentialStore(service: service) : GoogleDriveKeychain(service: service)
    }

    /// True when the process runs against a scratch data folder (every
    /// `scripts/test.sh` run does) or its code has no team identifier
    /// (an ad-hoc signature, which the keychain treats as a new app each
    /// time it is rebuilt).
    static var usesFileStore: Bool {
        if SettingsStore.customDataFolder != nil { return true }
        return teamIdentifier == nil
    }

    /// The running code's team identifier, or nil when it is ad-hoc signed
    /// (or unsigned). Read once — `SecCodeCopySelf` is not cheap.
    private static let teamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return (team?.isEmpty ?? true) ? nil : team
    }()
}
