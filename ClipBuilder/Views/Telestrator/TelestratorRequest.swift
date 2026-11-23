import CoreGraphics
import Foundation
import SwiftUI

/// A row asks its page to present the editor; split-view children never present it.
nonisolated struct TelestratorRequest: Identifiable, Sendable {
    let id = UUID()
    var videoURL: URL
    var videoID: Int64
    var duration: Double
    var aspect: CGFloat
    var range: ClosedRange<Double>
    /// The whole clip, for playing it with the drawing in it.
    var clipRange: ClosedRange<Double>? = nil
    var initialTime: Double
    var existing: TelestrationRecord?
    var profileGeneration: Int

    static let drawingsHelp = "Pauses drawn with the pencil button on a clip. Turn off to leave them out of this reel."

    /// Nil when done; otherwise the reason, for the sheet to show and stay open.
    @MainActor func save(_ drawing: Telestration?, store: AppStore) async -> String? {
        guard profileGeneration == store.profileGeneration else { return "The profile changed; this drawing was not saved." }
        if var drawing {
            drawing.time = min(range.upperBound, max(range.lowerBound, drawing.time))
            return await store.saveTelestration(TelestrationRecord(id: existing?.id ?? 0,
                videoID: videoID, drawing: drawing))
        } else if let existing {
            return await store.deleteTelestration(id: existing.id)
        }
        return nil
    }

    /// How far the moment can be moved: a pause needs a quarter second of
    /// screen time on each side of it, or the reel leaves it out. An existing
    /// drawing's own moment always stays reachable, so opening one never moves it.
    static func drawable(_ range: ClosedRange<Double>, keeping time: Double? = nil) -> ClosedRange<Double> {
        let inset = min(StrikeFreezeRules.minimumPiece, (range.upperBound - range.lowerBound) / 2)
        var lower = range.lowerBound + inset, upper = max(range.lowerBound + inset, range.upperBound - inset)
        if let time, range.contains(time) { lower = min(lower, time); upper = max(upper, time) }
        return lower...upper
    }

    /// Where a new drawing starts: half a second in, which also clears the
    /// edge of a clip played at up to 2×, or the middle of a shorter clip.
    static func initialTime(_ range: ClosedRange<Double>) -> Double {
        min(range.lowerBound + 0.5, (range.lowerBound + range.upperBound) / 2)
    }
}

extension EnvironmentValues {
    @Entry var requestTelestration: (@MainActor @Sendable (TelestratorRequest) -> Void)? = nil
}
