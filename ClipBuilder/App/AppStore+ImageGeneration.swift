import Foundation
import CoreGraphics

extension AppStore {
    private static func timeLabel(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// `subject` and `placement` are in source-frame fractions; the overlay
    /// is placed in output-frame fractions through `placement`. In edit mode
    /// only the visible window of the frame is sent, so the edited picture
    /// matches what the render shows and covers exactly that box.
    func generateSticker(prompt: String, mode: ImageGeneration.Mode,
                         video: URL?, sourceTime: Double?, subject: CGRect?, subjectName: String? = nil,
                         placement: ImageGeneration.Placement = .fullFrame, follow: Bool = false, builder: BuilderTimelineModel) {
        let generation = profileGeneration
        let projectID = activeProjectID
        let timelineID = builder.timelineID
        let profileName = builder.profileName
        let playhead = builder.playhead
        let folder = AssetKind.images.rootURL.appendingPathComponent("Generated", isDirectory: true)
        let ai = ai
        jobs.start(.generateImage, title: "Generate Image — \(prompt)", project: activeProject,
                   profileGeneration: generation) { [weak self, weak builder] log in
            let started = Date()
            var frame: Data?
            if let video, let sourceTime {
                frame = await ThumbnailService.jpegFrame(url: video, at: sourceTime, maxDimension: 1280)
            }
            try Task.checkCancellation()
            var selectedSubject = subject
            if selectedSubject == nil, mode == .sticker, let frame {
                let image = try await AppJobWork.run { try ImageGeneration.decode(frame) }
                let faces = try await CenterStageService.faces(in: image).filter { placement.shows($0) }
                selectedSubject = faces.max { $0.width * $0.height < $1.width * $1.height }
                if faces.count > 1 { log("Found \(faces.count) faces on screen; using the largest face.") }
            }
            var requestSubject = selectedSubject
            if mode == .edit, let full = frame, placement.window != FreeCropRect() {
                // Edit what the render shows: cut the visible window out of the
                // source frame and express the subject inside that window.
                let window = placement.window
                frame = try await AppJobWork.run {
                    let image = ImageGeneration.cropped(try ImageGeneration.decode(full), to: window)
                    guard let data = ImageGeneration.jpeg(image) else {
                        throw AIError.unusableResponse("The frame at the playhead could not be prepared.")
                    }
                    return data
                }
                requestSubject = selectedSubject.map {
                    CGRect(x: ($0.minX - window.xFrac) / max(0.001, window.wFrac),
                           y: ($0.minY - window.yFrac) / max(0.001, window.hFrac),
                           width: $0.width / max(0.001, window.wFrac), height: $0.height / max(0.001, window.hFrac))
                }
            }
            let request = ImageGeneration.Request(prompt: prompt, mode: mode, frame: frame,
                                                  subject: requestSubject, subjectName: subjectName)
            log("Generating image…")
            let raw = try await ai.generateImage(request, timeout: mode == .edit ? 240 : 180, log: log)
            let provenance = AIProvenance(provider: "gemini", task: AITask.imageGeneration.rawValue,
                at: Date(), technique: "Nano Banana", duration: Date().timeIntervalSince(started))
            let result: ImageGeneration.Result
            do {
                result = try await AppJobWork.run {
                    try ImageGeneration.save(raw: raw, mode: mode, prompt: prompt, folder: folder, provenance: provenance)
                }
            } catch {
                // The worker may have been cancelled before its closure began.
                await Task.detached { ImageGeneration.removeScratch(containing: raw) }.value
                throw error
            }
            try Task.checkCancellation()
            guard let self, self.profileGeneration == generation else { throw CancellationError() }
            AIRunCapture.current?.append(provenance, prompt: "\(prompt)\nOutput: \(result.path)")
            let fileName = (result.path as NSString).lastPathComponent
            if let builder, self.activeProjectID == projectID,
               builder.timelineID == timelineID, builder.profileName == profileName {
                let geometry = ImageGeneration.overlayGeometry(mode: mode, subject: selectedSubject, placement: placement)
                let uid = builder.addImage(path: result.path, at: playhead)
                builder.updateImage(uid) { item in
                    item.xFrac = geometry.xFrac
                    item.yFrac = geometry.yFrac
                    item.wFrac = geometry.wFrac
                    // Placed on a face or over the frame on purpose: never
                    // nudged clear of platform chrome.
                    item.keepsPlacement = true
                }
                if follow, mode == .sticker {
                    self.trackImageOverlay(uid, builder: builder, seed: selectedSubject)
                }
                log("Added \(fileName) to the timeline at \(Self.timeLabel(playhead)); also in Images › Generated.")
            } else {
                log("Timeline changed; \(fileName) is saved in Images › Generated.")
            }
            return .generatedImage(GeneratedImage(image: result, subject: selectedSubject,
                                                  provenance: provenance, placement: placement))
        }
    }
}

extension AppStore {
    func stopTrackingImageOverlay(_ uid: UUID, builder: BuilderTimelineModel) {
        for job in jobs.running where job.kind == .trackImage && job.subjectID == uid.uuidString {
            jobs.cancel(job.id)
        }
        guard let item = builder.imageItem(uid), item.track != nil else { return }
        let key = ImageTrackKey.interpolate(item.track ?? [], at: builder.playhead)
        builder.updateImage(uid) {
            $0.xFrac = key?.xFrac ?? $0.xFrac
            $0.yFrac = key?.yFrac ?? $0.yFrac
            $0.wFrac = item.track?.first?.wFrac ?? $0.wFrac
            $0.track = nil
        }
    }

