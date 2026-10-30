import SwiftUI

/// Sidebar aliases select the initial studio tab; all four tabs share one host.
enum TextLooksTab: String, CaseIterable, Identifiable {
    case captions = "Captions"
    case tags = "Name tags"
    case overlays = "Overlays"
    case named = "Named styles"
    case fonts = "Fonts"
    var id: String { rawValue }

    /// The legacy sidebar sections name a tab; the Text row opens the last one.
    static func tab(for section: SidebarSection) -> Self? {
        switch section {
        case .captions: .captions
        case .tags: .tags
        case .overlays: .overlays
        case .fonts: .fonts
        default: nil
        }
    }

    static let rememberedKey = "textLooks.tab"
    static func remember(_ tab: Self, defaults: UserDefaults = .standard) { defaults.set(tab.rawValue, forKey: rememberedKey) }
    static func remembered(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: rememberedKey).flatMap(Self.init(rawValue:)) ?? .captions
    }
}

struct TextLooksView: View {
    let initialTab: TextLooksTab
    @Environment(AppStore.self) private var store
    @AppStorage("textLooks.openNamedStyles") private var openNamedStyles = false
    @State private var tab: TextLooksTab
    @State private var selection: String? = "default"
    @State private var captionState = "Text"
    @State private var tagState = "Box"
    @State private var selectedImage: UUID?
    @State private var deleting = false
    @State private var counts = TextLookRunCounts()
    @State private var countError: String?
    @State private var overlayLinks: [TextLookRunCounts.Link] = []

    init(tab: TextLooksTab) {
        initialTab = tab
        _tab = State(initialValue: tab)
    }

