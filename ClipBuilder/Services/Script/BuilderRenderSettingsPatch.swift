import Foundation

/// Only the canvas and encoding controls exposed by Builder. Omitted values
/// retain the captured document setting, including inactive custom values.
nonisolated struct BuilderRenderSettingsPatch: Codable, Sendable, Equatable {
    var preset: RenderPreset?
    var customWidth: Int?
    var customHeight: Int?
    var quality: EncodeQuality?
    var customCRF: Int?

    init(preset: RenderPreset? = nil, customWidth: Int? = nil, customHeight: Int? = nil,
         quality: EncodeQuality? = nil, customCRF: Int? = nil) {
        self.preset = preset; self.customWidth = customWidth; self.customHeight = customHeight
        self.quality = quality; self.customCRF = customCRF
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ScriptKey.self)
        try c.only(["preset", "custom_width", "custom_height", "quality", "custom_crf"])
        // Explicit null is not a reset operation for render settings.
        for key in c.allKeys where try c.decodeNil(forKey: key) {
            throw BuilderCommandFailure.invalid("Render settings cannot be null: \(key.stringValue).")
        }
        preset = try c.decodeIfPresent(RenderPreset.self, forKey: ScriptKey("preset"))
        customWidth = try c.decodeIfPresent(Int.self, forKey: ScriptKey("custom_width"))
        customHeight = try c.decodeIfPresent(Int.self, forKey: ScriptKey("custom_height"))
        quality = try c.decodeIfPresent(EncodeQuality.self, forKey: ScriptKey("quality"))
        customCRF = try c.decodeIfPresent(Int.self, forKey: ScriptKey("custom_crf"))
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ScriptKey.self)
        try c.encodeIfPresent(preset, forKey: ScriptKey("preset"))
        try c.encodeIfPresent(customWidth, forKey: ScriptKey("custom_width"))
        try c.encodeIfPresent(customHeight, forKey: ScriptKey("custom_height"))
        try c.encodeIfPresent(quality, forKey: ScriptKey("quality"))
        try c.encodeIfPresent(customCRF, forKey: ScriptKey("custom_crf"))
    }

    func validate() throws {
        for dimension in [customWidth, customHeight].compactMap({ $0 }) {
            guard (240...7680).contains(dimension), dimension.isMultiple(of: 2) else {
                throw BuilderCommandFailure.bounds("Custom dimensions must be even pixels in 240...7680.")
            }
        }
        if let customCRF, !(10...35).contains(customCRF) {
            throw BuilderCommandFailure.bounds("Custom CRF must be in 10...35.")
        }
    }

    func applying(to original: RenderSettings) -> RenderSettings {
        var result = original
        if let preset { result.preset = preset }
        if let customWidth { result.customWidth = customWidth }
        if let customHeight { result.customHeight = customHeight }
        if let quality { result.quality = quality }
        if let customCRF { result.customCRF = customCRF }
        return result
    }
}
