import Foundation

/// The name of a blessed stable release ("Harbor"), shown in the About box.
/// `scripts/bless.sh` writes it into `ReleaseName.txt` in the worktree it
/// builds the stable pkg from, so only blessed stable binaries carry one;
/// Debug and beta builds have no file and no name
/// (docs/Stable-Beta-Channels-Plan.md, Release names).
nonisolated enum ReleaseName {
    static let resourceName = "ReleaseName"

    /// The running app's release name, read once.
    static let current: String? = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }()

    /// The first non-blank line, trimmed; `nil` when there is none.
    static func parse(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// The About panel's application version, "1.152 “Harbor”"; the panel
    /// adds "Version" before it and the build after it. `nil` without a name,
    /// so the standard panel keeps its own line.
    static func aboutVersion(version: String, name: String?) -> String? {
        guard let name else { return nil }
        return "\(version) “\(name)”"
    }
}
