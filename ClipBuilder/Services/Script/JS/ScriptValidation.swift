import Foundation

nonisolated struct ScriptValidationResult: Sendable {
    var diagnostic: ScriptDiagnostic?
    var partial: Bool
    var message: String
    var prerequisiteStubStopped = false
}

/// Its entire input capability is copied values. No database, hydration owner,
/// service adapter or audit sink can be supplied to this entry point.
@MainActor
enum ScriptValidation {
    static func validate(source: String, sampleParams: Data = Data("{}".utf8),
                         capture: ScriptCapture, seconds: Double = 10) async -> ScriptValidationResult {
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
            var reachedPrerequisiteStub = false
            let run = ScriptRunModel(session: session, header: header, params: params, confirmed: requirements, seconds: seconds,
                ensure: { _ in
                    reachedPrerequisiteStub = true
                    return BuilderScriptResult(outcomes: [.refused(code: "requires_user_run_validation",
                        reason: "requires user-run validation")], completed: false, hasDocumentChanges: false)
                })
            await run.run(source: source)
            let partial = !requirements.isEmpty
            var diagnostic = run.diagnostic
            // The coordinator closes the throwaway session on a refused ensure.
            // Preserve that explicit partial result instead of its generic closed error.
            let stubStopped = reachedPrerequisiteStub && (diagnostic?.code == "closed" || diagnostic?.code == "requires_user_run_validation")
            if stubStopped {
                diagnostic?.code = "requires_user_run_validation"
                diagnostic?.reason = "requires user-run validation"
            }
            return .init(diagnostic: diagnostic, partial: partial,
                         message: partial ? "requires user-run validation" : (run.diagnostic?.reason ?? "Validation passed."),
                         prerequisiteStubStopped: stubStopped)
        } catch {
            return .init(diagnostic: ScriptHeader.diagnostic(source: source, error: error),
                         partial: false, message: error.localizedDescription)
        }
    }
}
