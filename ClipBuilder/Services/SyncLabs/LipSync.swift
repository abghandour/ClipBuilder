import Foundation

/// Lip sync by Sync Labs (sync.so): its models, what a run costs, the bodies
/// the API takes and the answers it gives. Pure; `SyncLabsClient` sends them
/// and `LipSyncService` runs the whole pass. See docs/Lip-Sync-Plan.md.
nonisolated enum LipSync {
    static let provider = "synclabs"

    /// Cheapest first. The raw value is the API's model id.
    enum Model: String, CaseIterable, Sendable, Identifiable {
        case standard = "lipsync-2"
        case pro = "lipsync-2-pro"
        case sync3 = "sync-3"

        static let fallback = Model.standard

        var id: String { rawValue }

        var label: String {
            switch self {
            case .standard: "Lipsync 2"
            case .pro: "Lipsync 2 Pro"
            case .sync3: "Sync 3"
            }
        }

        /// US dollars per second of output at 25 fps, from Sync Labs' price
        /// list of 2026-11-26. An estimate: the invoice is theirs.
        var dollarsPerSecond: Double {
            switch self {
            case .standard: 0.05
            case .pro: 0.083
            case .sync3: 0.133
            }
        }

        var detail: String {
            switch self {
            case .standard: "The everyday model. Leaves a closed, still mouth as it is."
            case .pro: "Sharper teeth and skin detail on close-ups. Leaves a closed, still mouth as it is."
            case .sync3: "The model the ElevenLabs website uses. Opens a closed mouth and holds up in 4K."
            }
        }
    }

    static func model(_ id: String?) -> Model { id.flatMap(Model.init(rawValue:)) ?? .fallback }

    /// What `seconds` of reel cost with `model`, in dollars.
    static func estimate(seconds: Double, model: Model) -> Double {
        max(0, seconds) * model.dollarsPerSecond
    }

    /// "about $3.00", "about $0.40": never more exact than the estimate is.
    static func estimateLabel(seconds: Double, model: Model) -> String {
        "about $" + String(format: "%.2f", estimate(seconds: seconds, model: model))
    }

    /// "About $3 a minute": the rate as a row caption states it.
    static func rateLabel(_ model: Model) -> String {
        let minute = model.dollarsPerSecond * 60
        return "about $" + (minute.rounded() == minute ? String(format: "%.0f", minute) : String(format: "%.2f", minute)) + " a minute"
    }

    // MARK: Requests

    struct UploadRequest: Encodable, Equatable {
        var fileName: String
        var contentType: String
        var size: Int
    }

    struct AssetRequest: Encodable, Equatable {
        var url: String
        /// VIDEO or AUDIO.
        var type: String
        var name: String
    }

    struct GenerateRequest: Encodable, Equatable {
        struct Input: Encodable, Equatable {
            var type: String
            var assetId: String
        }
        struct Options: Encodable, Equatable {
            struct SpeakerDetection: Encodable, Equatable {
                var autoDetect = true
                enum CodingKeys: String, CodingKey { case autoDetect = "auto_detect" }
            }
            /// The reel and its audio are the same length; `cut_off` never
            /// loops or stretches the picture if they differ by a frame.
            var syncMode = "cut_off"
            /// Two people in the shot: only the one speaking is re-timed.
            var speakerDetection = SpeakerDetection()
            enum CodingKeys: String, CodingKey {
                case syncMode = "sync_mode"
                case speakerDetection = "active_speaker_detection"
            }
        }
        var model: String
        var input: [Input]
        var options = Options()
    }

    static func request(videoAsset: String, audioAsset: String, model: Model) -> GenerateRequest {
        GenerateRequest(model: model.rawValue, input: [.init(type: "video", assetId: videoAsset),
                                                       .init(type: "audio", assetId: audioAsset)])
    }

    // MARK: Answers

    struct Upload: Decodable, Equatable {
        var uploadUrl: String
        var url: String
    }

    struct Asset: Decodable, Equatable {
        var id: String
    }

    struct Account: Decodable, Equatable, Sendable {
        struct Plan: Decodable, Equatable, Sendable { var name: String? }
        struct Limits: Decodable, Equatable, Sendable {
            var maxOutputDurationSeconds: Double?
            var maxFileSizeBytes: Double?
        }
        var plan: Plan?
        var limits: Limits?

        /// "Creator plan, videos up to 5 minutes".
        var summary: String {
            var parts = [plan?.name.map { "\($0) plan" } ?? "Connected"]
            if let seconds = limits?.maxOutputDurationSeconds, seconds > 0 { parts.append("videos up to \(LipSync.length(seconds))") }
            return parts.joined(separator: ", ")
        }
    }

    struct Generation: Decodable, Equatable, Sendable {
        var id: String
        var status: String
        var outputUrl: String?
        var error: String?
        var errorCode: String?
    }

    enum Outcome: Equatable, Sendable {
        case waiting
        case done(URL)
        /// Sync Labs finished and changed nothing (no face, no speech).
        case unchanged(String)
        case failed(String)
    }

    static func outcome(_ generation: Generation) -> Outcome {
        let reason = [generation.error, generation.errorCode].compactMap { $0 }.first { !$0.isEmpty }
        switch generation.status.uppercased() {
        case "PENDING", "PROCESSING":
            return .waiting
        case "COMPLETED":
            guard let text = generation.outputUrl, let url = URL(string: text), url.scheme == "https" else {
                return .failed("Sync Labs finished without a video to download.")
            }
            return .done(url)
        case "NO_OP":
            return .unchanged(reason ?? "Sync Labs found no speaking face to re-time.")
        case "REJECTED":
            return .failed(reason ?? "Sync Labs rejected the request.")
        default:
            return .failed(reason ?? "Sync Labs could not finish the video.")
        }
    }

    /// The API's error body: `message` is one string or several.
    struct Failure: Decodable, Equatable {
        var message: String?
        var errorCode: String?
        var suggestion: String?

        enum CodingKeys: String, CodingKey { case message, errorCode, suggestion }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let one = try? c.decodeIfPresent(String.self, forKey: .message) {
                message = one
            } else if let many = try? c.decodeIfPresent([String].self, forKey: .message) {
                message = many.joined(separator: " ")
            }
            errorCode = try? c.decodeIfPresent(String.self, forKey: .errorCode)
            suggestion = try? c.decodeIfPresent(String.self, forKey: .suggestion)
        }

        /// The server's words, with its suggestion when it has one.
        var text: String? {
            let parts = [message, suggestion].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return parts.isEmpty ? errorCode : parts.joined(separator: " ")
        }
    }

    // MARK: Media

    /// The reel's audio as the track Sync Labs listens to: 16-bit WAV, the
    /// one format its docs list as fully supported.
    static func audioArguments(source: String, output: String) -> [String] {
        ["-y", "-i", source, "-vn", "-ac", "1", "-ar", "44100", "-c:a", "pcm_s16le", output]
    }

    /// The synced picture with the reel's own audio, both copied: the mix
    /// the app rendered is the mix that ships.
    static func muxArguments(synced: String, original: String, output: String) -> [String] {
        ["-y", "-i", synced, "-i", original, "-map", "0:v:0", "-map", "1:a:0", "-c", "copy",
         "-movflags", "+faststart", output]
    }

    /// A synced file is the reel only if it is as long as the reel.
    static func sameLength(_ synced: Double, as original: Double, tolerance: Double = 0.5) -> Bool {
        synced > 0 && abs(synced - original) <= tolerance
    }

    /// "45 seconds", "1 minute", "2.5 minutes".
    static func length(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) seconds" }
        let minutes = seconds / 60
        if minutes == 1 { return "1 minute" }
        return (minutes.rounded() == minutes ? String(format: "%.0f", minutes) : String(format: "%.1f", minutes)) + " minutes"
    }
}
