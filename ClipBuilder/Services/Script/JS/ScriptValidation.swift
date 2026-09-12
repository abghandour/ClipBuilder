import Foundation

nonisolated struct ScriptValidationResult: Sendable {
    var diagnostic: ScriptDiagnostic?
    var partial: Bool
    var message: String
}

/// Its entire input capability is copied values. No database, hydration owner,
/// service adapter or audit sink can be supplied to this entry point.
@MainActor
enum ScriptValidation {
    static func validate(source: String, sampleParams: Data = Data("{}".utf8),
                         capture: ScriptCapture) async -> ScriptValidationResult {
        do {
            let header = try ScriptHeader.parse(source)
            let (params, requirements) = try header.resolve(sampleParams, capture: capture)
            let live = BuilderTimelineModel(mode: .transient)
            capture.library.withLayouts {
                live.seed(document: capture.document, scenes: capture.library.scenes,
                          driveBackedPaths: capture.driveBackedPaths, selection: capture.selection,
                          playhead: capture.playhead, focusedTrack: capture.focusedTrack, zoom: capture.zoom)
            }
            let session = BuilderScriptSession(live: live, library: capture.library, ownsHydration: false)
            defer { session.discard() }
            let run = ScriptRunModel(session: session, header: header, params: params, confirmed: requirements,
                ensure: { _ in
                    BuilderScriptResult(outcomes: [.refused(code: "requires_user_run_validation",
                        reason: "requires user-run validation")], completed: false, hasDocumentChanges: false)
                })
            await run.run(source: source)
            let partial = !requirements.isEmpty
            return .init(diagnostic: run.diagnostic, partial: partial,
                         message: partial ? "requires user-run validation" : (run.diagnostic?.reason ?? "Validation passed."))
        } catch {
            return .init(diagnostic: ScriptHeader.diagnostic(source: source, error: error),
                         partial: false, message: error.localizedDescription)
        }
    }
}
