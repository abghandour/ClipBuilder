import Foundation

nonisolated struct WizardStrikeHighlightContext: Sendable {
    @TaskLocal static var current: WizardStrikeHighlightContext?
    var isCurrent: @Sendable () async -> Bool = { true }
    var didSave: @Sendable () async -> Void = {}
    var marking: @Sendable (Int64, Bool) async -> Void = { _, _ in }
}
