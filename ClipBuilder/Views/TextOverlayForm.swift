import SwiftUI

/// The text-overlay style editor shared by the Builder inspector and the
/// Overlays template section. Position is edited by dragging in the preview
/// and timing/effects live with the timing controls, so neither appears here.
struct TextOverlayForm: View {
    @Binding var item: TextOverlayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $item.text)
                .frame(minHeight: 48, maxHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

            Stepper("Font size: \(item.fontsize)", value: $item.fontsize, in: 10...200, step: 2)
            HStack {
                Toggle("Bold", isOn: $item.bold)
                Toggle("Italic", isOn: $item.italic)
            }
            FontFamilyPicker(family: $item.fontfamily)

            ColorPicker("Text color",
                        selection: overlayColorBinding($item.fontcolor),
                        supportsOpacity: false)
            ColorPicker("Background color",
                        selection: overlayOptionalColorBinding($item.bgcolor, fallback: "#000000"),
                        supportsOpacity: false)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Background opacity: %.0f%%", item.boxOpacity * 100))
                    .font(.caption)
                Slider(value: $item.boxOpacity, in: 0...1)
                Text(String(format: "Background corner radius: %.0f", item.boxRadius ?? 4))
                    .font(.caption)
                Slider(value: Binding(
                    get: { item.boxRadius ?? 4 },
                    set: { item.boxRadius = $0 }), in: 0...60, step: 1)
                Text(String(format: "Element opacity: %.0f%%", item.opacity * 100))
                    .font(.caption)
                Slider(value: $item.opacity, in: 0.05...1)
            }
        }
    }
}

/// The image-overlay style editor shared by the Builder inspector and the
/// Overlays template section.
struct ImageOverlayControls: View {
    @Binding var item: ImageOverlayItem
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Group {
                    CachedImage(url: item.url, maxPixel: 128, contentMode: .fit)
                }
                .frame(width: 48, height: 48)
                Text(name)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Size: %.0f%% of frame width", item.wFrac * 100))
                    .font(.caption)
                Slider(value: $item.wFrac, in: 0.05...1)
                Text(String(format: "Element opacity: %.0f%%", item.opacity * 100))
                    .font(.caption)
                Slider(value: $item.opacity, in: 0.05...1)
            }
        }
    }
}

// MARK: - Color bindings

/// Overlay colors persist as strings (names or #hex, shared with the render
/// pipeline); these adapt them to the system color picker.
func overlayColorBinding(_ string: Binding<String>) -> Binding<Color> {
    Binding(
        get: { overlayColor(string.wrappedValue) },
        set: { string.wrappedValue = overlayHexString($0) })
}

func overlayOptionalColorBinding(_ string: Binding<String?>, fallback: String) -> Binding<Color> {
    Binding(
        get: { overlayColor(string.wrappedValue ?? fallback) },
        set: { string.wrappedValue = overlayHexString($0) })
}

private func overlayColor(_ string: String?) -> Color {
    let (r, g, b) = TextOverlayRenderer.parseColor(string)
    return Color(red: r, green: g, blue: b)
}

private func overlayHexString(_ color: Color) -> String {
    let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
    return String(format: "#%02X%02X%02X",
                  Int((resolved.redComponent * 255).rounded()),
                  Int((resolved.greenComponent * 255).rounded()),
                  Int((resolved.blueComponent * 255).rounded()))
}

// MARK: - Font picker

/// Font family combo: a searchable popover listing the Fonts-library
/// families first, then every system family — each rendered in its own
/// typeface (menus can't do that, so this is a popover, not a Picker).
struct FontFamilyPicker: View {
    @Binding var family: String?

    @State private var showingList = false
    @State private var search = ""
    @State private var libraryFamilies: [String] = []
    @State private var systemFamilies: [String] = []

    var body: some View {
        LabeledContent("Font") {
            Button {
                showingList = true
            } label: {
                HStack(spacing: 4) {
                    Text(family?.isEmpty == false ? family! : "Default")
                        .font(sampleFont(family, size: 12))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .popover(isPresented: $showingList, arrowEdge: .bottom) {
                fontList
            }
        }
    }

    private var fontList: some View {
        VStack(spacing: 0) {
            TextField("Search fonts", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if search.isEmpty {
                        row(name: nil, label: "Default")
                    }
                    let library = matching(libraryFamilies)
                    if !library.isEmpty {
                        sectionHeader("Fonts Library")
                        ForEach(library, id: \.self) { name in
                            row(name: name, label: name)
                        }
                    }
                    sectionHeader("System")
                    ForEach(matching(systemFamilies), id: \.self) { name in
                        row(name: name, label: name)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 280, height: 360)
        .task {
            let library = await AssetStore.libraryFontFamiliesAsync()
            let system = Self.systemFamilies()
            libraryFamilies = library
            systemFamilies = system
        }
    }

    private func matching(_ names: [String]) -> [String] {
        search.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(name: String?, label: String) -> some View {
        Button {
            family = name
            showingList = false
        } label: {
            HStack {
                Text(label)
                    .font(sampleFont(name, size: 14))
                    .lineLimit(1)
                Spacer()
                if family == name || (name == nil && family?.isEmpty != false) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sampleFont(_ family: String?, size: CGFloat) -> Font {
        guard let family, !family.isEmpty else { return .system(size: size) }
        return .custom(family, size: size)
    }

    /// Family names of the fonts in the Fonts library (registered for this
    /// process at launch, so Font.custom resolves them).
    static func libraryFamilies() -> [String] {
        AssetStore.libraryFontFamilies()
    }

    /// Read per popover open (the `.task` above), so fonts installed
    /// system-wide mid-session show up without a relaunch.
    static func systemFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
