import SwiftUI

struct CaptionStylePicker: View {
    @Binding var selection: String?
    let profile: BrandProfile
    @State private var thumbnails: [CaptionStyle: NSImage] = [:]

    private var styles: [NamedCaptionStyle] { profile.captionStyles ?? [] }
    private var previewStyles: [CaptionStyle] {
        styles.map { $0.style.applyingSharedStyle(profile.textStyles ?? []) }
    }

    private var resolvedSelection: Binding<String?> {
        Binding(get: {
            profile.captionStyles?.contains { $0.id.uuidString == selection } == true ? selection : nil
        }, set: { selection = $0 })
    }

    var body: some View {
        Picker("Caption style", selection: resolvedSelection) {
            Text("Profile default").lineLimit(1).fixedSize().tag(nil as String?)
            ForEach(CaptionPresets.Family.allCases) { family in
                let members = styles.filter { CaptionPresets.family(for: $0) == family }
                if !members.isEmpty {
                    Section(family.rawValue) {
                        ForEach(members) { style in choice(style) }
                    }
                }
            }
            let custom = styles.filter { CaptionPresets.family(for: $0) == nil }
            if !custom.isEmpty {
                Section("Custom") {
                    ForEach(custom) { style in choice(style) }
                }
            }
        }
        .pickerStyle(.menu)
        .lineLimit(1).fixedSize()
        .task(id: previewStyles) {
            for style in previewStyles {
                guard !Task.isCancelled else { return }
                guard thumbnails[style] == nil,
                      let preview = try? await CaptionThumbnailCache.shared.image(for: style),
                      !Task.isCancelled,
                      let image = NSImage(data: preview.data) else { continue }
                // Native menu rows use the NSImage's logical size.
                let scale = min(80 / preview.size.width, 32 / preview.size.height)
                image.size = NSSize(width: preview.size.width * scale, height: preview.size.height * scale)
                thumbnails[style] = image
            }
        }
    }

    private func choice(_ style: NamedCaptionStyle) -> some View {
        Label {
            Text(style.name).lineLimit(1).fixedSize()
        } icon: {
            if let image = thumbnails[style.style.applyingSharedStyle(profile.textStyles ?? [])] {
                Image(nsImage: image)
            }
        }
        .tag(Optional(style.id.uuidString))
    }
}
