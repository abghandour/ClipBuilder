import SwiftUI

/// Shared framing controls for Express and the full wizard.
struct FramingRows: View {
    @Environment(AppStore.self) private var store
    @Binding var framing: Framing
    let type: VideoType
    var videoIDs: [Int64] = []
    /// Width over height of the output canvas; the locked focus frame starts at this shape.
    var canvasAspect: Double = 9.0 / 16
    /// The slider's value while it is being dragged; committed when the drag ends.
    @State private var zoomLive: Double?
    @State private var hasTurns = false
    /// Recorded feeds per selected recording, for the Shot row's caption.
    @State private var feedCounts: [Int] = []
    /// Everyone the selected recordings know, one entry per person key.
    @State private var roster: [(record: VideoPersonRecord, videoURL: URL)] = []

    /// The run's VIPs: the request's own choice, else the People tags.
    private var vipKeys: Set<String> {
        framing.vips.map(Set.init) ?? Set(roster.filter(\.record.isVIP).map(\.record.key))
    }
    private var hasVIP: Bool { !vipKeys.isEmpty }
    private var showsVIPPicker: Bool {
        (framing.subject == .centerStage && framing.people == .vips)
            || (framing.subject == .layout && framing.layout == FramingMenu.vipsLayout)
    }

    var body: some View {
        SettingsRow("Framing", detail: framing.subject.summary(type: type)) {
            Menu {
                ForEach(FramingMenu.allowed(type: type), id: \.self) { subject in
                    Button {
                        var value = framing
                        value.subject = subject
                        if subject != .original { value.lockAspect = nil }
                        framing = value
                    } label: {
                        Text(subject.label(type: type)).lineLimit(1).fixedSize()
                    }
                    .disabled(reason(subject) != nil)
                    .help(reason(subject) ?? subject.label(type: type))
                }
            } label: {
                Text(framing.subject.label(type: type)).lineLimit(1).fixedSize()
            }
            .accessibilityLabel("Framing")
        }
        if let reason = reason(framing.subject) {
            FormCaption(reason)
        } else if FramingMenu.allowed(type: type).contains(.speakerFocus), !hasTurns {
            FormCaption("Speaker focus needs speaker turns. Analyze speech first.")
        }
        if type == .fight, framing.subject == .vipFocus, !hasVIP {
            FormCaption("Following both fighters. Tag a fighter in People to follow one.")
        }
        if framing.subject == .centerStage {
            SettingsRow("Show", detail: framing.people == .vips
                ? "Only the tagged VIPs stay in the picture."
                : "Everybody detected stays in the picture.") {
                Picker("Show", selection: Binding(get: { framing.people ?? .everyone },
                                                  set: { framing.people = $0 == .everyone ? nil : $0 })) {
                    Text("Everyone").lineLimit(1).fixedSize().tag(Framing.People.everyone)
                    Text("VIPs only").lineLimit(1).fixedSize().tag(Framing.People.vips)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Show")
            }
            if framing.people == .vips, !hasVIP {
                FormCaption("No VIP yet: pick one below, or everyone stays in the picture.")
            }
        }
        if showsVIPPicker, !roster.isEmpty {
            vipRow
        }
        if framing.subject == .layout {
            SettingsRow("Layout") {
                Picker("Layout", selection: Binding(get: { framing.layout ?? defaultLayout }, set: { framing.layout = $0 })) {
                    if let name = framing.layout, !FramingMenu.virtualLayouts.contains(name),
                       !layouts.contains(where: { $0.name == name }) {
                        Text("\(name) (missing)").lineLimit(1).fixedSize().tag(name)
                    }
                    ForEach(FramingMenu.virtualLayouts, id: \.self) { name in
                        Text(name + " · " + (FramingMenu.virtualLayoutSummary(name) ?? "")).lineLimit(1).fixedSize().tag(name)
                    }
                    Divider()
                    ForEach(layouts) { layout in
                        Text(layout.name + " · " + (layout.areas.compactMap { $0.role?.label }.isEmpty
                            ? "By order" : layout.areas.compactMap { $0.role?.label }.joined(separator: " / ")))
                            .lineLimit(1).fixedSize().tag(layout.name)
                    }
                }
                .labelsHidden()
            }
            if framing.layout == FramingMenu.vipsLayout, !hasVIP {
                FormCaption("No VIP yet: pick one below, or the grid shows everyone.")
            }
            if showsVIPPicker, !roster.isEmpty {
                vipRow
            }
            if (framing.layout ?? defaultLayout) == "Screen + presenter" {
                sourceRow(.screen)
                sourceRow(.presenter)
            }
        }
        if framing.subject == .vipFocus || framing.subject == .speakerFocus {
            SettingsRow("Pull back") {
                Slider(value: $framing.pullBack, in: 0...1)
                    .accessibilityLabel("Pull back")
                Text(framing.pullBack, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().lineLimit(1).fixedSize()
            }
        }
        if framing.subject == .speakerFocus {
            SettingsRow("Shot", detail: framing.speakerShot?.summary
                ?? "Auto pairs one VIP with the talker, puts several VIPs beside the talker, else the talker full screen.") {
                Picker("Shot", selection: Binding(get: { framing.speakerShot }, set: { framing.speakerShot = $0 })) {
                    Text("Auto").lineLimit(1).fixedSize().tag(CropRecipe.Kind?.none)
                    ForEach(Framing.speakerShots, id: \.self) { kind in
                        Text(kind.name).lineLimit(1).fixedSize().tag(CropRecipe.Kind?.some(kind))
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Shot")
            }
            if let shot = framing.speakerShot,
               let reason = feedCounts.lazy.compactMap({ FramingPlanner.shotReason(shot, feeds: $0, hasVIP: hasVIP) }).first {
                FormCaption("\(reason) Auto is used there.")
            }
            SettingsRow("Moves") {
                Picker("Moves", selection: $framing.moves) {
                    Text("Smooth").lineLimit(1).fixedSize().tag(Framing.Moves.smooth)
                    Text("Cuts").lineLimit(1).fixedSize().tag(Framing.Moves.cuts)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Moves")
            }
        }
        SettingsRow("Fit") {
            Picker("Fit", selection: Binding(get: { framing.fit }, set: { fit in
                var value = framing
                value.fit = fit
                if fit == .fill { value.lockAspect = nil }
                framing = value
            })) {
                Text("Fill").lineLimit(1).fixedSize().tag(Framing.Fit.fill)
                Text("Blurred fill").lineLimit(1).fixedSize().tag(Framing.Fit.blurredFill)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Fit")
        }
        if framing.fit == .blurredFill {
            SettingsRow("Blur") {
                Slider(value: $framing.blur, in: 0...1).accessibilityLabel("Blur")
                Text(framing.blur, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().lineLimit(1).fixedSize()
            }
            SettingsRow("Feather") {
                Slider(value: $framing.feather, in: 0...0.2).accessibilityLabel("Feather")
                Text(framing.feather, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().lineLimit(1).fixedSize()
            }
        }
        if framing.subject == .original, framing.fit == .blurredFill {
            SettingsRow("Free window") {
                Toggle(isOn: Binding(get: { framing.lockAspect == false }, set: { framing.lockAspect = $0 ? false : nil })) {
                    Text("Free window").lineLimit(1).fixedSize()
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Draw the focus frame at any shape; blurred fill covers the rest. Off keeps the frame at the canvas shape.")
            }
        }
        if framing.subject != .layout {
            SettingsRow("Focus frame") {
                // One view, so the row's width cap does not push the button to the column's edge.
                HStack(spacing: Theme.spaceM) {
                    Text(framing.focusFrame == nil ? "Full source" : "Custom")
                        .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    Button("Reset focus frame", systemImage: "arrow.uturn.backward") { framing.focusFrame = nil }
                        .labelStyle(.iconOnly).lineLimit(1).fixedSize()
                        .disabled(framing.focusFrame == nil)
                        .help("Reset the focus frame to the full source")
                }
            }
            SettingsRow("Zoom") {
                Slider(value: Binding(get: { zoomLive ?? FocusFrameZoom.zoom(framing.focusFrame) },
                                      set: { zoomLive = $0 }),
                       in: FocusFrameZoom.range) { Text("Zoom") } onEditingChanged: { editing in
                    guard !editing, let zoom = zoomLive else { return }
                    zoomLive = nil
                    framing.focusFrame = FocusFrameZoom.frame(zoom: zoom, current: framing.focusFrame, base: baseFocusFrame)
                }
                .labelsHidden()
                .accessibilityLabel("Zoom")
                .help("Zoom the focus frame in and out around its centre; drag it in the preview to move it")
                (Text(zoomLive ?? FocusFrameZoom.zoom(framing.focusFrame), format: .number.precision(.fractionLength(1))) + Text("×"))
                    .monospacedDigit().lineLimit(1).fixedSize()
            }
        }
        Color.clear.frame(height: 0)
            .task(id: "\(videoIDs)|\(store.videoPeopleVersion)|\(store.transcriptCountsVersion)") {
                hasTurns = false
                var feeds: [Int] = []
                var people: [(record: VideoPersonRecord, videoURL: URL)] = []
                for id in videoIDs {
                    let evidence = await store.speakerTurns(videoID: id)
                    guard !Task.isCancelled else { return }
                    hasTurns = hasTurns || !evidence.turns.isEmpty
                    guard let video = store.videos.first(where: { $0.id == id }) else { continue }
                    let url = video.url
                    feeds.append(FramingPlanner.recordedFeedCount(video: video, roster: evidence.roster))
                    for person in evidence.roster where !people.contains(where: { $0.record.key == person.key }) {
                        people.append((person, url))
                    }
                }
                roster = people
                feedCounts = feeds
            }
    }

    /// The frame a cleared focus frame stands for: the canvas shape centred in the first recording.
    private var baseFocusFrame: FreeCropRect {
        let video = videoIDs.lazy.compactMap { id in store.videos.first { $0.id == id } }.first { $0.width > 0 && $0.height > 0 }
        let size = video.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 1920, height: 1080)
        return FocusFrame.initial(framing: framing, sourceSize: size, canvasAspect: canvasAspect)
    }

    /// Everyone in the footage; a tap makes or unmakes a VIP for this run only.
    private var vipRow: some View {
        let names = roster.filter { vipKeys.contains($0.record.key) }.map(\.record.displayName)
        return SettingsRow("VIPs", detail: names.isEmpty ? "Nobody yet. Tap a face to make them a VIP for this run."
                           : names.joined(separator: ", ") + (framing.vips == nil ? " (from People)" : " (this run)")) {
            HStack(spacing: Theme.spaceM) {
                ForEach(roster, id: \.record.key) { entry in
                    let isVIP = vipKeys.contains(entry.record.key)
                    var badged = entry.record
                    let _ = badged.vip = isVIP
                    Button {
                        var keys = vipKeys
                        if !keys.insert(entry.record.key).inserted { keys.remove(entry.record.key) }
                        let tagged = Set(roster.filter(\.record.isVIP).map(\.record.key))
                        framing.vips = keys == tagged ? nil : keys.sorted()
                    } label: {
                        VStack(spacing: 2) {
                            VideoPersonAvatar(record: badged, videoURL: entry.videoURL, size: 32)
                                .overlay(Circle().strokeBorder(isVIP ? Color.accentColor : .clear, lineWidth: 2))
                            Text(entry.record.displayName).font(.caption).lineLimit(1).fixedSize()
                                .foregroundStyle(isVIP ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(isVIP ? "VIP for this run. Click to drop." : "Click to make \(entry.record.displayName) a VIP for this run.")
                    .accessibilityLabel("\(entry.record.displayName)\(isVIP ? ", VIP" : "")")
                }
            }
        }
    }

    private var layouts: [ScreenCropLayout] { ScreenCropStore.all() }
    private var defaultLayout: String { type == .screen ? "Screen + presenter" : "Split" }

    private func sourceRow(_ role: ScreenCropArea.Role) -> some View {
        let path = framing.sourceRoles?[role.rawValue] ?? ""
        func set(_ path: String) {
            var roles = framing.sourceRoles ?? [:]
            roles[role.rawValue] = path.isEmpty ? nil : path
            framing.sourceRoles = roles.isEmpty ? nil : roles
        }
        return SettingsRow(role.label) {
            SourcePickerButton(
                title: role.label, choices: store.videos.map(SourceChoice.init),
                selection: store.videos.first { $0.url.path == path }.map(SourceChoice.init),
                placeholder: "Main recording", placeholderImage: "video",
                caption: "Choose the recording that carries the \(role.label.lowercased()).",
                actions: [SourceAction(title: "Main recording", systemImage: "video", isCurrent: path.isEmpty) { set("") }]
            ) { set($0.id) }
        }
    }

    private func reason(_ subject: Framing.Subject) -> String? {
        FramingPlanner.unavailableReason(subject, type: type, hasTurns: hasTurns, hasVIP: hasVIP)
    }
}
