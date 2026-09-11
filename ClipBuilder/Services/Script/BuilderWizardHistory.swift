import Foundation

@MainActor
struct BuilderWizardHistory {
    private let defaults: UserDefaults
    nonisolated init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func requests(profile: String) -> [String] {
        Array((defaults.stringArray(forKey: key(profile)) ?? []).prefix(10))
    }

    func add(_ request: String, profile: String) {
        let value = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096 else { return }
        var values = requests(profile: profile).filter { $0 != value }
        values.insert(value, at: 0)
        defaults.set(Array(values.prefix(10)), forKey: key(profile))
    }

    private func key(_ profile: String) -> String {
        "builder.wizard.requests." + Data(profile.utf8).base64EncodedString()
    }
}
