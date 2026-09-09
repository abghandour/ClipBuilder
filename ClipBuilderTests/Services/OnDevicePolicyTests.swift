import Foundation
import Testing
@testable import Clip_Builder

struct OnDevicePolicyTests {
    @Test func legacyAndRoundTrip() throws {
        var config = try JSONDecoder().decode(AIConfig.self, from: Data("{}".utf8))
        #expect(config.preferOnDevice)
        #expect(!OnDevicePolicy.isEnabled(item: "images", config: config))
        config.onDeviceOverrides["images"] = true
        #expect(OnDevicePolicy.isEnabled(item: "images", config: config))
        config.preferOnDevice = false
        #expect(!OnDevicePolicy.isEnabled(item: "images", config: config))
        let copy = try JSONDecoder().decode(AIConfig.self, from: JSONEncoder().encode(config))
        #expect(!copy.preferOnDevice)
        #expect(copy.onDeviceOverrides == ["images": true])
        config.preferOnDevice = true
        config.onDeviceOverrides["images"] = false
        #expect(!OnDevicePolicy.isEnabled(item: "images", config: config))
    }

    @Test func provenanceRoundTrip() throws {
        let old = try JSONDecoder().decode(AIProvenance.self, from: Data("{\"provider\":\"claude\",\"fellBack\":false}".utf8))
        #expect(old.technique == nil)
        let local = AIProvenance.local(technique: "keyword-match")
        let copy = try JSONDecoder().decode(AIProvenance.self, from: JSONEncoder().encode(local))
        #expect(copy == local)
        #expect(copy.provider == "local")
        #expect(copy.model == "keyword-match")
    }
}

extension OnDevicePolicyTests {
    @Test func comparisonOverrideBeatsSettings() throws {
        var config = try JSONDecoder().decode(AIConfig.self, from: Data("{}".utf8))
        #expect(OnDevicePolicy.comparison.withValue(true) { OnDevicePolicy.isEnabled(item: "trim", config: config) })
        config.onDeviceOverrides["trim"] = true
        #expect(!OnDevicePolicy.comparison.withValue(false) { OnDevicePolicy.isEnabled(item: "trim", config: config) })
        #expect(OnDevicePolicy.isEnabled(item: "trim", config: config))
    }
    @Test func unknownItemStaysOff() throws {
        var config = try JSONDecoder().decode(AIConfig.self, from: Data("{}".utf8))
        config.onDeviceOverrides = Dictionary(uniqueKeysWithValues: OnDeviceAgreement.items.map { ($0, true) })
        #expect(!OnDevicePolicy.isEnabled(item: "not-an-item", config: config))
        #expect(OnDeviceAgreement.items.allSatisfy { OnDevicePolicy.isEnabled(item: $0, config: config) })
    }
}
