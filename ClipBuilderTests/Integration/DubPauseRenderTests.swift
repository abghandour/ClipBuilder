import Foundation
import Testing
@testable import Clip_Builder

@Suite("Dub pause decoded audio", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
struct DubPauseRenderTests {
    @Test("Recipe windows inherit bounded assembly and replace the same bed as the export",
          arguments: ["bounded", "replace", "empty"])
    func recipeWindowPolicy(mode: String) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let source = folder.appendingPathComponent("recipe-policy.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=black:s=320x180:r=30:d=5",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=5",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path], timeout: 60)
        let voice = folder.appendingPathComponent("policy-voice.caf")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=0.2",
            "-c:a", "pcm_f32le", voice.path], timeout: 60)
        var head = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2)
        head.videoFile = source.path; head.wide = false; head.captions = "none"
        head.transIn = "cut"; head.transOut = "cut"
        var tail = head; tail.uid = UUID(); tail.sourceStart = 2; tail.startTime = 2; tail.transIn = "whip_left"
        var document = Fixtures.timelineDocument(clips: [head, tail])
        if mode == "bounded" {
            var bumper = head; bumper.uid = UUID(); bumper.startTime = 4; bumper.duration = 1; bumper.bumper = true
            document.videoTrack.append(bumper)
        }
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 320, customHeight: 180)
        document.dub = DubSettings(language: "en", replaceOriginal: true)
        let onset = mode == "empty" ? 0.1 : 2.8
        document.dubLines = [DubLine(clipUID: onset < 2 ? head.uid : tail.uid, speakerKey: "host", voice: "fixture",
            text: "Event", sourceStart: onset, sourceEnd: onset + 0.2, start: onset, duration: 0.2,
            audio: voice.lastPathComponent)]
        var profile = Fixtures.brand()
        var editing = ProfileEditingDefaults(); editing.transitions.sfxEnabled = mode != "bounded"
        profile.editing = editing
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: false,
            dubSynthesizer: DubSynthesizer(directory: folder))
        let full = try await renderer.render(document: document, scenes: [], profile: profile,
            database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: full.url) }
        let fullClock = try #require(full.clock)
        let lower = 0.5, upper = 4.0
        var window = MultitrackRenderer.windowed(document, from: lower, to: upper)
        let windowHasBumper = window.videoTrack.contains { $0.bumper }
        #expect(!windowHasBumper)
        let planned = RenderContext.$transitions.withValue(editing.transitions) {
            DubRenderWindow.clock(document: document, window: window, scenes: [], camera: "balanced", lower: lower)
        }
        window.dubLines = DubRenderWindow.lines(document, clock: planned, lower: lower, upper: upper)
        let empty = window.dubLines?.isEmpty == true
        let expectedEmpty = mode == "empty"
        #expect(empty == expectedEmpty)
        let preview = try await renderer.render(document: window, scenes: [], profile: profile,
            database: temp.database, preview: true, dubState: DubRenderWindow.state(document: document), emit: { _ in })
        defer { try? FileManager.default.removeItem(at: preview.url) }
        let localClock = try #require(preview.clock)
        if mode == "bounded" {
            // Includes the incoming recipe head and events after it. The
            // window contains no bumper, so this exercises ordinary concatenate.
            for event in [1.0, 1.9, 2.05, 2.8, 3.8] {
                let expected = fullClock.map(event) - fullClock.map(lower)
                let actual = localClock.map(event - lower)
                // Bounded assembly rounds cumulative lengths to frames from the
                // window's own start: within one frame of the full render.
                #expect(abs(actual - expected) <= 1.0 / 30 + 1e-6)
            }
        }
        let fullAudio = try await decode(full.url, in: folder)
        let windowAudio = try await decode(preview.url, in: folder)
        try await Self.checkRecipePolicyAudio(full: fullAudio, window: windowAudio,
            offset: fullClock.map(lower), hasSpeech: !empty)
        if mode != "bounded" {
            // Prove the recipe actually produced audible SFX; silence must
            // come from replacement, not a missing effect or a disabled setting.
            var control = document; control.dub?.enabled = false
            let audible = try await renderer.render(document: control, scenes: [], profile: profile,
                database: temp.database, preview: true, emit: { _ in })
            defer { try? FileManager.default.removeItem(at: audible.url) }
            let controlAudio = try await decode(audible.url, in: folder)
            try await Self.checkRecipeEffect(controlAudio)
        }
    }

    @concurrent
    nonisolated private static func checkRecipePolicyAudio(full: URL, window: URL, offset: Double,
                                                          hasSpeech: Bool) async throws {
        let a = try samples(full), b = try samples(window)
        #expect(energy(a, start: 1.5, duration: 0.6) < 1e-7)
        #expect(energy(b, start: 1.5 - offset, duration: 0.6) < 1e-7)
        if hasSpeech {
            let fullOnset = try #require(stride(from: 2.2, to: 3.1, by: 0.005).first {
                energy(a, start: $0, duration: 0.005) > 0.001
            })
            let windowOnset = try #require(stride(from: 1.7, to: 2.6, by: 0.005).first {
                energy(b, start: $0, duration: 0.005) > 0.001
            })
            // One frame, plus the 5 ms step of the onset search.
            #expect(abs(windowOnset - (fullOnset - offset)) <= 1.0 / 30 + 0.005)
        } else {
            #expect(energy(b, start: 0.1, duration: 2.5) < 1e-7)
        }
    }

    @concurrent
    nonisolated private static func checkRecipeEffect(_ file: URL) async throws {
        let values = try samples(file)
        // Measured 4.2e-7 to 2.6e-6 for the whip's effect over this window
        // across runs; the replaced renders must stay under 1e-7.
        #expect(energy(values, start: 1.5, duration: 0.6) > 2e-7)
    }

    @Test("A durable take cannot restore audio for edited text")
    func cachedTakeMustMatchText() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let source = DubTakeSource(videoID: videoID, transcriptionKey: "fixture", rowStart: 0, rowEnd: 1,
            language: "en", text: "First")
        let settings = ElevenLabsSettings()
        let take = DubTake(id: "first-take", source: source, speakerKey: "host", text: "First",
            voice: "elevenlabs:fixture", model: settings.model, settingsHash: DubTake.settingsHash(settings),
            audioFile: "first-take.caf", alignment: nil, edited: false)
        try await temp.database.upsertDubTake(take)
        let name = DubTake.digest([take.id, take.text, "", "0.0", "1.0", "full"]) + ".caf"
        let file = temp.directory.url.appendingPathComponent(name)
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:a", "pcm_f32le", file.path], timeout: 60)
        var line = DubLine(clipUID: UUID(), speakerKey: "host", voice: take.voice, text: "First",
            sourceStart: 0, sourceEnd: 1, start: 0, duration: 1, audio: name, takeSource: source, takeID: take.id)
        let synth = DubSynthesizer(directory: temp.directory.url)
        let restored = try await synth.restoringAudio(lines: [line], database: temp.database, allowSynthesis: false)
        #expect(restored.first?.audio == name)
        // A line's own existing file is the document's pairing and is used as
        // it is (fifth review). The durable row is consulted only when the file
        // is gone, and then it must match the line's text.
        line.text = "Second"
        try FileManager.default.removeItem(at: file)
        do {
            _ = try await synth.restoringAudio(lines: [line], database: temp.database, allowSynthesis: false)
            Issue.record("The First row must not restore audio for Second's text")
        } catch {
            #expect(error.userMessage.contains("Prepare the dub again to hear it live"))
        }
    }

    @Test("An exact window after the only line keeps original speech silent", arguments: [false, true])
    func emptySpeechWindowIsSilent(bumper: Bool) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let source = folder.appendingPathComponent("late-original.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=black:s=320x180:r=30:d=4",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=4",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path], timeout: 60)
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 4)
        clip.videoFile = source.path; clip.wide = false; clip.captions = "none"
        clip.transIn = "cut"; clip.transOut = "cut"
        var document = Fixtures.timelineDocument(clips: [clip])
        if bumper {
            var extra = clip; extra.uid = UUID(); extra.bumper = true
            extra.startTime = 4; extra.duration = 1; extra.transIn = "fade"
            document.videoTrack.append(extra)
        }
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 320, customHeight: 180)
        document.dub = DubSettings(language: "en", replaceOriginal: true)
        document.dubLines = [DubLine(clipUID: clip.uid, speakerKey: "host", voice: "must-not-synthesize", text: "Early",
            sourceStart: 0, sourceEnd: 0.5, start: 0, duration: 0.5, audio: "missing-outside-window.caf")]
        let window = MultitrackRenderer.windowed(document, from: 2, to: 5)
        #expect(window.dubLines?.isEmpty == true)
        let result = try await StayRenderFixture.renderer(folder).render(document: window, scenes: [],
            profile: Fixtures.brand(), database: temp.database, preview: true,
            dubState: DubRenderWindow.state(document: document), emit: { _ in })
        defer { try? FileManager.default.removeItem(at: result.url) }
        let decoded = try await decode(result.url, in: folder)
        try await Self.checkEmptySpeechWindow(decoded, bumper: bumper)
        if bumper {
            let overlaps = RenderEngine.frameCrossfadeOverlaps(durations: [2, 1], transitions: ["fade"],
                transitionDuration: (Fixtures.brand().editing ?? ProfileEditingDefaults(seedingFrom: SettingsStore.loadSettings())).transitions.xfadeDuration)
            let expected = 2 - (overlaps[0] ?? 0)
            let clock = try #require(result.clock)
            #expect(abs(clock.map(2) - expected) < 1e-9)
        }
    }

    @concurrent
    nonisolated private static func checkEmptySpeechWindow(_ file: URL, bumper: Bool) async throws {
        let values = try samples(file)
        #expect(energy(values, start: 0.25, duration: 1) < 1e-7)
        if bumper { #expect(energy(values, start: 2.3, duration: 0.2) > 0.0001) }
    }

    @Test("A dub onset inside a speed-ramp bridge follows its pictured event, including bumper runs and boundaries",
          arguments: ["none", "elsewhere", "boundary"])
    func speedRampOnset(bumper: String) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let source = folder.appendingPathComponent("bridge-event.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=black:s=320x180:r=30:d=4",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=4",
            "-vf", "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='between(t,1.8,1.9)'",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path], timeout: 60)
        let voice = folder.appendingPathComponent("onset.caf")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=0.15",
            "-c:a", "pcm_f32le", voice.path], timeout: 60)
        var head = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2)
        head.videoFile = source.path; head.wide = false; head.captions = "none"
        head.transIn = "cut"; head.transOut = "cut"
        var tail = head
        tail.uid = UUID(); tail.sourceStart = 2; tail.startTime = 2; tail.transIn = "speed_ramp"
        var document = Fixtures.timelineDocument(clips: [head, tail])
        if bumper == "elsewhere" {
            var extra = tail
            extra.uid = UUID(); extra.startTime = 4; extra.duration = 1
            extra.bumper = true; extra.transIn = "cut"; extra.transOut = "cut"
            document.videoTrack.append(extra)
        } else if bumper == "boundary" {
            document.videoTrack[1].bumper = true
        }
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 320, customHeight: 180)
        document.dub = DubSettings(language: "en", replaceOriginal: true)
        document.dubLines = [DubLine(clipUID: head.uid, speakerKey: "host", voice: "fixture", text: "Event",
            sourceStart: 1.8, sourceEnd: 1.95, start: 1.8, duration: 0.15, audio: voice.lastPathComponent)]
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: false,
            dubSynthesizer: DubSynthesizer(directory: folder))
        var transitions = TransitionSettings(); transitions.sfxEnabled = false
        let result = try await RenderContext.$transitions.withValue(transitions) {
            try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        let frames = folder.appendingPathComponent("event.gray")
        try await FFmpeg.run(["-y", "-i", result.url.path, "-an", "-vf", "fps=30,scale=1:1",
            "-pix_fmt", "gray", "-f", "rawvideo", frames.path], timeout: 60)
        let audio = try await decode(result.url, in: folder)
        try await Self.checkOnset(frames: frames, audio: audio)
    }

    @concurrent
    nonisolated private static func checkOnset(frames: URL, audio: URL) async throws {
        let pixels = [UInt8](try Data(contentsOf: frames))
        let picture = try #require(pixels.firstIndex { $0 > 180 })
        let values = try samples(audio)
        let sound = try #require(stride(from: 0, to: 3.0, by: 0.005).first {
            energy(values, start: $0, duration: 0.005) > 0.001
        })
        #expect(abs(sound - Double(picture) / 30) <= 1.0 / 30)
    }

    @Test("Replace original retains the bumper soundtrack, ducked under an underway voice")
    func replacementPreservesBumperAudio() async throws {
        let temp = try TempDirectory()
        let source = temp.url.appendingPathComponent("bed.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=black:s=320x180:r=30:d=3",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=3",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path], timeout: 60)
        let track = temp.url.appendingPathComponent("silent-voice.caf")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=3",
            "-c:a", "pcm_f32le", track.path], timeout: 60)
        let line = DubLine(clipUID: UUID(), speakerKey: "host", voice: "fixture", text: "Underway",
            sourceStart: 0, sourceEnd: 2, start: 0.5, duration: 2)
        let output = temp.url.appendingPathComponent("dubbed.mp4")
        try await DubMixer.overlay(video: source, track: track, lines: [line],
            settings: DubSettings(language: "en", originalLevel: 0.2, replaceOriginal: true),
            output: output, bumpers: [1..<2])
        let decoded = try await decode(output, in: temp.url)
        try await Self.checkBumperEnergy(decoded)
    }

    @concurrent
    nonisolated private static func checkBumperEnergy(_ url: URL) async throws {
        let values = try samples(url)
        #expect(energy(values, start: 0.6, duration: 0.2) < 1e-7)
        #expect(energy(values, start: 1.3, duration: 0.2) > 0.0001)
        #expect(energy(values, start: 2.3, duration: 0.2) < 1e-7)
    }

    @Test("Live restoration never synthesizes a missing take")
    func liveRestoreRequiresPreparedAudio() async throws {
        let temp = try TempDirectory()
        let synth = DubSynthesizer(directory: temp.url)
        let line = DubLine(clipUID: UUID(), speakerKey: "host", voice: "must-not-synthesize", text: "Missing",
            sourceStart: 0, sourceEnd: 1, start: 0, duration: 1, audio: "missing.caf")
        do {
            _ = try await synth.restoringAudio(lines: [line], allowSynthesis: false)
            Issue.record("Missing Live audio must prevent playback")
        } catch {
            #expect(error.userMessage.contains("Prepare the dub again to hear it live"))
        }
    }

    @Test("Replacing footage before assembly removes its tone from both bumper crossfades, including cached segments")
    func replacementExcludesCrossfadeNeighbours() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let source = folder.appendingPathComponent("footage-tone.mp4")
        let bumperURL = folder.appendingPathComponent("bumper-tone.mp4")
        for (url, frequency) in [(source, 880), (bumperURL, 1760)] {
            try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=black:s=320x180:r=30:d=2",
                "-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=48000:duration=2",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", url.path], timeout: 60)
        }
        let voice = folder.appendingPathComponent("short-voice.caf")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=0.2",
            "-c:a", "pcm_f32le", voice.path], timeout: 60)
        var first = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2)
        first.videoFile = source.path; first.wide = false; first.captions = "none"
        first.transIn = "cut"; first.transOut = "cut"
        var bumper = first
        bumper.uid = UUID(); bumper.videoFile = bumperURL.path; bumper.startTime = 2; bumper.duration = 1
        bumper.bumper = true; bumper.transIn = "fade"; bumper.transOut = "fade"
        var last = first
        last.uid = UUID(); last.startTime = 3; last.transIn = "fade"
        var document = Fixtures.timelineDocument(clips: [first, bumper, last])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 320, customHeight: 180)
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: false,
            dubSynthesizer: DubSynthesizer(directory: folder))
        // Populate the ordinary segment keys first: dubbed footage must not
        // reuse these audible segments, while the bumper may reuse its key.
        let original = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: original.url) }
        document.dub = DubSettings(language: "en", originalLevel: 0.2, replaceOriginal: true)
        document.dubLines = [DubLine(clipUID: first.uid, speakerKey: "host", voice: "fixture", text: "Before bumper",
            sourceStart: 0, sourceEnd: 0.2, start: 0, duration: 0.2, audio: voice.lastPathComponent)]
        var transitions = TransitionSettings(); transitions.xfadeDuration = 0.35; transitions.sfxEnabled = false
        let rendered = try await RenderContext.$transitions.withValue(transitions) {
            try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: rendered.url) }
        let clock = try #require(rendered.clock)
        let decoded = try await decode(rendered.url, in: folder)
        try await Self.checkCrossfadeTones(decoded, incoming: clock.map(2), outgoing: clock.map(3))
    }

    @concurrent
    nonisolated private static func checkCrossfadeTones(_ url: URL, incoming: Double, outgoing: Double) async throws {
        let values = try samples(url)
        func toneEnergy(at start: Double, frequency: Double) -> Double {
            let lower = Int(start * 48000), count = 4800
            guard lower >= 0, lower + count <= values.count else { return .infinity }
            var real = 0.0, imaginary = 0.0
            for index in 0..<count {
                let phase = 2 * Double.pi * frequency * Double(index) / 48000
                real += values[lower + index] * cos(phase)
                imaginary += values[lower + index] * sin(phase)
            }
            return 2 * (real * real + imaginary * imaginary) / Double(count * count)
        }
        // Interior of each 11-frame fade, and the bumper-only part between.
        for time in [incoming + 0.1, incoming + 0.45, outgoing + 0.1] {
            #expect(toneEnergy(at: time, frequency: 880) < 1e-6)
            #expect(toneEnergy(at: time, frequency: 1760) > 1e-5)
        }
        #expect(energy(values, start: 0.7, duration: 0.2) < 1e-7)
        #expect(energy(values, start: outgoing + 0.8, duration: 0.2) < 1e-7)
    }

    @Test("Freeze is silent and resumes the same decoded speech samples", arguments: [1.0, 1.1])
    func shiftedAudio(stretch: Double) async throws {
        let temp = try TempDirectory()
        let source = temp.url.appendingPathComponent("speech.caf")
        // Changing amplitude/frequency makes restarting or skipping speech detectable.
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i",
            "aevalsrc=0.2*sin(2*PI*(220*t+55*t*t))*(0.5+0.1*t):s=48000:d=4.4",
            "-c:a", "pcm_f32le", source.path], timeout: 60)
        var line = DubLine(clipUID: UUID(), speakerKey: "host", voice: "fixture", text: "Speech",
            sourceStart: 0, sourceEnd: 4, start: 0.5, duration: 4, stretch: stretch, audio: source.lastPathComponent)
        let plain = temp.url.appendingPathComponent("plain.caf")
        try await DubMixer.buildTrack(lines: [line], duration: 7, output: plain, directory: temp.url)
        let freezes = [1.5..<2.75, 4.25..<4.75]
        let paused = temp.url.appendingPathComponent("paused.caf")
        try await DubMixer.buildTrack(lines: [line], duration: 7, output: paused, directory: temp.url, freezes: freezes)
        let reference = try await decode(plain, in: temp.url)
        let candidate = try await decode(paused, in: temp.url)
        try await Self.compare(reference, candidate)
        // A window starting in the first freeze must not restart the voice.
        line.start -= 2
        let window = temp.url.appendingPathComponent("window.caf")
        try await DubMixer.buildTrack(lines: [line], duration: 4, output: window, directory: temp.url,
            freezes: freezes.map { ($0.lowerBound - 2)..<($0.upperBound - 2) })
        let excerpt = try await decode(window, in: temp.url)
        try await Self.compareWindow(candidate, excerpt)
    }

    private func decode(_ input: URL, in directory: URL) async throws -> URL {
        let result = directory.appendingPathComponent(UUID().uuidString + ".f32")
        try await FFmpeg.run(["-y", "-i", input.path, "-ac", "1", "-ar", "48000", "-f", "f32le", result.path],
                             timeout: 60, mediaResource: .decoding)
        return result
    }

    @concurrent
    nonisolated private static func compare(_ reference: URL, _ candidate: URL) async throws {
        let a = try samples(reference), b = try samples(candidate)
        for (start, end) in [(1.6, 2.65), (4.35, 4.65)] {
            #expect(energy(b, start: start, duration: end - start) < 1e-9)
        }
        for (start, shift) in [(0.7, 0.0), (1.7, 1.25), (3.2, 1.75)] {
            let lower = Int(start * 48000), offset = Int(shift * 48000), count = 12000
            try #require(lower + offset + count < b.count && lower + count < a.count)
            let error = (0..<count).reduce(0.0) { $0 + pow(a[lower + $1] - b[lower + offset + $1], 2) } / Double(count)
            #expect(energy(a, start: start, duration: 0.25) > 0.001)
            #expect(error < 1e-8)
        }
    }

    @concurrent
    nonisolated private static func compareWindow(_ full: URL, _ window: URL) async throws {
        let a = try samples(full), b = try samples(window)
        #expect(energy(b, start: 0.1, duration: 0.5) < 1e-9)
        let count = 12000, lower = 48000, offset = 96000
        try #require(lower + offset + count < a.count && lower + count < b.count)
        let error = (0..<count).reduce(0.0) { $0 + pow(a[lower + offset + $1] - b[lower + $1], 2) } / Double(count)
        #expect(error < 1e-8)
    }

    nonisolated private static func samples(_ url: URL) throws -> [Double] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: data.count, by: 4).map {
                Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))))
            }
        }
    }

    nonisolated private static func energy(_ values: [Double], start: Double, duration: Double) -> Double {
        let lower = Int(start * 48000), upper = min(values.count, Int((start + duration) * 48000))
        guard upper > lower else { return .infinity }
        return values[lower..<upper].reduce(0) { $0 + $1 * $1 } / Double(upper - lower)
    }
}