    func trackImageOverlay(_ uid: UUID, builder: BuilderTimelineModel, seed sourceSeed: CGRect? = nil) {
        guard let item = builder.imageItem(uid),
              let clip = builder.pictureClip(at: item.startTime),
              let video = builder.sourceURL(for: clip) else {
            presentNotice("Track Face", "Place the image over a video clip first.")
            return
        }
        let generation = profileGeneration
        let projectID = activeProjectID
        let timelineID = builder.timelineID
        let revision = builder.revision
        let samples = ImageTracker.times(start: item.startTime, end: min(item.endTime, clip.startTime + clip.duration)).map {
            ImageTracker.Sample(time: $0, sourceTime: builder.sourceTime(for: clip, atTimeline: $0),
                                placement: builder.framePlacement(for: clip, atTimeline: $0))
        }
        guard let placement = samples.first?.placement else { return }
        let outputAspect = builder.document.renderSettings.aspectRatio
        jobs.start(.trackImage, title: "Track Face — \(item.displayName)", project: activeProject,
                   profileGeneration: generation, subjectID: uid.uuidString) { [weak self, weak builder] log in
            let seed = try await AppJobWork.run {
                if let sourceSeed { return sourceSeed }
                let image = try ImageGeneration.decode(Data(contentsOf: item.url))
                let height = item.wFrac * outputAspect * Double(image.height) / Double(max(1, image.width))
                return placement.inputRect(CGRect(x: item.xFrac - item.wFrac / 2,
                    y: item.yFrac - height / 2, width: item.wFrac, height: height))
            }
            log("Following the nearest face…")
            let track = try await ImageTracker.track(video: video, samples: samples, seed: seed, end: item.endTime)
            try Task.checkCancellation()
            guard let self, let builder, self.profileGeneration == generation,
                  self.activeProjectID == projectID, builder.timelineID == timelineID,
                  builder.revision == revision, builder.imageItem(uid) == item else {
                throw AppJobEmptyResult(message: "The timeline changed. Run Follow Face again for the current placement.")
            }
            guard !track.isEmpty else { throw AppJobEmptyResult(message: "No video frames were available to track.") }
            builder.updateImage(uid) { $0.track = track; $0.keepsPlacement = true }
            log("Tracked, \(track.count) keys")
            return nil
        }
    }
}
