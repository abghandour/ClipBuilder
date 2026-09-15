#if PERFORMANCE_BASELINE
import AppKit
import Foundation
import Synchronization

/// Compiled only into the dedicated profiling build. Uses production services,
/// an injected store, and a fresh database; never opens the user's library.
@MainActor
enum PerformanceBaseline {
    private struct Configuration: Decodable {
        var scenario: String
        var source: String
        var root: String
        var provider: String?
        var model: String?
        var localOnly: Bool
        var disableFinishingCache: Bool?
        var disableAssemblyCache: Bool?
        var captureOverlayInputs: Bool?
        var disableReelDetectorCache: Bool?
        var framingClipCount: Int?
        var disableFramingCache: Bool?
        var incrementalFinishing: String?
    }

    private struct Phase: Encodable {
        var name: String
        var seconds: Double
        var outcome: String
        var successfulFFmpegCalls: Int
        var successfulVideoEncodes: Int
    }

    private static var configuration: Configuration!
    private static var started = false
    private static var phases: [Phase] = []

    static func makeStore() -> AppStore {
        do {
            guard let path = ProcessInfo.processInfo.environment["CLIPBUILDER_BASELINE_CONFIG"] else {
                throw failure("Launch this build with scripts/performance_baseline.py.")
            }
            let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let root = URL(fileURLWithPath: config.root).resolvingSymlinksInPath()
            let data = root.appendingPathComponent("data", isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".baseline-owned").path),
                  SettingsStore.dataDirectory.resolvingSymlinksInPath() == data,
                  ["analysis", "render", "export", "metadata", "playback", "contention"].contains(config.scenario),
                  !FileManager.default.fileExists(atPath: data.appendingPathComponent("baseline.db").path) else {
                throw failure("A baseline requires a fresh, marked scratch directory and matching data-folder argument.")
            }
            configuration = config
            var profile = BrandProfile(name: "Performance Baseline")
            profile.sourceFolder = root.appendingPathComponent("media").path
            profile.outputFolder = root.appendingPathComponent("outputs").path
            profile.captionLanguages = ["en"]
            profile.contentDomain = "combat sports"
            profile.tagSchema = ["action": ["fight", "striking", "grappling"]]
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: profile.outputFolder), withIntermediateDirectories: true)
            let database = try Database(path: data.appendingPathComponent("baseline.db"))
            let settings = SettingsStore.loadSettings()
            let store = AppStore(settings: settings, profiles: [profile], active: profile,
                                 ai: AIService(config: settings.ai), database: database)
            store.diagnosticLogSink = { channel, line in log("[\(channel)] \(line)") }
            return store
        } catch {
            FileHandle.standardError.write(Data("Baseline setup failed: \(error)\n".utf8))
            exit(2)
        }
    }

    static func run(store: AppStore) async {
        guard !started else { return }
        started = true
        do {
            // Let the window settle; the external recorder starts before launch.
            try await Task.sleep(for: .seconds(2))
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard let database = store.database else { throw failure("Missing scratch database") }
            let source = URL(fileURLWithPath: configuration.source)
            let info = await FFmpeg.info(of: source)
            guard info.duration >= 5, info.width > 0 else { throw failure("Source must be a readable video at least 5 seconds long") }
            _ = try await database.registerVideo(hash: ContentHash.fingerprint(of: source),
                filename: source.lastPathComponent, path: source.path, duration: info.duration,
                width: info.width, height: info.height, wide: info.width > info.height)
            guard let video = try await database.fetchVideos().first else { throw failure("Source registration failed") }
            log("SOURCE duration=\(info.duration) dimensions=\(info.width)x\(info.height) localOnly=\(configuration.localOnly)")
            if configuration.scenario == "analysis" {
                try await analyze(video: video, database: database, store: store)
            } else {
                let document = try await seedTimeline(video: video, database: database, store: store)
                if configuration.scenario == "metadata" {
                    try await metadata(document: document, source: source, database: database, store: store)
                } else if configuration.scenario == "render" || configuration.scenario == "export" {
                    try await render(document: document, database: database, store: store)
                } else if configuration.scenario == "contention" {
                    try await contention(document: document, video: video, database: database, store: store)
                } else {
                    try await playback(store: store)
                }
            }
            try writeReport(outcome: "completed", error: nil)
        } catch {
            log("FAILED: \(error)")
            try? writeReport(outcome: "failed", error: String(describing: error))
        }
        await store.flushForTermination()
        store.hasFlushedForTermination = true
        NSApplication.shared.terminate(nil)
    }

    private static func analyze(video: VideoRecord, database: Database, store: AppStore) async throws {
        // Isolate detector cold/warm reads from remote latency. The warm pass
        // deliberately uses the same DB entry, not a second direct scan.
        let detectors = try await measure("detectors-cold") {
            guard let result = await store.cachedDetectors(for: video) else { throw failure("Detector scan failed") }
            return result
        }
        _ = try await measure("detectors-warm") { await store.cachedDetectors(for: video) }
        // Retained so paired runs can prove the scan modes report identical events.
        let detectorEncoder = JSONEncoder()
        detectorEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try detectorEncoder.encode(detectors)
            .write(to: URL(fileURLWithPath: configuration.root).appendingPathComponent("detectors.json"))
        if configuration.localOnly {
            _ = try await measure("analysis-grid-local-only") {
                await ThumbnailService.jpegFrames(url: video.url, at: Analyzer.frameTimestamps(duration: video.duration),
                    maxDimension: CGFloat(AnalysisImageBudget.longestEdge))
            }
            _ = try await measure("tracking-local-only") {
                try await CenterStageService().cameraPath(source: video.url, start: 0,
                    duration: min(60, video.duration), tuning: .balanced)
            }
            // Portrait fit, then both framing cameras, inside one run-scoped
            // frame cache exactly as the analysis pipeline nests them.
            let scenes = try await seedScenes(video: video, database: database)
            let cache = SampledFrameCache()
            try await SampledFrameCache.$current.withValue(cache) { @MainActor in
                _ = try await measure("portrait-fit-local-only") {
                    var good = 0, poor = 0, none = 0
                    for scene in scenes {
                        guard let result = await Analyzer.portraitFit(url: video.url, start: scene.startTime,
                            end: scene.endTime, videoWidth: video.width, videoHeight: video.height,
                            frameCache: cache) else { none += 1; continue }
                        switch result.fit {
                        case .fits: good += 1
                        case .tooWide: poor += 1
                        case .noPeople: none += 1
                        }
                    }
                    log("PORTRAIT_FIT good=\(good) poor=\(poor) none=\(none) visionRequests=\(await cache.visionRequests)")
                }
                _ = try await measure("framing-static-local-only") {
                    let summary = try await FramingService.detectFraming(video: video, database: database,
                        camera: FramingService.staticCamera, tagFramedPeople: true, log: { log($0) })
                    log("FRAMING_STATIC framed=\(summary.framed) skipped=\(summary.skipped) visionRequests=\(await cache.visionRequests)")
                }
                // Retained so paired runs can prove identical framing decisions.
                try await retainFraming(video: video, database: database, name: "framing-static.json")
                _ = try await measure("framing-tracked-local-only") {
                    let summary = try await FramingService.detectFraming(video: video, database: database,
                        camera: "balanced", tagFramedPeople: false, log: { log($0) })
                    log("FRAMING_TRACKED framed=\(summary.framed) skipped=\(summary.skipped) visionRequests=\(await cache.visionRequests)")
                }
                try await retainFraming(video: video, database: database, name: "framing-tracked.json")
            }
        } else {
            let analyzer = Analyzer(ai: AIService(config: store.settings.ai))
            _ = try await measure("analysis-ai-and-scene-tracking") {
                try await analyzer.analyzeVisual(video: video, profile: store.activeProfile, database: database,
                    runName: "Performance baseline", provider: configuration.provider, model: configuration.model,
                    breakdownTags: ["fight", "striking"], centerStagePaths: true,
                    smartSampling: true, cuts: detectors.cuts, log: { log($0) },
                    progress: { value, message in log("ANALYSIS \(value) \(message)") })
            }
        }
        try await measure("detector-cancellation") {
            let job = Task { try await FFmpeg.detectors(of: video.url, duration: video.duration) }
            try await Task.sleep(for: .seconds(1))
            let requested = ContinuousClock.now
            PerfSignpost.event("BaselineCancelRequested", metadata: "detectors")
            job.cancel()
            do {
                _ = try await job.value
                log("CANCEL detector returned normally (possibly already finished); latency=\(requested.duration(to: .now))")
            } catch is CancellationError {
                log("CANCEL detector acknowledged; latency=\(requested.duration(to: .now))")
            }
        }
    }

    private struct FramingEvidence: Encodable { var id: Int64; var path: String?; var tags: [String] }

    private static func retainFraming(video: VideoRecord, database: Database, name: String) async throws {
        let evidence = try await database.fetchScenes(videoID: video.id).map {
            FramingEvidence(id: $0.id, path: $0.centerStagePathJSON, tags: $0.tags.sorted())
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: URL(fileURLWithPath: configuration.root).appendingPathComponent(name))
    }

    /// Forty two-second scene ranges over the source.
    private static func fixtureRanges(duration: Double) -> [(start: Double, end: Double)] {
        (0..<40).map { index in
            let start = Double(index * 2).truncatingRemainder(dividingBy: max(2, duration - 3))
            return (start: start, end: start + 2)
        }
    }

    private static func seedScenes(video: VideoRecord, database: Database) async throws -> [SceneRecord] {
        _ = try await database.saveAnalysis(videoID: video.id, runName: "Deterministic render fixture",
            instructions: "Synthetic scene boundaries and captions for performance measurement", sampleInterval: nil,
            notesJSON: nil, tagRanges: ["fixture": fixtureRanges(duration: video.duration)], moments: [],
            analyzedTags: ["fixture"], provider: nil, model: nil, mode: "visual")
        return try await database.fetchScenes(videoID: video.id)
    }

    private static func seedTimeline(video: VideoRecord, database: Database, store: AppStore) async throws -> TimelineDocument {
        let framingClipCount = min(40, max(0, configuration.framingClipCount ?? 1))
        log("FIXTURE clips=40 framingClips=\(video.wide ? framingClipCount : 0) ffmpegJobs=\(FFmpeg.jobLimit)")
        let ranges = fixtureRanges(duration: video.duration)
        var scenes = try await seedScenes(video: video, database: database)
        if let first = scenes.first, video.wide {
            let width = (9.0 / 16) * Double(video.height) / Double(video.width)
            let path = SceneCameraPath(camera: "balanced", keyframes: [
                CameraPathKeyframe(t: 0, x: 0.2, y: 0, w: width, h: 1),
                CameraPathKeyframe(t: first.duration, x: min(0.4, 1 - width), y: 0, w: width, h: 1)
            ])
            let json = String(decoding: try JSONEncoder().encode(path), as: UTF8.self)
            try await database.setSceneCenterStagePath(first.id, json: json)
            scenes = try await database.fetchScenes(videoID: video.id)
        }
        let transcripts = ranges.enumerated().map { index, range in
            TranscriptSegment(start: range.start, end: range.end, text: "Baseline caption \(index + 1)")
        }
        try await database.replaceTranscripts(videoID: video.id, language: "en", isTranslation: false,
            segments: transcripts, provider: nil, model: nil)
        var document = TimelineDocument()
        for index in 0..<40 {
            let scene = scenes[index % scenes.count]
            var clip = TimelineClip()
            clip.sceneID = scene.id
            clip.videoFile = video.path
            clip.sourceStart = scene.startTime
            clip.sourceEnd = scene.endTime
            clip.duration = 2
            clip.startTime = Double(index * 2)
            clip.wide = video.wide
            clip.centerStage = index < framingClipCount && video.wide
            clip.captions = "bottom"
            clip.transIn = [10, 20].contains(index) ? "fade" : nil
            document.videoTrack.append(clip)
        }
        document.textOverlays = [TextOverlayItem(text: "Performance baseline", startTime: 0, endTime: 80)]
        var block = OverlayBlockItem()
        block.duration = 80
        block.composition.texts = [TextOverlayItem(text: "Overlay block", startTime: 0, endTime: 80)]
        document.overlayBlocks = [block]
        let projectID = try await database.createProject(profileName: store.activeProfile.profileName,
            name: "Performance baseline", videoIDs: [video.id])
        store.activeProjectID = projectID
        store.projects = try await database.fetchProjects()
        store.videos = [video]
        store.scenes = scenes
        store.builder.updateScenes(scenes)
        let timelineID = try await database.createTimeline(projectID: projectID, name: "40 clips, two fades",
            documentJSON: String(decoding: try JSONEncoder().encode(document), as: UTF8.self))
        guard let row = try await database.fetchTimeline(id: timelineID) else { throw failure("Missing fixture timeline") }
        store.timelines = [row]
        store.openTimelineRecord(row)
        return document
    }

    /// Isolates the production post-render trait path using an already exported video.
    private static func metadata(document: TimelineDocument, source: URL, database: Database, store: AppStore) async throws {
        for name in ["metadata-cold", "metadata-warm"] {
            let copy = URL(fileURLWithPath: configuration.root).appendingPathComponent("outputs/\(name).mp4")
            try FileManager.default.copyItem(at: source, to: copy)
            let duration = await FFmpeg.duration(of: copy)
            let id = try await database.insertGeneratedVideo(path: copy.path, duration: duration, timelineJSON: "{}",
                wizardProvider: nil, wizardModel: nil)
            try await measure(name) {
                await ReelTraitRecording.record(url: copy, id: id, database: database, document: document,
                    scenes: store.scenes, log: { log($0) })
                guard let traits = try await database.reelTraits(kind: "generated", videoID: String(id)) else {
                    throw failure("No reel traits were persisted")
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(traits).write(to: URL(fileURLWithPath: configuration.root).appendingPathComponent("\(name)-traits.json"))
            }
        }
    }

    private static func render(document: TimelineDocument, database: Database, store: AppStore) async throws {
        let incremental = try configuration.incrementalFinishing.map {
            guard let mode = MultitrackRenderer.IncrementalFinishing(rawValue: $0) else {
                throw failure("Unknown incrementalFinishing mode \($0)")
            }
            return mode
        } ?? .editsOnly
        let renderer = MultitrackRenderer(render: RenderEngine(),
            finishingCacheEnabled: configuration.disableFinishingCache != true,
            assemblyCacheEnabled: configuration.disableAssemblyCache != true,
            framingCacheEnabled: configuration.disableFramingCache != true,
            incrementalFinishing: incremental)
        // The second edit changes the same caption again: the steady state
        // after finishing ranges exist, with one range to rebuild.
        let edits = ["render-caption-edit": "Changed baseline caption",
                     "render-second-edit": "Changed baseline caption again"]
        for name in ["render-cold", "render-warm", "render-caption-edit", "render-second-edit"] {
            if let text = edits[name], let video = store.videos.first {
                var captions = try await database.transcriptSegments(videoID: video.id, start: 0,
                    end: video.duration, language: "en")
                guard !captions.isEmpty else { throw failure("Missing fixture captions") }
                captions[0].text = text
                try await database.replaceTranscripts(videoID: video.id, language: "en", isTranslation: false,
                    segments: captions, provider: nil, model: nil)
            }
            let result = try await measure(name) {
                try await renderer.render(document: document, scenes: store.scenes,
                    profile: store.activeProfile, database: database, preview: configuration.scenario != "export", emit: { log($0) })
            }
            let retained = URL(fileURLWithPath: configuration.root)
                .appendingPathComponent("outputs/\(name).mp4")
            if configuration.scenario == "export" {
                try FileManager.default.copyItem(at: result.url, to: retained)
            } else {
                try FileManager.default.moveItem(at: result.url, to: retained)
            }
        }
        try await measure("render-cancellation") {
            var changed = document
            changed.videoTrack[0].sourceStart = (changed.videoTrack[0].sourceStart ?? 0) + 0.1
            let input = changed
            let job = Task {
                try await renderer.render(document: input, scenes: store.scenes,
                    profile: store.activeProfile, database: database, preview: true, emit: { log($0) })
            }
            try await Task.sleep(for: .seconds(1))
            let requested = ContinuousClock.now
            PerfSignpost.event("BaselineCancelRequested", metadata: "render")
            job.cancel()
            do {
                let result = try await job.value
                try? FileManager.default.removeItem(at: result.url)
                log("CANCEL render returned normally (possibly already finished); latency=\(requested.duration(to: .now))")
            } catch is CancellationError {
                log("CANCEL render acknowledged; latency=\(requested.duration(to: .now))")
            }
        }
    }

    private static func contention(document: TimelineDocument, video: VideoRecord,
                                   database: Database, store: AppStore) async throws {
        let renderer = MultitrackRenderer(render: RenderEngine())
        let analysis = Task { try await FFmpeg.detectors(of: video.url, duration: video.duration) }
        let background = Task {
            try await renderer.render(document: document, scenes: store.scenes,
                profile: store.activeProfile, database: database, preview: true, emit: { log($0) })
        }
        defer { analysis.cancel(); background.cancel(); store.stopBuilderPreview() }
        do {
            try await measure("contention-ready") {
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while true {
                    let encoding = await MediaWorkScheduler.current.snapshot(.encoding)
                    let decoding = await MediaWorkScheduler.current.snapshot(.decoding)
                    if encoding.active > 0 && decoding.active > 0 { break }
                    guard ContinuousClock.now < deadline else { throw failure("Background media did not overlap") }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            _ = try await measure("probe-under-load") {
                try await FFmpeg.probe(["-v", "error", "-show_entries", "format=duration", "-of", "json", video.path])
            }
            try await measure("preview-under-load") {
                store.startBuilderPreview(from: 30)
                try await waitForPreview(store)
            }
            try await measure("contention-cancellation") {
                PerfSignpost.event("BaselineCancelRequested", metadata: "contention")
                store.stopBuilderPreview()
                analysis.cancel()
                background.cancel()
                switch await background.result {
                case .success(let result):
                    try? FileManager.default.removeItem(at: result.url)
                    log("CONTENTION background render completed before cancellation")
                case .failure(let error):
                    guard error is CancellationError else { throw error }
                    log("CONTENTION background render acknowledged cancellation")
                }
                switch await analysis.result {
                case .success:
                    log("CONTENTION detectors completed before cancellation")
                case .failure(let error):
                    guard error is CancellationError else { throw error }
                    log("CONTENTION detectors acknowledged cancellation")
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while store.isBuilderPreviewRendering {
                    guard ContinuousClock.now < deadline else { throw failure("Prefetch did not stop") }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        } catch {
            analysis.cancel()
            background.cancel()
            _ = await analysis.result
            if case .success(let result) = await background.result {
                try? FileManager.default.removeItem(at: result.url)
            }
            throw error
        }
    }

    private static func playback(store: AppStore) async throws {
        try await measure("preview-cold-start") {
            store.startBuilderPreview(from: 0)
            try await waitForPreview(store)
        }
        store.stopBuilderPreview()
        let settled = ContinuousClock.now.advanced(by: .seconds(60))
        while store.isBuilderPreviewRendering {
            guard ContinuousClock.now < settled else { throw failure("Cold preview prefetch did not stop") }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await measure("preview-warm-start") {
            store.startBuilderPreview(from: 0)
            try await waitForPreview(store)
        }
        try await measure("preview-playback-20s") {
            log("PLAYBACK WINDOW: interact with the timeline now; capture records actual UI work.")
            try await Task.sleep(for: .seconds(20))
            log("PLAYBACK observed playhead=\(store.builder.playhead), active=\(store.builderPreview != nil)")
        }
        store.stopBuilderPreview()
        try await measure("preview-cancellation") {
            store.startBuilderPreview(from: 50)
            try await Task.sleep(for: .milliseconds(300))
            PerfSignpost.event("BaselineCancelRequested", metadata: "preview")
            store.stopBuilderPreview()
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while store.isBuilderPreviewRendering {
                guard ContinuousClock.now < deadline else { throw failure("Preview still rendering 60 seconds after cancellation") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static func waitForPreview(_ store: AppStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while store.builderPreview == nil {
            guard ContinuousClock.now < deadline else { throw failure("Preview did not start within 120 seconds") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func measure<T: Sendable>(_ name: String, _ operation: @MainActor () async throws -> T) async throws -> T {
        let commands = Mutex<[[String]]>([])
        let captureErrors = Mutex<[String]>([])
        let captureDirectory = configuration.captureOverlayInputs == true
            ? URL(fileURLWithPath: configuration.root).appendingPathComponent("overlay-inputs/\(name)") : nil
        let start = ContinuousClock.now
        let interval = PerfSignpost.begin("BaselinePhase", metadata: name)
        log("PHASE START \(name) epoch=\(Date().timeIntervalSince1970)")
        var outcome = "completed"
        defer {
            PerfSignpost.end(interval)
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let calls = commands.withLock { $0 }
            let encodes = calls.filter { args in
                guard let i = args.firstIndex(of: "-c:v"), args.indices.contains(i + 1) else { return false }
                return args[i + 1] != "copy"
            }.count
            phases.append(Phase(name: name, seconds: seconds, outcome: outcome,
                successfulFFmpegCalls: calls.count, successfulVideoEncodes: encodes))
            log("PHASE END \(name) seconds=\(seconds) successfulFFmpegCalls=\(calls.count) successfulVideoEncodes=\(encodes) outcome=\(outcome) epoch=\(Date().timeIntervalSince1970)")
            try? writeReport(outcome: "running", error: nil)
        }
        do {
            let result = try await FFmpeg.$commandCompleted.withValue({ args in
                commands.withLock { $0.append(args) }
                if let captureDirectory {
                    do { try captureOverlayInputs(args, directory: captureDirectory) }
                    catch { captureErrors.withLock { $0.append(String(describing: error)) } }
                }
            }) {
                try await ReelTraitExtractor.$stageCompleted.withValue({ stage, seconds in
                    log("TRAIT_STAGE \(stage) seconds=\(seconds)")
                }) {
                    try await ReelTraitRecording.$detectorCacheEnabled.withValue(configuration.disableReelDetectorCache != true) {
                        try await operation()
                    }
                }
            }
            if let error = captureErrors.withLock({ $0.first }) { throw failure("Overlay input capture failed: \(error)") }
            return result
        } catch {
            outcome = String(describing: error)
            throw error
        }
    }

    /// Diagnostic-only snapshots of the real assembly groups and final-pass
    /// inputs. Captures include file copies and are not timing controls.
    nonisolated private static func captureOverlayInputs(_ args: [String], directory: URL) throws {
        guard let output = args.last else { return }
        let basename = URL(fileURLWithPath: output).lastPathComponent
        guard basename == "assembled.mp4" || basename == "with_overlays.mp4" else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if basename == "assembled.mp4", args.contains("concat"), let input = args.firstIndex(of: "-i") {
            let listing = try String(contentsOfFile: args[input + 1], encoding: .utf8)
            let paths = try listing.split(separator: "\n").enumerated().map { index, line in
                guard line.hasPrefix("file '"), line.hasSuffix("'") else { throw failure("Unsupported concat listing") }
                let path = String(line.dropFirst(6).dropLast()).replacingOccurrences(of: "'\\''", with: "'")
                let copy = directory.appendingPathComponent("group-\(index).mp4")
                try FileManager.default.copyItemReplacing(at: URL(fileURLWithPath: path), to: copy)
                return copy.path
            }
            try encoder.encode(paths).write(to: directory.appendingPathComponent("groups.json"), options: .atomic)
        } else if basename == "with_overlays.mp4" {
            var command = args
            for index in args.indices where args[index] == "-i" && args.indices.contains(index + 1) {
                let input = URL(fileURLWithPath: args[index + 1])
                let copy = directory.appendingPathComponent("input-\(index).\(input.pathExtension)")
                try FileManager.default.copyItemReplacing(at: input, to: copy)
                command[index + 1] = copy.path
            }
            let reference = directory.appendingPathComponent("reference.mp4")
            try FileManager.default.copyItemReplacing(at: URL(fileURLWithPath: output), to: reference)
            command[command.count - 1] = reference.path
            try encoder.encode(command).write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        }
    }

    private static func writeReport(outcome: String, error: String?) throws {
        struct Report: Encodable {
            var scenario: String
            var localOnly: Bool
            var outcome: String
            var error: String?
            var phases: [Phase]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = Report(scenario: configuration.scenario, localOnly: configuration.localOnly,
            outcome: outcome, error: error, phases: phases)
        try encoder.encode(report).write(to: URL(fileURLWithPath: configuration.root).appendingPathComponent("phases.json"), options: .atomic)
    }

    nonisolated private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    nonisolated private static func failure(_ message: String) -> NSError {
        NSError(domain: "PerformanceBaseline", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
