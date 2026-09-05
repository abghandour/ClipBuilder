import Foundation

/// A concrete output canvas. Custom dimensions are normalized to even
/// pixels because the H.264 encoders used by Clip Builder require them.
nonisolated struct RenderSettings: Codable, Sendable, Equatable, Hashable {
    var preset: RenderPreset = .portrait1080
    var customWidth = 1080
    var customHeight = 1920
    var quality: EncodeQuality = .balanced
    var customCRF = 20

    var width: Int { preset.width ?? Self.even(customWidth) }
    var height: Int { preset.height ?? Self.even(customHeight) }
    var crf: Int { quality.crf ?? min(35, max(10, customCRF)) }
    var aspectRatio: Double { Double(width) / Double(height) }
    var sizeLabel: String { "\(width)×\(height)" }

    private static func even(_ value: Int) -> Int {
        let clamped = min(7680, max(240, value))
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }
}

nonisolated enum RenderPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case portrait1080, portrait4K, landscape1080, landscape4K
    case square1080, feedPortrait1080, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .portrait1080: "9:16 · 1080p"
        case .portrait4K: "9:16 · 4K"
        case .landscape1080: "16:9 · 1080p"
        case .landscape4K: "16:9 · 4K"
        case .square1080: "1:1 · 1080p"
        case .feedPortrait1080: "4:5 · 1080p"
        case .custom: "Custom"
        }
    }

    var width: Int? {
        switch self {
        case .portrait1080, .square1080, .feedPortrait1080: 1080
        case .portrait4K: 2160
        case .landscape1080: 1920
        case .landscape4K: 3840
        case .custom: nil
        }
    }

    var height: Int? {
        switch self {
        case .portrait1080: 1920
        case .portrait4K: 3840
        case .landscape1080: 1080
        case .landscape4K: 2160
        case .square1080: 1080
        case .feedPortrait1080: 1350
        case .custom: nil
        }
    }
}

nonisolated enum EncodeQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case archival, balanced, compact, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .archival: "High"
        case .balanced: "Balanced"
        case .compact: "Compact"
        case .custom: "Custom CRF"
        }
    }

    var crf: Int? {
        switch self {
        case .archival: 16
        case .balanced: 20
        case .compact: 25
        case .custom: nil
        }
    }

    /// Hardware-encoder bitrate per megapixel of canvas. Balanced lands on
    /// the 8 Mbit/s the app always used for 1080×1920; nil = custom CRF,
    /// which only libx264 can honor.
    var videoToolboxMegabitsPerMegapixel: Double? {
        switch self {
        case .archival: 6
        case .balanced: 4
        case .compact: 2.5
        case .custom: nil
        }
    }
}

/// Task-local settings let simultaneous renders use different canvases
/// without mutable global state.
nonisolated enum RenderContext {
    @TaskLocal static var settings = RenderSettings()
}