extension DubPauseRenderTests {
    @Test("Inserted holds freeze video and dub on the same assembled clock",
           arguments: ["cut", "fade", "bumper", "recipe", "two-recipes"])
    func documentRender(join: String) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let source = folder.appendingPathComponent("picture.mp4")
        // Every frame changes by one luma level. Only a hold repeats frames;
        // this makes its boundaries observable without trusting the clock.
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i",
            "nullsrc=s=320x180:r=30:d=7,geq=lum='20+30*T':cb=128:cr=128",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=7",
            "-c:v", "libx264", "-crf", "10", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path], timeout: 60)
        let speech = folder.appendingPathComponent("voice.caf")
        // 120 ms amplitude symbols expose a consumed-offset error even when
        // both renders place the silence correctly. A smooth chirp's slowly
        // varying energy could hide the former 85 ms bumper error.
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i",
            "aevalsrc='0.2*sin(2*PI*(220*t+55*t*t))*(0.4+0.08*mod(3*floor(t/0.12)+floor(t/0.84),7))':s=48000:d=6",
            "-c:a", "pcm_f32le", speech.path], timeout: 60)
        var head = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2)
        head.videoFile = source.path; head.wide = false; head.captions = "none"
        head.transIn = "cut"; head.transOut = "cut"
        var tail = Fixtures.timelineClip(sceneID: nil, sourceStart: 2, duration: 5, startTime: 2)
        tail.videoFile = source.path; tail.wide = false; tail.captions = "none"
        tail.transIn = join == "fade" ? "fade" : (join.contains("recipe") ? "whip_left" : "cut")
        tail.transOut = "cut"
        var plain = Fixtures.timelineDocument(clips: [head, tail])
        if join == "two-recipes" {
            plain.videoTrack[0].duration = 1
            var middle = head
            middle.uid = UUID(); middle.startTime = 1; middle.sourceStart = 1; middle.duration = 1
            middle.transIn = "whip_left"
            plain.videoTrack.insert(middle, at: 1)
        }
        plain.renderSettings = RenderSettings(preset: .custom, customWidth: 320, customHeight: 180)
        plain.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 7)]
        plain.dub = DubSettings(language: "en-US", replaceOriginal: true)
        plain.dubLines = [DubLine(clipUID: head.uid, speakerKey: "host", voice: "fixture", text: "Speech",
            sourceStart: 0.25, sourceEnd: 6.25, start: 0.25, duration: 6, audio: speech.lastPathComponent)]
        let inserted = try #require(TimelinePauseRules.insert([.init(time: 4, duration: 1, owner: tail.uid)],
            into: plain, resolve: { $0 }))
        var paused = inserted.document
        if join == "bumper" {
            // The bumper and both of its crossfades lie between speech start
            // and the pause. Insertion changes the hold, not the dub line.
            let bumper = try #require(BumperAsset(path: source.path, displayName: "Fixture", duration: 1).clip(at: 2))
            for index in 0..<2 {
                var document = index == 0 ? plain : paused
                BumperPlanner.insertGap(in: &document, at: 2, duration: 1)
                var clip = bumper; clip.bumperMode = .pause
                clip.transIn = "fade"; clip.transOut = "fade"
                for position in document.videoTrack.indices where document.videoTrack[position].startTime == 3 {
                    document.videoTrack[position].transIn = "fade"
                }
                document.videoTrack.append(clip)
                if index == 0 { plain = document } else { paused = document }
            }
        }
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, framingCacheEnabled: false,
            dubSynthesizer: DubSynthesizer(directory: folder))
        let reference = try await renderer.render(document: plain, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: reference.url) }
        let candidate = try await renderer.render(document: paused, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: candidate.url) }
        let clock = try #require(candidate.clock)
        if join == "fade" || join == "bumper" { #expect(!clock.isIdentity) }
        let freeze = try #require(DubFreezes.intervals(in: paused, clock: clock).first)
        let frames = folder.appendingPathComponent("frames.gray")
        try await FFmpeg.run(["-y", "-i", candidate.url.path, "-an", "-vf", "fps=30,scale=32:18",
            "-pix_fmt", "gray", "-f", "rawvideo", frames.path], timeout: 60, mediaResource: .decoding)
        let a = try await decode(reference.url, in: folder)
        let b = try await decode(candidate.url, in: folder)
        try await Self.checkPictureAndAudio(frames: frames, plain: a, paused: b, freeze: freeze,
            slack: 1.0 / 30 + 1e-6)
        if join == "fade" || join == "bumper" {
            let timelineFreeze = try #require(DubFreezes.intervals(in: paused).first)
            for lower in [timelineFreeze.lowerBound + 0.5, timelineFreeze.lowerBound - 0.5] {
                var window = MultitrackRenderer.windowed(paused, from: lower, to: lower + 2)
                let planned = DubRenderWindow.clock(document: paused, window: window,
                    scenes: [], camera: "balanced", lower: lower)
                #expect(abs(planned.map(lower) - clock.map(lower)) < 1.0 / 44100)
                window.dubLines = DubRenderWindow.lines(paused, clock: planned, lower: lower, upper: lower + 2)
                let preview = try await renderer.render(document: window, scenes: [], profile: Fixtures.brand(),
                    database: temp.database, preview: true, emit: { _ in })
                defer { try? FileManager.default.removeItem(at: preview.url) }
                let decoded = try await decode(preview.url, in: folder)
                try await Self.compareEnergyWindow(full: b, window: decoded, offset: planned.map(lower))
            }
        }
        if join == "bumper" {
            // Both the unpaused export and a paused export's window that
            // omits its hold must retain the full document's bumper policy.
            let referenceClock = try #require(reference.clock)
            for (document, fullAudio, fullClock, lower, upper) in [
                (plain, a, referenceClock, 4.5, 6.5),
                (paused, b, clock, 1.0, 4.9)
            ] {
                var window = MultitrackRenderer.windowed(document, from: lower, to: upper)
                #expect(!window.videoTrack.contains { $0.hold == true })
                let planned = DubRenderWindow.clock(document: document, window: window,
                    scenes: [], camera: "balanced", lower: lower)
                #expect(abs(planned.map(lower) - fullClock.map(lower)) < 1.0 / 44100)
                window.dubLines = DubRenderWindow.lines(document, clock: planned, lower: lower, upper: upper)
                let preview = try await renderer.render(document: window, scenes: [], profile: Fixtures.brand(),
                    database: temp.database, preview: true, emit: { _ in })
                defer { try? FileManager.default.removeItem(at: preview.url) }
                let decoded = try await decode(preview.url, in: folder)
                try await Self.compareEnergyWindow(full: fullAudio, window: decoded, offset: planned.map(lower))
            }
        }
    }

    @concurrent
    nonisolated private static func compareEnergyWindow(full: URL, window: URL, offset: Double) async throws {
        let a = try samples(full), b = try samples(window)
        for time in stride(from: 0.1, through: 1.5, by: 0.1) {
            let expected = energy(a, start: offset + time, duration: 0.04)
            let actual = energy(b, start: time, duration: 0.04)
            if expected < 1e-7 { #expect(actual < 1e-6) }
            else { #expect(abs(actual / expected - 1) < 0.15) }
        }
    }

    @Test("Window inside a freeze retains a short line after a removed half-second join", arguments: [3.8, 6.0])
    func joinedWindow(duration: Double) async throws {
        let temp = try TempDirectory()
        let speech = temp.url.appendingPathComponent("window-voice.caf")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i",
            "aevalsrc=0.2*sin(2*PI*(220*t+55*t*t))*(0.5+0.05*t):s=48000:d=\(duration)",
            "-c:a", "pcm_f32le", speech.path], timeout: 60)
        var hold = Fixtures.timelineClip(sceneID: nil, duration: 1, startTime: 4)
        hold.hold = true; hold.pauseGroup = hold.uid
        var document = Fixtures.timelineDocument(clips: [hold])
        document.dubLines = [DubLine(clipUID: hold.uid, speakerKey: "host", voice: "fixture", text: "Speech",
            sourceStart: 0, sourceEnd: duration, start: 0, duration: duration, audio: speech.lastPathComponent)]
        let clock = RenderClock(segmentStarts: [0, 2, 4, 5], overlaps: [0: 0.5])
        let full = temp.url.appendingPathComponent("full.caf"), window = temp.url.appendingPathComponent("window.caf")
        try await DubMixer.buildTrack(lines: clock.map(document.dubLines ?? []), duration: 8,
            output: full, directory: temp.url, freezes: DubFreezes.intervals(in: document, clock: clock))
        let lines = try #require(DubRenderWindow.lines(document, clock: clock, lower: 4.5, upper: 7))
        #expect(lines.count == 1)
        try await DubMixer.buildTrack(lines: lines, duration: 2, output: window,
            directory: temp.url, freezes: [0..<0.5])
        let a = try await decode(full, in: temp.url), b = try await decode(window, in: temp.url)
        try await Self.compareEnergyWindow(full: a, window: b, offset: 4)
    }

    @concurrent
    nonisolated private static func checkPictureAndAudio(frames: URL, plain: URL, paused: URL,
                                                        freeze: Range<Double>, slack: Double) async throws {
        let pixels = [UInt8](try Data(contentsOf: frames)), frameSize = 32 * 18
        let means = stride(from: 0, through: pixels.count - frameSize, by: frameSize).map { offset in
            pixels[offset..<(offset + frameSize)].reduce(0.0) { $0 + Double($1) } / Double(frameSize)
        }
        // Find the longest run of repeated frames, independently of hold time.
        var best = 0..<0, run = 0
        for index in 1..<means.count {
            if abs(means[index] - means[index - 1]) >= 0.2 { run = index }
            if index + 1 - run > best.count { best = run..<(index + 1) }
        }
        try #require(best.count > 20)
        let frozenStart = Double(best.lowerBound) / 30
        // The first resumed frame can equal the hold's frame, hence one-frame tolerance.
        let frozenEnd = Double(best.upperBound) / 30
        #expect(abs(frozenStart - freeze.lowerBound) <= 1.0 / 30 + 1e-6)
        #expect(abs(frozenEnd - freeze.upperBound) <= slack)
        let audio = try samples(paused), reference = try samples(plain)
        var silent = 0..<0, start: Int?
        // Ignore intentional silence before/after the line. Within speech,
        // the longest silent run must be the hold, found in 10 ms windows.
        for index in 75..<min(audio.count / 480, 650) {
            let quiet = energy(audio, start: Double(index) / 100, duration: 0.01) < 1e-6
            if quiet {
                if start == nil { start = index }
                if let start, index + 1 - start > silent.count { silent = start..<(index + 1) }
            } else { start = nil }
        }
        try #require(silent.count > 80)
        #expect(abs(Double(silent.lowerBound) / 100 - frozenStart) <= 1.0 / 30 + 1e-6)
        // Silence is found in 10 ms windows, so its end is known to 10 ms.
        #expect(abs(Double(silent.upperBound) / 100 - frozenEnd) <= slack + 0.01)
        // AAC changes sample values/priming. Compare decoded energy in short
        // shifted windows; the lossless mixer test above checks sample equality.
        let shift = freeze.upperBound - freeze.lowerBound
        for offset in [0.15, 0.35, 0.55] {
            let time = freeze.upperBound + offset
            let expected = energy(reference, start: time - shift, duration: 0.1)
            let actual = energy(audio, start: time, duration: 0.1)
            #expect(expected > 0.001 && abs(actual / expected - 1) < 0.12)
        }
    }
}
