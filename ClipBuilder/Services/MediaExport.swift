import AVFoundation
import Foundation

/// AVFoundation and ffmpeg exports share the same hardware admission budget.
nonisolated enum MediaExport {
    static func run(_ session: AVAssetExportSession, to output: URL,
                    isolation: isolated (any Actor)? = #isolation) async throws {
        let permit = try await MediaWorkScheduler.current.acquire(.encoding)
        defer { withExtendedLifetime(permit) {} }
        try Task.checkCancellation()
        let timing = PerfSignpost.begin("MediaExecution", metadata: "AVFoundation encoding")
        defer { PerfSignpost.end(timing) }
        try? FileManager.default.removeItem(at: output)
        do {
            // The async API cancels the export when this task is cancelled.
            // Await termination before deleting output or releasing admission.
            try await session.export(to: output, as: .mp4)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: output)
            try Task.checkCancellation()
            throw error
        }
    }
}
