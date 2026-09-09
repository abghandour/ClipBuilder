import Foundation

/// Capture once at an operation's entry point; pass the result into actors.
nonisolated enum OnDevicePolicy {
    static let comparison = TaskLocal<Bool?>(wrappedValue: nil)

    static func isEnabled(item: String, config: AIConfig) -> Bool {
        if let override = comparison.get() { return override }
        return config.preferOnDevice && (config.onDeviceOverrides[item] ?? false)
    }
}
