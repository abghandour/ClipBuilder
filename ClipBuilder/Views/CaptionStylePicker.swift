import SwiftUI

/// The caption look in use, as a button that opens the chooser grid.
struct CaptionStylePicker: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: String?
    let profile: BrandProfile
    /// What "no choice" means here, and the look it resolves to.
    var fallbackName = "Profile default"
    var fallbackStyleID: String? = nil
    @State private var choosing = false

    private var chosen: NamedCaptionStyle? {
        profile.captionStyles?.first { $0.id.uuidString == selection }
    }
    private var fallbackStyle: CaptionStyle { profile.captionStyle(id: fallbackStyleID) }

    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: Theme.spaceS) {
                CaptionPresetThumbnail(style: (chosen?.style ?? fallbackStyle).applyingSharedStyle(profile.textStyles ?? []),
                                       height: 22, padding: 2)
                    .frame(width: 72)
                Text(chosen?.name ?? fallbackName).lineLimit(1).fixedSize()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
        }
        .help("Choose a caption style from this profile or the library")
        .accessibilityLabel("Caption style")
        .accessibilityValue(chosen?.name ?? fallbackName)
        .sheet(isPresented: $choosing) {
            CaptionStyleChooserSheet(profile: profile, selection: selection, fallbackName: fallbackName,
                                     fallbackStyle: fallbackStyle) { choose($0) }
        }
    }

    private func choose(_ choice: CaptionStyleChoices.Choice) {
        switch choice.source {
        case .fallback:
            selection = nil
        case .profile(let id):
            selection = id.uuidString
        case .library(let name):
            guard let preset = CaptionPresets.styles.first(where: { $0.name == name }) else { return }
            let saved = store.activeProfile.captionStyles ?? []
            if let copy = CaptionStyleChoices.existing(preset, in: saved) {
                selection = copy.id.uuidString
            } else {
                store.activeProfile.captionStyles = saved + [preset]
                store.saveActiveProfile()
                selection = preset.id.uuidString
            }
        }
    }
}

/// Every caption look as a grid of rendered samples. One click picks.
struct CaptionStyleChooserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: BrandProfile
    let selection: String?
    let fallbackName: String
    let fallbackStyle: CaptionStyle
    let choose: (CaptionStyleChoices.Choice) -> Void
    @State private var search = ""

    private var groups: [CaptionStyleChoices.Group] {
        CaptionStyleChoices.groups(saved: profile.captionStyles ?? [], fallbackName: fallbackName,
                                   fallbackStyle: fallbackStyle, search: search)
    }
    private var selectedID: String {
        profile.captionStyles?.contains { $0.id.uuidString == selection } == true ? selection ?? "fallback" : "fallback"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                Text("Caption Style").font(.headline)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search styles", text: $search).textFieldStyle(.plain)
                }
                .padding(Theme.spaceS)
                .background(.quaternary, in: .rect(cornerRadius: Theme.mediaRadius))
            }
            .padding(Theme.spaceM)
            if groups.isEmpty {
                ContentUnavailableView("No matching styles", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.spaceL) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: Theme.spaceS) {
                                SectionLabel(group.title)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: Theme.spaceM, alignment: .top)],
                                          alignment: .leading, spacing: Theme.spaceM) {
                                    ForEach(group.choices) { cell($0) }
                                }
                            }
                        }
                    }
                    .padding(Theme.spaceM)
                }
            }
            Divider()
            HStack {
                Text("Library styles are copied into this profile when picked.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }.lineLimit(1).fixedSize()
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.spaceM)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 640)
        .modalCloseButton { dismiss() }
    }

    private func cell(_ choice: CaptionStyleChoices.Choice) -> some View {
        let selected = choice.id == selectedID
        return Button {
            choose(choice)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                CaptionPresetThumbnail(style: choice.style.applyingSharedStyle(profile.textStyles ?? []), height: 92)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.mediaRadius)
                            .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(Theme.spaceXS)
                        }
                    }
                Text(choice.name).lineLimit(1).truncationMode(.tail).help(choice.name)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
