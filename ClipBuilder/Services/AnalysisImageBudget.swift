import AppKit
import Foundation

/// Budget for analysis stills, separate from thumbnail and identity-crop sizing.
nonisolated enum AnalysisImageBudget {
    static let maxTotalBytes = 24 * 1024 * 1024
    static var longestEdge: Int {
        let override = UserDefaults.standard.integer(forKey: "AnalysisImageLongestEdge")
        return override > 0 ? override : 1536
    }

    /// Preserve labels and order. First lower JPEG quality, then remove the
    /// older frame of each evenly spaced pair until the request fits. Identity
    /// portraits and timestamped references are reserved by the caller, never dropped.
    @concurrent
    static func fit(_ frames: [AIFrame], reservingBytes: Int = 0,
                    log: @Sendable (String) -> Void) async -> [AIFrame] {
        let allowance = max(0, maxTotalBytes - reservingBytes)
        let originalBytes = frames.reduce(0) { $0 + $1.jpeg.count }
        guard originalBytes > allowance else { return frames }
        var result = frames
        for quality in [0.65, 0.45, 0.25] {
            guard !Task.isCancelled else { return [] }
            result = reencoded(result, quality: quality)
            if result.reduce(0, { $0 + $1.jpeg.count }) <= allowance { break }
        }
        while result.reduce(0, { $0 + $1.jpeg.count }) > allowance {
            let last = result.count - 1
            result = result.count == 1 ? [] : result.enumerated()
                .filter { !$0.offset.isMultiple(of: 2) || $0.offset == last }.map(\.element)
        }
        log("Analysis image budget: \(frames.count) frames / \(originalBytes) bytes → \(result.count) frames / \(result.reduce(0) { $0 + $1.jpeg.count }) bytes (\(reservingBytes) reference bytes reserved)")
        return result
    }

    /// References cannot be dropped: prompts name each identity/note. Re-encode
    /// only if they alone exceed the budget, preserving every label and pixel size.
    @concurrent
    static func fitReferences(_ frames: [AIFrame], log: @Sendable (String) -> Void) async throws -> [AIFrame] {
        guard frames.reduce(0, { $0 + $1.jpeg.count }) > maxTotalBytes else { return frames }
        var result = frames
        for quality in [0.65, 0.45, 0.25] {
            try Task.checkCancellation()
            result = reencoded(result, quality: quality)
            if result.reduce(0, { $0 + $1.jpeg.count }) <= maxTotalBytes {
                log("Analysis image budget: recompressed \(frames.count) reference images to fit 24 MiB; labels and dimensions retained")
                return result
            }
        }
        log("Analysis image budget: reference images still exceed 24 MiB after recompression")
        throw AIError.unusableResponse("Analysis reference images exceed 24 MiB. Reduce the number of notes or identity references and retry.")
    }

    private static func reencoded(_ frames: [AIFrame], quality: Double) -> [AIFrame] {
        frames.map { frame in
            autoreleasepool {
                guard let bitmap = NSBitmapImageRep(data: frame.jpeg),
                      let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                      data.count < frame.jpeg.count else { return frame }
                return AIFrame(jpeg: data, label: frame.label)
            }
        }
    }
}
