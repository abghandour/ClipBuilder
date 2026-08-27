import Foundation

/// Soundbite finder: reads a video's transcript and surfaces the most
/// quotable self-contained moments — the lines worth building an interview
/// or recap reel around — each with a suggested overlay line.
nonisolated enum SoundbiteFinder {

    struct Soundbite: Identifiable, Sendable, Hashable {
        var start: Double
        var end: Double
        var quote: String
        var overlayLine: String
        var reason: String

        var id: Double { start }
    }

    /// Transcript budget per call; interviews fit whole, marathons get the
    /// opening hours' worth with a log note.
    static let maxTranscriptChars = 16000

    static func prompt(video: VideoRecord, transcript: [TranscriptRow]) -> String {
        var lines: [String] = []
        var used = 0
        for row in transcript {
            let line = String(format: "[%.1f–%.1f] %@", row.startTime, row.endTime, row.text)
            guard used + line.count <= maxTranscriptChars else { break }
            lines.append(line)
            used += line.count
        }
        return """
        You are mining a \(Int(video.duration))s video's transcript for SOUNDBITES — the short, self-contained spoken moments a short-form reel could be built around: a bold claim, a raw emotion, a sharp insight, a funny line, a quotable answer.

        ## TRANSCRIPT of "\(video.filename)" (each line is [start–end] in seconds)
        \(lines.joined(separator: "\n"))

        ## OUTPUT
        Pick the 3–5 strongest soundbites. Each must stand on its own without setup, start and end at natural sentence boundaries, and run roughly 5–25 seconds. Return ONLY a JSON object:
        {"soundbites": [{"start": <seconds>, "end": <seconds>, "quote": "<the words, verbatim from the transcript>", "overlay_line": "<a punchy on-screen caption for it, at most 8 words>", "why": "<at most 12 words on why it lands>"}]}
        Fewer is fine when the material is thin; never invent words the transcript doesn't contain.
        """
    }

    static func parse(_ response: String, duration: Double) -> [Soundbite] {
        guard let object = AIResponseParser.jsonObject(from: response),
              let raw = object["soundbites"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            let start = (entry["start"] as? NSNumber)?.doubleValue ?? -1
            let end = (entry["end"] as? NSNumber)?.doubleValue ?? -1
            guard start >= 0, end > start, start < duration,
                  let quote = (entry["quote"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty
            else { return nil }
            return Soundbite(start: start, end: min(end, duration),
                             quote: quote,
                             overlayLine: (entry["overlay_line"] as? String)?
                                 .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                             reason: (entry["why"] as? String)?
                                 .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        .sorted { $0.start < $1.start }
    }
}
