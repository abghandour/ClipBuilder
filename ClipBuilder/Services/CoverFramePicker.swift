import Foundation

/// Cover-frame picker: samples frames across a rendered reel and has a
/// multimodal model rank the best thumbnail candidates — sharp action or an
/// expressive face, subject well framed, no motion blur or mid-transition
/// frames.
nonisolated enum CoverFramePicker {

    struct Candidate: Identifiable, Sendable, Hashable {
        var time: Double
        var reason: String

        var id: Double { time }
    }

    /// Frames sampled across the reel per pick.
    static let sampleCount = 12
    /// Ranked candidates asked of the model.
    static let pickCount = 3

    /// Evenly spread sample timestamps, keeping clear of the first/last
    /// moments (fade-ins, end cards).
    static func sampleTimes(duration: Double) -> [Double] {
        guard duration > 1 else { return [duration / 2] }
        let margin = min(1.5, duration * 0.05)
        let span = duration - margin * 2
        return (0..<sampleCount).map { index in
            margin + span * Double(index) / Double(sampleCount - 1)
        }
    }

    static func prompt(filename: String, duration: Double) -> String {
        """
        You are picking the COVER FRAME (thumbnail) for a short-form social reel ("\(filename)", \(Int(duration))s). The frames below are samples across the reel, labeled with their timestamps.

        A great cover: the subject sharp and well framed, peak action or an expressive face, readable at thumbnail size, no motion blur, no mid-transition or half-faded frames, no near-black frames.

        Rank the best \(pickCount) frames. Return ONLY a JSON object:
        {"covers": [{"t": <the frame's timestamp in seconds, exactly as labeled>, "why": "<at most 10 words>"}]}
        """
    }

    /// Candidates out of the reply, snapped to the nearest actually-sampled
    /// timestamp so a made-up time can't pick an unseen frame.
    static func parse(_ response: String, sampledTimes: [Double]) -> [Candidate] {
        guard let object = AIResponseParser.jsonObject(from: response),
              let raw = object["covers"] as? [[String: Any]], !sampledTimes.isEmpty
        else { return [] }
        var seen = Set<Double>()
        return raw.compactMap { entry in
            guard let time = (entry["t"] as? NSNumber)?.doubleValue else { return nil }
            let snapped = sampledTimes.min { abs($0 - time) < abs($1 - time) } ?? time
            guard abs(snapped - time) < 3, seen.insert(snapped).inserted else { return nil }
            return Candidate(time: snapped,
                             reason: (entry["why"] as? String)?
                                 .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        .prefix(pickCount)
        .map { $0 }
    }
}
