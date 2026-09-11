import CoreGraphics
import Foundation

@MainActor
extension ScriptRunner {
    private func requireWideFraming(_ clip: TimelineClip, model: BuilderTimelineModel) throws {
        guard !clip.bumper, clip.wide,
              model.area(forTrack: clip.track, at: clip.startTime) == nil,
              !model.document.isOrphaned(clip) else {
            throw BuilderCommandFailure.invalid("Position and crop require a wide clip in Full Screen.")
        }
    }

    func executeExpansion(_ command: BuilderCommand, model: BuilderTimelineModel,
                          library: ScriptLibrarySnapshot) throws {
        func id(_ reference: String) throws -> UUID {
            do { return try resolve(reference) }
            catch { throw BuilderCommandFailure.unknownID }
        }
        func clip(_ reference: String) throws -> TimelineClip {
            guard let clip = model.clip(try id(reference)) else { throw BuilderCommandFailure.unknownID }
            return clip
        }
        func sound(_ reference: String) throws -> SoundItem {
            let uid = try id(reference)
            guard let item = model.document.soundTrack.first(where: { $0.uid == uid }) else {
                throw BuilderCommandFailure.unknownID
            }
            return item
        }
        func track(_ index: Int) throws {
            guard (0..<model.document.trackCount).contains(index), model.document.trackSettings.indices.contains(index) else {
                throw BuilderCommandFailure.bounds("Track is not visible.")
            }
        }
        func unsupported(_ reason: String) throws {
            throw BuilderCommandFailure.invalid(reason)
        }
        switch command {
        case .setBumperMode(let reference, let mode):
            let item = try clip(reference)
            guard item.bumper else { throw BuilderCommandFailure.invalid("Bumper mode requires a bumper.") }
            if item.bumperMode != mode { model.setBumperMode(item.uid, mode: mode) }
        case .setCropBlockDuration(let reference, let duration):
            let uid = try id(reference)
            guard let item = model.cropBlock(uid) else { throw BuilderCommandFailure.unknownID }
            guard item.startTime + duration <= 86400 else { throw BuilderCommandFailure.bounds("Crop exceeds one day.") }
            if item.duration != duration { model.resizeCropBlock(uid, duration: duration) }
        case .splitCropBlock(let at):
            let snapped = BuilderTimelineModel.snap(at)
            guard let item = model.document.cropBlock(at: snapped) else {
                throw BuilderCommandFailure.invalid("No crop block covers the split time.")
            }
            guard snapped > item.startTime + 0.499, snapped < item.endTime - 0.499 else {
                throw BuilderCommandFailure.bounds("Both crop pieces must last at least 0.5 seconds.")
            }
            model.splitCropBlock(at: at)
        case .removeSound(let reference): model.removeSound(try sound(reference).uid)
        case .setImageGeometry(let reference, let x, let y, let width, let opacity):
            let uid = try id(reference)
            guard let item = model.imageItem(uid) else { throw BuilderCommandFailure.unknownID }
            var updated = item
            if let x { updated.xFrac = x }
            if let y { updated.yFrac = y }
            if let width { updated.wFrac = width }
            if let opacity { updated.opacity = opacity }
            if updated != item { model.updateImage(uid) { $0 = updated } }
        case .setOverlayPosition(let reference, let x, let y):
            let uid = try id(reference)
            if let item = model.textItem(uid) {
                if item.xFrac != x || item.yFrac != y { model.updateText(uid) { $0.xFrac = x; $0.yFrac = y } }
            } else if let item = model.imageItem(uid) {
                if item.xFrac != x || item.yFrac != y { model.updateImage(uid) { $0.xFrac = x; $0.yFrac = y } }
            } else { throw BuilderCommandFailure.unknownID }
        case .setTextStyle(let reference, let style):
            let uid = try id(reference)
            guard let item = model.textItem(uid) else { throw BuilderCommandFailure.unknownID }
            let updated = try style.applying(to: item)
            if updated != item { model.updateText(uid) { $0 = updated } }
        case .setClipVolume(let reference, let volume):
            let item = try clip(reference)
            // The exporter honours the volume slider only for bumpers and mixed-in
            // B-roll; a main clip's slider is a preview-only control, so applying
            // it would report a change the rendered file never shows.
            guard item.bumper || item.role == .cutaway else {
                throw BuilderCommandFailure.invalid("Clip volume applies to bumpers and B-roll only; mute main clips with set_clip_muted or set_track_muted.")
            }
            if item.volume != volume { model.updateClip(item.uid) { $0.volume = volume } }
        case .setClipPosition(let reference, let position):
            let item = try clip(reference)
            try requireWideFraming(item, model: model)
            if item.position != position { model.updateClip(item.uid) { $0.position = position } }
        case .setClipCrop(let reference, let fraction):
            let item = try clip(reference)
            try requireWideFraming(item, model: model)
            if item.cropXFrac != fraction { model.updateClip(item.uid) { $0.cropXFrac = fraction } }
        case .splitZoomFeeds(let reference, let left, let right):
            let item = try clip(reference)
            try requireWideFraming(item, model: model)
            // The store pins the source to track 0 and the new feed to track 1;
            // refusing elsewhere keeps a clip from being silently relocated.
            guard item.track == 0 else {
                throw BuilderCommandFailure.invalid("Split zoom feeds requires the clip on track 0.")
            }
            guard library.layouts.contains(where: { $0.name == "50-50 Horizontal" && !$0.areas.isEmpty }) else {
                throw BuilderCommandFailure.invalid("Split feeds require a wide clip and the 50-50 Horizontal layout.")
            }
            guard !model.document.videoTrack.contains(where: {
                $0.uid != item.uid && ($0.track == 1 || (item.track == 1 && $0.track == 0)) && $0.sceneID == item.sceneID
                    && abs($0.startTime - item.startTime) < 0.01
                    && abs(($0.sourceStart ?? 0) - (item.sourceStart ?? 0)) < 0.01
                    && abs(($0.sourceEnd ?? 0) - (item.sourceEnd ?? 0)) < 0.01
            }) else { throw BuilderCommandFailure.invalid("Clip already has a split partner.") }
            let videoID = library.videoID(for: item, scene: nil)
            guard let video = library.videos.first(where: { $0.id == videoID }), video.width > 0 else {
                throw BuilderCommandFailure.invalid("Split feeds require captured source dimensions.")
            }
            model.splitZoomFeeds(item.uid, leftName: left, rightName: right,
                                 sourceAspect: Double(video.width) / Double(max(1, video.height)))
        case .clearTimeline: model.clear()
        case .setSoundVolume(let reference, let volume):
            let item = try sound(reference)
            if item.volume != volume { model.updateSound(item.uid) { $0.volume = volume } }
        case .setSoundRange(let reference, let start, let duration):
            let item = try sound(reference)
            if item.startTime != start || item.duration != duration {
                model.updateSound(item.uid) { $0.startTime = start; $0.duration = duration }
            }
        case .moveSound(let reference, let at):
            let item = try sound(reference)
            guard at + item.duration <= 86400 else { throw BuilderCommandFailure.bounds("Sound exceeds one day.") }
            if item.startTime != at { model.updateSound(item.uid) { $0.startTime = at } }
        case .setText(let reference, let text):
            let uid = try id(reference)
            guard let item = model.textItem(uid) else { throw BuilderCommandFailure.unknownID }
            if item.text != text { model.updateText(uid) { $0.text = text } }
        case .setTextPosition(let reference, let position):
            let uid = try id(reference)
            guard let item = model.textItem(uid) else { throw BuilderCommandFailure.unknownID }
            // Fractional placement overrides position. Clear it so this setter
            // has the stated visible effect, even on text created by addText.
            if item.position != position || item.xFrac != nil || item.yFrac != nil {
                model.updateText(uid) { $0.position = position; $0.xFrac = nil; $0.yFrac = nil }
            }
        case .setOverlayRange(let reference, let at, let duration):
            let uid = try id(reference)
            if let item = model.textItem(uid) {
                if item.startTime != at || item.endTime != at + duration {
                    model.updateText(uid) { $0.startTime = at; $0.endTime = at + duration }
                }
            } else if let item = model.imageItem(uid) {
                if item.startTime != at || item.endTime != at + duration {
                    model.updateImage(uid) { $0.startTime = at; $0.endTime = at + duration }
                }
            } else if let item = model.overlayBlock(uid) {
                if item.startTime != at || item.duration != duration {
                    model.updateOverlayBlock(uid) { $0.startTime = at; $0.duration = duration }
                }
            } else { throw BuilderCommandFailure.unknownID }
        case .setOverlayTransitions(let reference, let a, let b):
            let uid = try id(reference)
            if let item = model.textItem(uid) {
                if item.transIn != a || item.transOut != b { model.updateText(uid) { $0.transIn = a; $0.transOut = b } }
            } else if let item = model.imageItem(uid) {
                if item.transIn != a || item.transOut != b { model.updateImage(uid) { $0.transIn = a; $0.transOut = b } }
            } else if model.overlayBlock(uid) != nil {
                try unsupported("Overlay blocks have no block-level transitions; their composition retains its own transitions.")
            } else { throw BuilderCommandFailure.unknownID }
        case .setClipSpeed(let reference, let speed):
            let item = try clip(reference)
            guard item.effectiveSpeed != speed else { return }
            let duration = ((item.sourceSpan / speed) * 10).rounded() / 10
            let ceiling = item.bumper ? item.sourceEnd : library.sourceDuration(for: item)
            guard let start = item.sourceStart, let ceiling, start.isFinite, ceiling.isFinite,
                  start >= 0, duration.isFinite, duration >= 0.1, duration <= 86400,
                  start + duration * speed <= ceiling + 1e-9 else {
                throw BuilderCommandFailure.bounds("Rounded speed duration exceeds the available source or timing limits.")
            }
            model.updateClip(item.uid) { $0.speed = speed == 1 ? nil : speed; $0.duration = duration }
        case .setClipFades(let reference, let a, let b):
            let item = try clip(reference)
            guard item.isCutaway else { throw BuilderCommandFailure.invalid("Clip fades require B-roll.") }
            // Same cap as enforceCutawayRules, but refuse rather than silently
            // change the requested value. Speed edits still use model clamping.
            guard a <= item.duration / 2, b <= item.duration / 2 else {
                throw BuilderCommandFailure.bounds("Each fade must be at most half the clip duration.")
            }
            if item.fadeIn != a || item.fadeOut != b { model.updateClip(item.uid) { $0.fadeIn = a; $0.fadeOut = b } }
        case .setClipCaptions(let reference, let captions):
            let item = try clip(reference)
            guard (!item.bumper && !item.isCutaway) || captions == "none" else {
                throw BuilderCommandFailure.invalid("Bumpers and B-roll cannot have captions.")
            }
            if item.captions != captions { model.updateClip(item.uid) { $0.captions = captions } }
        case .setClipTransitions(let reference, let a, let b):
            let item = try clip(reference)
            guard (item.transIn ?? "cut") != a || (item.transOut ?? "cut") != b else { return }
            let transIn = a == "cut" ? nil : a
            let transOut = b == "cut" ? nil : b
            if item.transIn != transIn || item.transOut != transOut {
                model.updateClip(item.uid) { $0.transIn = transIn; $0.transOut = transOut }
            }
        case .setClipCenterStage(let reference, let enabled):
            let item = try clip(reference)
            guard !enabled || (!item.bumper && !item.isCutaway && item.wide
                && model.area(forTrack: item.track, at: item.startTime) == nil
                && !model.document.isOrphaned(item)) else {
                throw BuilderCommandFailure.invalid("Tracking requires a wide main clip in Full Screen.")
            }
            if item.centerStage != enabled { model.updateClip(item.uid) { $0.centerStage = enabled } }
        case .setClipAreaWindow(let reference, let x, let y, let width, let height):
            let item = try clip(reference)
            guard !item.bumper, !item.coverAllAreas,
                  let area = model.area(forTrack: item.track, at: item.startTime) else {
                throw BuilderCommandFailure.invalid("Area framing requires a clip assigned to a crop area.")
            }
            let videoID = library.scenes.first { $0.id == item.sceneID }?.videoID
            guard let video = library.videos.first(where: { $0.id == videoID || $0.path == item.videoFile }),
                  video.width > 0, video.height > 0 else {
                throw BuilderCommandFailure.invalid("Area framing requires captured source dimensions.")
            }
            let original = item.areaWindow ?? RenderContext.$settings.withValue(model.document.renderSettings) {
                AreaFramer.defaultWindow(for: area, sourceSize: CGSize(width: video.width, height: video.height))
            }
            let ratio = original.hFrac / max(0.001, original.wFrac)
            guard width >= 0.1, abs(height - width * ratio) <= 1e-6 else {
                throw BuilderCommandFailure.bounds("Area resize must preserve its proportions and use width of at least 0.1.")
            }
            let window = FreeCropRect(xFrac: x, yFrac: y, wFrac: width, hFrac: height)
            if item.areaWindow != window { model.updateClip(item.uid) { $0.areaWindow = window } }
        case .setTrackCaptions(let index, let captions):
            try track(index)
            if model.document.trackSettings[index].captions != captions {
                model.updateTrackSettings(index) { $0.captions = captions }
            }
        case .setTrackMuted(let index, let muted):
            try track(index)
            if model.document.trackSettings[index].muted != muted { model.updateTrackSettings(index) { $0.muted = muted } }
        case .setTrackPosition(let index, let position):
            try track(index)
            guard model.document.cropBlocks.contains(where: { $0.layout.isFullScreen }) else {
                throw BuilderCommandFailure.invalid("Track position requires a Full Screen block.")
            }
            if model.document.trackSettings[index].defaultPosition != position {
                model.updateTrackSettings(index) { $0.defaultPosition = position }
            }
        case .setTrackCrop(let index, let fraction):
            try track(index)
            guard model.document.cropBlocks.contains(where: { $0.layout.isFullScreen }) else {
                throw BuilderCommandFailure.invalid("Track crop requires a Full Screen block.")
            }
            if model.document.trackSettings[index].defaultCropXFrac != fraction {
                model.updateTrackSettings(index) { $0.defaultCropXFrac = fraction }
            }
        case .setRenderSettings(let settings): model.setRenderSettings(settings.applying(to: model.document.renderSettings))
        case .setPacing(let pacing): model.setPacing(pacing.value)
        default: throw BuilderCommandFailure.invalid("Not an expansion command.")
        }
    }
}
