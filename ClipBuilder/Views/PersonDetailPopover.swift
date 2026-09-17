import SwiftUI

/// What clicking a person's avatar opens: a larger portrait, who they are,
/// where they appear in the video at hand, and every video and scene in the
/// library they are known from. Presented as a popover anchored to the
/// avatar; anything that needs a sheet (playing a scene) or a selection
/// change is handed back to the presenting screen through the callbacks,
/// because a sheet inside a split-view child crashes AppKit's layout.
struct PersonDetailPopover: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let person: PersonRecord
    /// The video the avatar was clicked in, for the "In this video" section.
    var video: VideoRecord?
    /// This video's roster entry for the person: its portrait is the face
    /// the clicked avatar showed, so the popover shows the same one.
    var rosterEntry: VideoPersonRecord?
    /// Moves the presenting screen's player to a moment of `video`.
    var onSeek: ((Double) -> Void)?
    /// Selects another of the person's videos in the presenting screen.
    var onSelectVideo: ((VideoRecord) -> Void)?
    /// Plays a scene (the presenter owns the sheet).
    var onPreviewScene: ((SceneRecord) -> Void)?

    @State private var videos: [VideoRecord] = []
    @State private var ranges: [ScriptTimeRange] = []
    @State private var speakingSeconds: Double = 0
    @State private var loaded = false

    /// Every usable scene tagged with the person, by video then time.
    private var scenes: [SceneRecord] {
        store.scenes
            .filter { !$0.ignored && $0.tags.contains(person.tag) }
            .sorted { ($0.videoID, $0.startTime) < ($1.videoID, $1.startTime) }
    }

    private var sceneCounts: [Int64: Int] {
        scenes.reduce(into: [:]) { $0[$1.videoID, default: 0] += 1 }
    }

    private var onScreenSeconds: Double {
        ranges.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let video { inThisVideo(video) }
                    videosSection
                    scenesSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 380)
        .task(id: "\(person.id)|\(video?.id ?? -1)|\(store.scenesVersion)") {
            videos = await store.personVideos(person)
            if let video {
                ranges = await store.personRanges(videoID: video.id, key: person.key)
                speakingSeconds = await store.personSpeakingSeconds(videoID: video.id, key: person.key)
            }
            loaded = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let rosterEntry, let video, rosterEntry.portraitBox != nil {
                    VideoPersonAvatar(record: rosterEntry, videoURL: video.url, size: 112)
                } else {
                    PersonFaceAvatar(person: person, size: 112)
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(person.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if person.isUnnamed {
                    Text(person.keyName == nil ? "Not named yet — name them on the People screen"
                         : "Name read by the analyzer — confirm it on the People screen")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !person.descriptor.isEmpty {
                    Text(person.descriptor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Button("Open in People", systemImage: "person.crop.rectangle.stack") {
                    store.requestedPersonID = person.id
                    store.requestedSection = .people
                    dismiss()
                }
                .controlSize(.small)
                .padding(.top, 4)
                .help("Show this person on the People screen: rename them, pick their avatar, merge or hide them")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summaryLine: String {
        let videoCount = videos.count, sceneCount = scenes.count
        var parts = ["\(videoCount) video\(videoCount == 1 ? "" : "s")",
                     "\(sceneCount) scene\(sceneCount == 1 ? "" : "s")"]
        if person.hidden { parts.append("hidden") }
        return parts.joined(separator: " · ")
    }

    // MARK: - In this video

    @ViewBuilder
    private func inThisVideo(_ video: VideoRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("In this video")
            if ranges.isEmpty {
                Text(loaded ? "Seen in this video; the people pass did not note when." : "Loading…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(presenceLine(duration: video.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Each range is a jump: the inspector's player follows.
                FlowLayout(spacing: 4) {
                    ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
                        Button {
                            onSeek?(range.start)
                        } label: {
                            Text("\(range.start.timecode)–\(range.end.timecode)")
                                .font(.caption.monospacedDigit())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(onSeek == nil)
                        .help("Jump the preview to \(range.start.timecode)")
                    }
                }
            }
        }
    }

    private func presenceLine(duration: Double) -> String {
        var line = "On screen \(onScreenSeconds.timecode)"
        if duration > 0 {
            line += " (\(Int((onScreenSeconds / duration * 100).rounded()))%)"
        }
        if speakingSeconds > 0 { line += " · speaking \(speakingSeconds.timecode)" }
        return line
    }

    // MARK: - Videos

    private var videosSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Videos")
            if videos.isEmpty {
                Text(loaded ? "Not in any video of this project." : "Loading…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(videos) { entry in
                let current = entry.id == video?.id
                Button {
                    guard !current else { return }
                    onSelectVideo?(entry)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: current ? "checkmark.circle.fill" : "film")
                            .foregroundStyle(current ? Color.accentColor : .secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.filename)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(videoLine(entry))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(current || onSelectVideo == nil)
                .help(current ? "The video you are looking at" : "Show this video in Sources")
            }
        }
    }

    private func videoLine(_ entry: VideoRecord) -> String {
        var parts = [entry.duration.timecode]
        if let type = entry.type { parts.append(type.label) }
        let count = sceneCounts[entry.id] ?? 0
        parts.append(count == 0 ? "no scenes yet" : "\(count) scene\(count == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    // MARK: - Scenes

    private var scenesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Scenes")
            if scenes.isEmpty {
                Text("No scenes tagged with this person yet — analyze their videos with tag detection on.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(scenes) { scene in
                Button {
                    onPreviewScene?(scene)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        let poster = scene.posterFrame(videoType: store.videos.first { $0.id == scene.videoID }?.type)
                        VideoThumbnail(url: scene.videoURL, time: poster.time, cornerRadius: 4,
                                       window: poster.window)
                            .frame(width: 64, height: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(scene.startTime.timecode)–\(scene.endTime.timecode)")
                                .font(.callout.monospacedDigit())
                            Text(sceneLine(scene))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if scene.favorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                        DurationBadge(seconds: scene.duration)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onPreviewScene == nil)
                .help(scene.narrative ?? "Play this scene")
            }
        }
    }

    private func sceneLine(_ scene: SceneRecord) -> String {
        let tags = scene.tags.filter { !$0.hasPrefix("person:") && !$0.hasPrefix("vip:") && $0 != "auto-hidden" }
        if videos.count > 1 || scene.videoID != video?.id {
            return ([scene.videoFilename] + tags).joined(separator: " · ")
        }
        return tags.isEmpty ? scene.videoFilename : tags.joined(separator: " · ")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