    private var captionIndex: Int? { store.activeProfile.captionStyles?.firstIndex { $0.id.uuidString == selection } }
    private var tagIndex: Int? { store.activeProfile.tagStyles?.firstIndex { $0.id.uuidString == selection } }
    private var namedIndex: Int? { store.activeProfile.textStyles?.firstIndex { $0.id.uuidString == selection } }
    private var canDelete: Bool {
        switch tab {
        case .captions: captionIndex != nil
        case .tags: tagIndex != nil
        case .named: namedIndex != nil
        case .overlays, .fonts: false
        }
    }
    private var name: Binding<String> {
        Binding(
            get: {
                switch tab {
                case .captions: captionIndex.flatMap { store.activeProfile.captionStyles?[$0].name } ?? "Profile default"
                case .tags: tagIndex.flatMap { store.activeProfile.tagStyles?[$0].name } ?? "Profile default"
                case .named: namedIndex.flatMap { store.activeProfile.textStyles?[$0].name } ?? ""
                case .overlays, .fonts: ""
                }
            },
            set: { value in
                switch tab {
                case .captions: if let i = captionIndex { store.activeProfile.captionStyles?[i].name = value }
                case .tags: if let i = tagIndex { store.activeProfile.tagStyles?[i].name = value }
                case .named: if let i = namedIndex { store.activeProfile.textStyles?[i].name = value }
                case .overlays, .fonts: break
                }
                store.scheduleActiveProfileSave()
            })
    }
    private var caption: Binding<CaptionStyle> {
        Binding(
            get: { store.activeProfile.captionStyle(id: selection) },
            set: {
                if let i = captionIndex { store.activeProfile.captionStyles?[i].style = $0 } else { store.activeProfile.captions = $0 }
                store.scheduleActiveProfileSave()
            })
    }
    private var tag: Binding<TagStyle> {
        Binding(
            get: { store.activeProfile.tagStyle(id: selection) },
            set: {
                if let i = tagIndex { store.activeProfile.tagStyles?[i].style = $0 } else { store.activeProfile.tagStyle = $0 }
                store.scheduleActiveProfileSave()
            })
    }
    private var named: Binding<NamedTextStyle>? {
        guard let id = selection, let i = namedIndex, let fallback = store.activeProfile.textStyles?[i] else { return nil }
        return Binding(
            get: { store.activeProfile.textStyles?.first { $0.id.uuidString == id } ?? fallback },
            set: { value in
                guard let index = store.activeProfile.textStyles?.firstIndex(where: { $0.id.uuidString == id }) else { return }
                store.activeProfile.textStyles?[index] = value
                store.scheduleActiveProfileSave()
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Text Looks", selection: $tab) {
                ForEach(TextLooksTab.allCases) { tab in Text(tab.rawValue).lineLimit(1).fixedSize().tag(tab) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, Theme.spaceM).padding(.vertical, Theme.spaceS)
            Divider()
            if tab == .overlays {
                OverlayTemplatesView(runCounts: counts.overlays)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == .fonts {
                // The font files behind every picker's "Fonts Library" group.
                AssetBrowserView(kind: .fonts)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    TextLooksList(
                        entries: entries, presets: presets, selection: $selection,
                        addPreset: addPreset, add: { add(duplicate: false) }, duplicate: { add(duplicate: true) },
                        remove: { deleting = true }, canDelete: canDelete
                    )
                    .rememberedPaneWidth("pane.textLooks.list", min: 200, initial: 232, max: 300)
                    stage.id(selection).frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    inspector.frame(minWidth: 280, idealWidth: 336, maxWidth: 440).frame(maxHeight: .infinity)
                }
            }
            if let countError { FormCaption(countError, tone: .warning).padding(8) }
        }
        .screenTitle("Text Looks", subtitle: tab.rawValue)
        .onChange(of: tab) { _, value in
            TextLooksTab.remember(value)
            selection = value == .named ? store.activeProfile.textStyles?.first?.id.uuidString : "default"
            refreshOverlayLinks()
        }
        .onChange(of: selection) { selectedImage = nil }
        .onChange(of: selectedImage) { _, image in if image != nil { tagState = "Box" } }
        .onChange(of: initialTab) { _, value in tab = value }
        .onAppear {
            consumeNamedRequest()
            refreshOverlayLinks()
        }
        .onChange(of: openNamedStyles) { consumeNamedRequest() }
        .task(id: countKey) {
            guard let database = store.database else { return }
            do {
                let result = try await database.textLookRunCounts(namedLinks: namedLinks)
                try Task.checkCancellation()
                counts = result
                countError = nil
            } catch is CancellationError {
            } catch { countError = "Could not count style usage: \(error.localizedDescription)" }
        }
        .confirmationDialog("Delete this style?", isPresented: $deleting) {
            Button("Delete Style", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                tab == .named
                    ? "Linked elements keep their local overrides and fall back to their default look."
                    : "Runs using this style will use Profile default instead.")
        }
    }

    private var countKey: String {
        store.activeProfile.profileName + ":" + store.generatedVideos.map { String($0.id) }.joined(separator: ",")
            + namedLinks.map { "\($0.kind):\($0.style):\($0.namedID)" }.joined(separator: ",")
    }

    private func consumeNamedRequest() {
        guard openNamedStyles else { return }
        tab = .named
        selection = store.activeProfile.textStyles?.first?.id.uuidString
        openNamedStyles = false
    }

    @ViewBuilder private var stage: some View {
        switch tab {
        case .captions: TextLooksStage(caption: caption, selectedState: $captionState)
        case .tags: TextLooksStage(tag: tag, selectedState: $tagState, selectedImage: $selectedImage)
        case .named:
            if let named {
                TextLooksStage(named: named.wrappedValue)
            } else {
                ContentUnavailableView(
                    "Named styles", systemImage: "textformat",
                    description: Text("Create a look to share across captions, name tags and overlays."))
            }
        case .overlays, .fonts: EmptyView()
        }
    }

    @ViewBuilder private var inspector: some View {
        switch tab {
        case .captions: CaptionStyleEditor(name: name, style: caption, isDefault: captionIndex == nil, selectedState: $captionState)
        case .tags:
            TagStyleEditor(name: name, style: tag, isDefault: tagIndex == nil, selectedState: $tagState, selectedImage: $selectedImage)
        case .named:
            if let named {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spaceM) {
                        TextField("Name", text: named.name).help(WizardFieldHelp.textDecor["name"]!.tooltip)
                        TextLookInspector(
                            decor: Binding(get: { named.wrappedValue.decor }, set: { named.wrappedValue.decor = $0 ?? TextDecor() }),
                            fontFamily: named.fontFamily, defaultLabel: "Defaults", sourceLabel: "named style", stateLabel: "Look")
                    }.padding(Theme.spaceM)
                }
            }
        case .overlays, .fonts: EmptyView()
        }
    }

    private func baseName(_ id: String?) -> String {
        guard let id else { return "Default look" }
        return store.activeProfile.textStyles?.first { $0.id.uuidString == id }?.name ?? "Unavailable style"
    }
    private func captionEntry(_ id: String, _ name: String, _ style: CaptionStyle) -> TextLooksList.Entry {
        let resolved = style.applyingSharedStyle(store.activeProfile.textStyles ?? [])
        return .init(
            id: id, name: name, decor: resolved.resolvedTextDecor(for: .text), fontFamily: resolved.fontOverride ?? resolved.font,
            base: baseName(style.sharedStyleID), runs: counts.captions[id] ?? 0)
    }
    private func tagEntry(_ id: String, _ name: String, _ style: TagStyle) -> TextLooksList.Entry {
        let resolved = style.applyingSharedStyle(store.activeProfile.textStyles ?? [])
        return .init(
            id: id, name: name,
            decor: (resolved.name.decor ?? TextDecor()).resolved(over: resolved.lineDecor.merged(over: resolved.name.legacyDecor)),
            fontFamily: resolved.name.fontOverride ?? resolved.name.font, base: baseName(style.sharedStyleID), runs: counts.tags[id] ?? 0)
    }
    private var entries: [TextLooksList.Entry] {
        switch tab {
        case .captions:
            [captionEntry("default", "Profile default", store.activeProfile.captions)]
                + (store.activeProfile.captionStyles ?? []).map { captionEntry($0.id.uuidString, $0.name, $0.style) }
        case .tags:
            [tagEntry("default", "Profile default", store.activeProfile.tagStyle(id: nil))]
                + (store.activeProfile.tagStyles ?? []).map { tagEntry($0.id.uuidString, $0.name, $0.style) }
        case .named:
            (store.activeProfile.textStyles ?? []).map {
                .init(
                    id: $0.id.uuidString, name: $0.name, decor: $0.decor,
                    fontFamily: $0.fontFamily, base: "Shared look", runs: counts.named[$0.id.uuidString] ?? 0)
            }
        case .overlays, .fonts: []
        }
    }
    private func refreshOverlayLinks() {
        // Refresh on studio entry/tab changes, never for every inspector keystroke.
        overlayLinks = OverlayTemplateStore.list().flatMap { template in
            let ids = Set(template.composition.texts.flatMap { [$0.sharedStyleID, $0.tagStyle?.sharedStyleID].compactMap { $0 } })
            return ids.sorted().map { TextLookRunCounts.Link(kind: "overlays", style: template.name, namedID: $0) }
        }
    }

    private var namedLinks: [TextLookRunCounts.Link] {
        var links = overlayLinks
        if let id = store.activeProfile.captions.sharedStyleID {
            links.append(.init(kind: "captions", style: "default", namedID: id))
        }
        if let id = store.activeProfile.tagStyle?.sharedStyleID {
            links.append(.init(kind: "tags", style: "default", namedID: id))
        }
        for caption in store.activeProfile.captionStyles ?? [] {
            if let id = caption.style.sharedStyleID { links.append(.init(kind: "captions", style: caption.id.uuidString, namedID: id)) }
        }
        for tag in store.activeProfile.tagStyles ?? [] {
            if let id = tag.style.sharedStyleID { links.append(.init(kind: "tags", style: tag.id.uuidString, namedID: id)) }
        }
        return links
    }
    private var presets: [TextLooksList.Entry] {
        switch tab {
        case .captions: CaptionPresets.styles.map { captionEntry($0.name, $0.name, $0.style) }
        case .tags: TextLookPresets.tags.map { tagEntry($0.name, $0.name, $0.style) }
        default: []
        }
    }
    private func addPreset(_ id: String) {
        if tab == .captions, let preset = CaptionPresets.styles.first(where: { $0.name == id }) {
            let copy = NamedCaptionStyle(name: preset.name, style: preset.style)
            store.activeProfile.captionStyles = (store.activeProfile.captionStyles ?? []) + [copy]
            selection = copy.id.uuidString
        } else if tab == .tags, let preset = TextLookPresets.tags.first(where: { $0.name == id }) {
            let copy = NamedTagStyle(name: preset.name, style: preset.style)
            store.activeProfile.tagStyles = (store.activeProfile.tagStyles ?? []) + [copy]
            selection = copy.id.uuidString
        }
        store.saveActiveProfile()
    }
    private func add(duplicate: Bool) {
        let label = duplicate ? name.wrappedValue + " Copy" : "New Style"
        switch tab {
        case .captions:
            let copy = NamedCaptionStyle(name: label, style: duplicate ? caption.wrappedValue : store.activeProfile.captions)
            store.activeProfile.captionStyles = (store.activeProfile.captionStyles ?? []) + [copy]
            selection = copy.id.uuidString
        case .tags:
            let copy = NamedTagStyle(name: label, style: duplicate ? tag.wrappedValue : store.activeProfile.tagStyle(id: nil))
            store.activeProfile.tagStyles = (store.activeProfile.tagStyles ?? []) + [copy]
            selection = copy.id.uuidString
        case .named:
            let copy = NamedTextStyle(
                name: label, decor: duplicate ? named?.wrappedValue.decor ?? TextDecor() : TextDecor(),
                fontFamily: duplicate ? named?.wrappedValue.fontFamily : nil)
            store.activeProfile.textStyles = (store.activeProfile.textStyles ?? []) + [copy]
            selection = copy.id.uuidString
        case .overlays, .fonts: break
        }
        store.saveActiveProfile()
    }
    private func remove() {
        guard canDelete else { return }
        switch tab {
        case .captions: store.activeProfile.captionStyles?.removeAll { $0.id.uuidString == selection }
        case .tags: store.activeProfile.tagStyles?.removeAll { $0.id.uuidString == selection }
        case .named: store.activeProfile.textStyles?.removeAll { $0.id.uuidString == selection }
        case .overlays, .fonts: break
        }
        selection = tab == .named ? store.activeProfile.textStyles?.first?.id.uuidString : "default"
        store.saveActiveProfile()
    }
}
