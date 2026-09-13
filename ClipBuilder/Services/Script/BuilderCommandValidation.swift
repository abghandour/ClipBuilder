import Foundation

/// Stable refusal codes also survive validation of programmatically built commands.
nonisolated struct BuilderCommandFailure: Error, LocalizedError {
    var code: String
    var reason: String
    var errorDescription: String? { reason }

    static func bounds(_ reason: String) -> Self { Self(code: "out_of_bounds", reason: reason) }
    static func invalid(_ reason: String) -> Self { Self(code: "invalid_value", reason: reason) }
    static let unknownID = Self(code: "unknown_id", reason: "Target is not in this session.")
}

nonisolated extension BuilderCommand {
    /// Structural/value validation shared by JSON and direct Swift callers.
    /// Document-dependent bounds and eligibility are checked by the runner.
    func validateExpansion(effectFilters: Set<String>? = nil) throws {
        func number(_ value: Double, _ range: ClosedRange<Double>) throws {
            guard value.isFinite, range.contains(value) else {
                throw BuilderCommandFailure.bounds("Number must be finite and within \(range).")
            }
        }
        func choice(_ value: String, _ choices: [String]) throws {
            guard choices.contains(value) else { throw BuilderCommandFailure.invalid("Unknown value: \(value).") }
        }
        func range(_ start: Double, _ duration: Double) throws {
            try number(start, 0...86400); try number(duration, 0.5...86400)
            try number(start + duration, 0...86400)
        }
        switch self {
        case .splitClipEvenly(_, let parts, _):
            guard (2...12).contains(parts) else { throw BuilderCommandFailure.bounds("Parts must be between 2 and 12.") }
        case .setCropBlockDuration(_, let duration): try number(duration, 0.5...86400)
        case .splitCropBlock(let at): try number(at, 0...86400)
        case .addOverlay(_, let at, let duration, _):
            if let at { try number(at, 0...86400) }
            if let duration { try number(duration, 0.5...86400) }
            if let at, let duration { try range(at, duration) }
        case .setImageGeometry(_, let x, let y, let width, let opacity):
            guard x != nil || y != nil || width != nil || opacity != nil else {
                throw BuilderCommandFailure.invalid("Image geometry needs at least one field.")
            }
            for value in [x, y, opacity].compactMap({ $0 }) { try number(value, 0...1) }
            if let width { try number(width, 0.05...1) }
        case .setOverlayPosition(_, let x, let y):
            try number(x, 0...1); try number(y, 0...1)
        case .setTextStyle(_, let style): try style.validate()
        case .setClipPosition(_, let position):
            if let position { try choice(position, ["top", "center", "bottom"]) }
        case .setClipCrop(_, let fraction):
            if let fraction { try number(fraction, 0...1) }
        case .splitZoomFeeds(_, let left, let right):
            guard left.utf8.count <= 1000, right.utf8.count <= 1000 else {
                throw BuilderCommandFailure.invalid("Feed names exceed 1000 bytes.")
            }
        case .setSoundVolume(_, let volume), .setClipVolume(_, let volume):
            try number(Double(volume), 1...5)
        case .setSoundRange(_, let start, let duration), .setOverlayRange(_, let start, let duration):
            try range(start, duration)
        case .moveSound(_, let at): try number(at, 0...86400)
        case .setClipFades(_, let a, let b):
            try number(a, 0...86400); try number(b, 0...86400)
        case .setText(_, let text):
            guard text.utf8.count <= 16384 else { throw BuilderCommandFailure.invalid("Text exceeds 16 KiB.") }
        case .setTextPosition(_, let position), .setTrackPosition(_, let position):
            try choice(position, ["top", "center", "bottom"])
        case .setOverlayTransitions(_, let a, let b):
            try choice(a, TextOverlayItem.transitionChoices); try choice(b, TextOverlayItem.transitionChoices)
        case .setClipTransitions(_, let a, let b):
            try choice(a, ["cut"] + RenderEngine.allTransitions)
            try choice(b, ["cut"] + RenderEngine.allTransitions)
        case .setClipSpeed(_, let speed): try number(speed, 0.5...2)
        case .setClipCaptions(_, let captions): try choice(captions, TimelineClip.captionChoices)
        case .setTrackEffect(_, let effect), .setClipEffect(_, let effect):
            if let effect {
                try EffectCatalog.validate(effect)
                guard EffectCatalog.isAvailable(effect.preset, filters: effectFilters ?? EffectCatalog.availableFilters) else {
                    throw BuilderCommandFailure.invalid("Effect unavailable in ffmpeg: \(effect.preset).")
                }
            }
        case .setTrackCaptions(_, let captions): try choice(captions, TrackSettings.captionChoices)
        case .setClipAreaWindow(_, let x, let y, let width, let height):
            for value in [x, y, width, height] { try number(value, 0...1) }
            guard width > 0, height > 0, x + width <= 1, y + height <= 1 else {
                throw BuilderCommandFailure.bounds("The positive area window must fit within the source frame.")
            }
        case .setTrackCrop(_, let fraction):
            if let fraction { try number(fraction, 0...1) }
        case .setRenderSettings(let settings): try settings.validate()
        default: break
        }
    }
}
