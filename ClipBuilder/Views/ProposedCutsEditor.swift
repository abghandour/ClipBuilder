import SwiftUI
import AVKit

/// Shared per-cut review body: playback, include/reject, trims, and Space / I / O.
struct ProposedCutsEditor: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var originalPlan: WizardPlan
    let sceneMap: [Int64: SceneRecord]
    let onChange: (WizardPlan) -> Void

    @State private var plan: WizardPlan
    @State private var rejected: Set<Int>
    @State private var selectedIndex: Int?
    @State private var playback = PodcastHighlightTrimPlayback()
    @State private var loadedURL: URL?
    @State private var draft: (start: Double, end: Double)?
    @State private var window = ProposedCutTrim.Window(start: 0, span: 30)

    init(plan: WizardPlan, sceneMap: [Int64: SceneRecord], onChange: @escaping (WizardPlan) -> Void) {
        _originalPlan = State(initialValue: plan)
        self.sceneMap = sceneMap
        self.onChange = onChange
        var plan = plan
        for index in plan.clips.indices {
            let clip = plan.clips[index]
            guard let scene = sceneMap[clip.sceneID] else { continue }
            let range = ProposedCutTrim.clamp(start: clip.start, end: clip.end,
                                             scene: scene.startTime...scene.endTime)
            plan.clips[index].start = range.lowerBound
            plan.clips[index].end = range.upperBound
        }
        _plan = State(initialValue: plan)
        _rejected = State(initialValue: [])
        _selectedIndex = State(initialValue: plan.clips.indices.first {
            sceneMap[plan.clips[$0].sceneID] != nil
        } ?? plan.clips.indices.first)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedIndex) {
                ForEach(plan.clips.indices, id: \.self) { index in
                    cutRow(index).tag(index)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 320)
            Divider()
            trimSurface
                .padding(Theme.spaceM)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selectCurrentCut() }
        .onChange(of: selectedIndex) { _, _ in selectCurrentCut() }
        .onChange(of: selectedURL) { _, _ in selectCurrentCut() }
        .onChange(of: playback.player != nil) { _, ready in
            // A same-file selection can change while the initial load is pending.
            if ready, let range = selectedRange {
                playback.setRange(range)
                playback.seek(to: range.lowerBound)
            }
        }
        .onDisappear {
            playback.tearDown()
            loadedURL = nil
        }
        .background {
            PodcastHighlightScreeningKeys(isActive: { false }, rate: { _ in }, other: handleKey)
                .frame(width: 0, height: 0)
        }
    }

    private var selectedScene: SceneRecord? {
        guard let selectedIndex else { return nil }
        return sceneMap[plan.clips[selectedIndex].sceneID]
    }

    private var selectedURL: URL? { selectedScene?.videoURL }

    private var selectedRange: ClosedRange<Double>? {
        guard let selectedIndex, let scene = selectedScene else { return nil }
        let clip = plan.clips[selectedIndex]
        return ProposedCutTrim.clamp(start: clip.start, end: clip.end, scene: scene.startTime...scene.endTime)
    }

    private var canTrim: Bool {
        guard isEnabled, let selectedIndex, selectedScene != nil else { return false }
        return !rejected.contains(selectedIndex)
    }

    private func cutRow(_ index: Int) -> some View {
        let clip = plan.clips[index]
        let scene = sceneMap[clip.sceneID]
        let range = ProposedCutTrim.range(start: clip.start, end: clip.end)
        return VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceS) {
                if let scene {
                    VideoThumbnail(url: scene.videoURL, time: ProposedCutTrim.midpoint(range), cornerRadius: 4)
                        .frame(width: 64, height: 40)
                        .accessibilityHidden(true)
                }
                Text("Cut \(index + 1)").bold()
                Spacer(minLength: 0)
                Toggle("Include", isOn: Binding(
                    get: { scene != nil && !rejected.contains(index) },
                    set: { include in
                        if include { rejected.remove(index) } else { rejected.insert(index) }
                        if selectedIndex == index { draft = nil }
                        onChange(approvedPlan())
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(scene == nil)
                    .fixedSize()
            }
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            Text(scene?.videoFilename ?? "Missing source")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(clip.start.timecode)–\(clip.end.timecode) · \(ProposedCutTrim.duration(range), format: .number.precision(.fractionLength(1)))s")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            Text(clip.reason ?? "Planner did not provide a reason.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, Theme.spaceS)
    }

    @ViewBuilder
    private var trimSurface: some View {
        if let scene = selectedScene, !FileManager.default.fileExists(atPath: scene.videoPath) {
            ContentUnavailableView("Video not available", systemImage: "video.slash",
                description: Text("Make this source available on this Mac to preview and trim it."))
        } else if let index = selectedIndex, let scene = selectedScene, let range = selectedRange {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                // The list truncates the planner's reason; here it reads in full.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cut \(index + 1) · \(scene.videoFilename)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if let reason = plan.clips[index].reason {
                        Text(reason)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                PlayerView(player: playback.player, controlsStyle: .none)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
                    .overlay {
                        if playback.player == nil { ProgressView().controlSize(.small) }
                    }
                filmstrip(scene: scene, range: range)
                    .id(index)
                    .disabled(!canTrim)
                trimControls(index: index, range: range)
                Text("Drag the handles · I / O set the start / end at the playhead")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            }
        } else if selectedIndex != nil {
            ContentUnavailableView("Missing source", systemImage: "video.slash",
                                   description: Text("The source scene for this cut is unavailable. It cannot be previewed or included."))
        } else {
            ContentUnavailableView("Select a cut", systemImage: "film",
                                   description: Text("Choose a proposed cut to preview and trim it."))
        }
    }

    private func filmstrip(scene: SceneRecord, range: ClosedRange<Double>) -> some View {
        let editStart = draft?.start ?? range.lowerBound
        let editEnd = draft?.end ?? range.upperBound
        return VideoTrimSlider(url: scene.videoURL, duration: window.span,
                               start: Binding(get: { editStart }, set: {
                                   guard canTrim else { return }
                                   draft = (start: $0, end: draft?.end ?? range.upperBound)
                               }),
                               end: Binding(get: { editEnd }, set: {
                                   guard canTrim else { return }
                                   draft = (start: draft?.start ?? range.lowerBound, end: $0)
                               }),
                               timeOffset: window.start, rulerInterval: window.rulerInterval,
                               minimumSpan: window.minimumSpan,
                               showsTimes: false, stripHeight: 48,
                               onScrub: { if canTrim { playback.scrub(to: $0) } }, onDragEnded: commitDraft)
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    if let x = window.playheadX(at: playback.time, width: Double(proxy.size.width)) {
                        Rectangle().fill(.white)
                            .frame(width: 2, height: 48)
                            .offset(x: CGFloat(x))
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .help("Drag a handle and release near the edge to see more of this scene")
    }

    private func trimControls(index: Int, range: ClosedRange<Double>) -> some View {
        let proposal = originalPlan.clips[index]
        let changed = ProposedCutTrim.differs(range, proposedStart: proposal.start, proposedEnd: proposal.end)
        let start = draft?.start ?? range.lowerBound
        let end = draft?.end ?? range.upperBound
        return HStack(spacing: Theme.spaceS) {
            Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                playback.togglePlay()
            }
            .labelStyle(.iconOnly)
            .disabled(playback.player == nil)
            .help(playback.isPlaying ? "Pause (Space)" : "Play the cut (Space)")
            PlaybackSpeedSlider(playback: playback)
            Text("\(ProposedCutTrim.timecode(start))–\(ProposedCutTrim.timecode(end)) · \(ProposedCutTrim.duration(ProposedCutTrim.range(start: start, end: end)), format: .number.precision(.fractionLength(1)))s")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
            if changed {
                Text("proposed \(proposal.start.timecode)–\(proposal.end.timecode)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Reset to Proposed") { commit(start: proposal.start, end: proposal.end) }
                .controlSize(.small)
                .disabled(!canTrim || !changed)
                .fixedSize()
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func selectCurrentCut() {
        draft = nil
        playback.pause()
        guard let scene = selectedScene, let range = selectedRange,
              FileManager.default.fileExists(atPath: scene.videoPath) else {
            playback.tearDown()
            loadedURL = nil
            return
        }
        window = ProposedCutTrim.window(for: range, scene: scene.startTime...scene.endTime)
        if loadedURL != scene.videoURL {
            playback.tearDown()
            loadedURL = scene.videoURL
            playback.load(url: scene.videoURL, range: range, autoplay: false)
        } else if playback.player != nil {
            playback.setRange(range)
            playback.seek(to: range.lowerBound)
        }
    }

    private func commitDraft() {
        guard let draft else { return }
        self.draft = nil
        commit(start: draft.start, end: draft.end)
    }

    private func commit(start: Double, end: Double) {
        guard canTrim, let index = selectedIndex, let scene = selectedScene else { return }
        draft = nil
        let bounds = scene.startTime...scene.endTime
        let range = ProposedCutTrim.clamp(start: start, end: end, scene: bounds)
        plan.clips[index].start = range.lowerBound
        plan.clips[index].end = range.upperBound
        onChange(approvedPlan())
        if playback.player != nil { playback.setRange(range) }
        if window.needsRecentering(range) { window = ProposedCutTrim.window(for: range, scene: bounds) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isEnabled, let range = selectedRange, let scene = selectedScene, playback.player != nil else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ":
            playback.togglePlay()
        case "i", "o":
            guard canTrim else { return false }
            let bounds = scene.startTime...scene.endTime
            let updated = event.charactersIgnoringModifiers?.lowercased() == "i"
                ? ProposedCutTrim.settingStart(at: playback.time, in: range, scene: bounds)
                : ProposedCutTrim.settingEnd(at: playback.time, in: range, scene: bounds)
            commit(start: updated.lowerBound, end: updated.upperBound)
        default:
            return false
        }
        return true
    }

    private func approvedPlan() -> WizardPlan {
        var approved = plan
        approved.clips = plan.clips.enumerated().compactMap { index, clip in
            guard !rejected.contains(index), let scene = sceneMap[clip.sceneID] else { return nil }
            var clip = clip
            clip.start = min(scene.endTime, max(scene.startTime, clip.start))
            clip.end = min(scene.endTime, max(clip.start + 0.5, clip.end))
            return clip.end > clip.start ? clip : nil
        }
        approved.transitions = Array(plan.transitions.prefix(max(0, approved.clips.count - 1)))
        while approved.transitions.count < max(0, approved.clips.count - 1) {
            approved.transitions.append("cut")
        }
        return approved
    }
}
