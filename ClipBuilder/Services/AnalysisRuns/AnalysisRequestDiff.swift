import Foundation

nonisolated enum AnalysisRequestDiff {
    static func describe(old: AnalysisRequest, new: AnalysisRequest) -> [String] {
        let old = old.normalized, new = new.normalized
        var result: [String] = []
        if old.version != new.version { result.append("request format \(old.version) → \(new.version)") }
        if old.sourceIdentity != new.sourceIdentity { result.append("source file changed") }
        if old.videoType != new.videoType { result.append("video type changed") }
        if old.pipeline != new.pipeline { result.append("pipeline \(old.pipeline) → \(new.pipeline)") }
        if old.passVersions != new.passVersions { result.append("pass versions changed") }
        if old.plan.trimRange != new.plan.trimRange { result.append("trim range changed") }
        if old.plan.sampleInterval != new.plan.sampleInterval {
            func label(_ interval: Double?) -> String { interval.map { "\($0.formatted()) s" } ?? "automatic" }
            result.append("sampling \(label(old.plan.sampleInterval)) → \(label(new.plan.sampleInterval))")
        }
        if old.plan.smartSampling != new.plan.smartSampling { result.append("smart sampling changed") }
        if old.plan.instructions != new.plan.instructions { result.append("instructions changed") }
        if old.notes != new.notes { result.append(new.notes.count > old.notes.count ? "notes added" : "notes changed") }
        if old.plan.requiredPeopleKeys != new.plan.requiredPeopleKeys { result.append("required people changed") }
        if old.markers != new.markers { result.append("identity markers changed") }
        if old.people != new.people { result.append("people identities changed") }
        if old.tags != new.tags { result.append("profile tags changed") }
        if old.domain != new.domain { result.append("profile domain changed") }
        if old.tasteRubric != new.tasteRubric || old.taste != new.taste || old.exemplarHashes != new.exemplarHashes { result.append("taste inputs changed") }
        if old.routing != new.routing { result.append("model routing changed") }
        if old.onDevice != new.onDevice { result.append("on-device policy changed") }
        if old.transcriptKey != new.transcriptKey || old.transcriptHash != new.transcriptHash || old.language != new.language {
            result.append("transcript dependency changed")
        }
        if old.podcastJSON != new.podcastJSON { result.append("podcast settings changed") }
        if old.requestedPasses != new.requestedPasses || old.plan.detectPeople != new.plan.detectPeople
            || old.plan.includeTranscript != new.plan.includeTranscript || old.plan.includeFightScoring != new.plan.includeFightScoring {
            result.append("requested passes changed")
        }
        if old.plan.autoZoomUnframed != new.plan.autoZoomUnframed { result.append("automatic framing changed") }
        if old.plan.breakdownTags != new.plan.breakdownTags { result.append("breakdown tags changed") }
        return result
    }
}
