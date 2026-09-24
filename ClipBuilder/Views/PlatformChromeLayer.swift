import SwiftUI

/// What the preview draws over the picture: nothing, the safe-area shading
/// alone, or one platform's mock buttons, header and description.
nonisolated enum PlatformChromePreview: String, CaseIterable, Identifiable, Sendable {
    case off, safeArea, instagram, tiktok, youtubeShorts, youtube

    static let storageKey = "previewPlatformChrome"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .safeArea: "Safe area only"
        case .instagram: SocialPlatform.instagram.label
        case .tiktok: SocialPlatform.tiktok.label
        case .youtubeShorts: SocialPlatform.youtubeShorts.label
        case .youtube: SocialPlatform.youtube.label
        }
    }

    var platform: SocialPlatform? {
        switch self {
        case .off, .safeArea: nil
        case .instagram: .instagram
        case .tiktok: .tiktok
        case .youtubeShorts: .youtubeShorts
        case .youtube: .youtube
        }
    }
}

/// The menu that picks the simulated platform; one choice for every preview.
struct PlatformChromePicker: View {
    @AppStorage(PlatformChromePreview.storageKey) private var choice = PlatformChromePreview.off.rawValue

    var body: some View {
        Menu {
            Picker("Simulate", selection: $choice) {
                ForEach(PlatformChromePreview.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(choice == PlatformChromePreview.off.rawValue ? "Simulate" : PlatformChromePreview(rawValue: choice)?.label ?? "Simulate",
                  systemImage: "iphone")
        }
        .help("Draw a platform's buttons, header and description over the picture to see what they hide")
    }
}

/// Mock platform chrome and shaded zones over a video frame of `size`. The
/// zones come from the same geometry the renderer keeps overlays out of.
struct PlatformChromeLayer: View {
    let size: CGSize
    /// The output canvas's flag, so the safe-area choice shades the union.
    var safeAreaSettings: PlatformSafeAreaSettings
    @AppStorage(PlatformChromePreview.storageKey) private var choice = PlatformChromePreview.off.rawValue

    private var preview: PlatformChromePreview { PlatformChromePreview(rawValue: choice) ?? .off }
    private var aspectRatio: Double { size.height > 0 ? size.width / size.height : 9.0 / 16.0 }

    private var safeArea: PlatformSafeArea? {
        switch preview {
        case .off: nil
        case .safeArea:
            PlatformSafeArea.resolve(platforms: safeAreaSettings.platforms, aspectRatio: aspectRatio)
        default:
            preview.platform.flatMap { PlatformSafeArea.resolve(platforms: [$0], aspectRatio: aspectRatio) }
        }
    }

    var body: some View {
        if preview != .off, size.width > 0, size.height > 0 {
            ZStack(alignment: .topLeading) {
                if let safeArea {
                    ForEach(Array(safeArea.zones.enumerated()), id: \.offset) { _, zone in
                        Rectangle()
                            .fill(Color.red.opacity(0.16))
                            .frame(width: size.width * zone.rect.width, height: size.height * zone.rect.height)
                            .offset(x: size.width * zone.rect.minX, y: size.height * zone.rect.minY)
                    }
                    Rectangle()
                        .strokeBorder(Color.green.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: size.width * safeArea.rect.width, height: size.height * safeArea.rect.height)
                        .offset(x: size.width * safeArea.rect.minX, y: size.height * safeArea.rect.minY)
                }
                if let platform = preview.platform, platform.applies(toAspectRatio: aspectRatio) {
                    mockChrome(platform)
                } else if preview == .safeArea, safeArea == nil {
                    Text("No chosen platform covers this canvas")
                        .font(.caption).foregroundStyle(.white)
                        .padding(6).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                } else if preview.platform != nil, safeArea == nil {
                    Text("\(preview.label) does not show this canvas")
                        .font(.caption).foregroundStyle(.white)
                        .padding(6).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                }
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .accessibilityLabel("Simulated \(preview.label) player chrome")
        }
    }

    // MARK: - Mock chrome

    /// Everything scales with the frame height so a 210pt card and a full
    /// monitor read the same.
    private var unit: CGFloat { size.height / 1920 }
    private func pt(_ designPoints: CGFloat) -> CGFloat { designPoints * unit }
    private var textFont: Font { .system(size: pt(38), weight: .semibold) }
    private var smallFont: Font { .system(size: pt(30)) }
    private var iconFont: Font { .system(size: pt(64), weight: .regular) }

    @ViewBuilder
    private func mockChrome(_ platform: SocialPlatform) -> some View {
        switch platform {
        case .instagram:
            header(leading: "Reels", trailing: "camera")
            rail(y: 0.86, items: [("heart", "12.4K"), ("bubble.right", "318"), ("paperplane", "1,204"),
                                  ("ellipsis", ""), ("music.note", "")])
            footer(handle: "yourhandle", follow: true, description: "Caption of the reel goes here #fight #bjj",
                   audio: "Original audio · yourhandle")
        case .tiktok:
            header(leading: "Following    For You", trailing: "magnifyingglass", centered: true)
            rail(y: 0.86, items: [("person.crop.circle.badge.plus", ""), ("heart.fill", "12.4K"),
                                  ("ellipsis.bubble.fill", "318"), ("bookmark.fill", "2,051"),
                                  ("arrowshape.turn.up.right.fill", "1,204"), ("record.circle", "")])
            footer(handle: "yourhandle", follow: false, description: "Caption of the video goes here #fight #bjj",
                   audio: "♫ original sound · yourhandle")
        case .youtubeShorts:
            header(leading: "", trailing: "magnifyingglass ellipsis")
            rail(y: 0.92, items: [("hand.thumbsup", "2.8M"), ("hand.thumbsdown", "Dislike"),
                                  ("text.bubble", "2.8M"), ("arrowshape.turn.up.right", "Share"),
                                  ("arrow.triangle.2.circlepath", "Remix"), ("play.rectangle.fill", "")])
            footer(handle: "Your name", follow: false, description: "Here are some descriptions about videos",
                   audio: nil)
        case .youtube:
            playerChrome
        }
    }

    private func header(leading: String, trailing: String, centered: Bool = false) -> some View {
        HStack {
            if !centered {
                Text(leading).font(.system(size: pt(44), weight: .bold)).foregroundStyle(.white)
            }
            Spacer()
            if centered {
                Text(leading).font(textFont).foregroundStyle(.white)
                Spacer()
            }
            ForEach(trailing.split(separator: " ").map(String.init), id: \.self) { symbol in
                Image(systemName: symbol).font(iconFont).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, pt(40))
        .frame(width: size.width, height: size.height * 0.12, alignment: .bottom)
        .padding(.bottom, pt(20))
        .shadow(radius: 2)
    }

    /// The action buttons stacked up the right edge, ending at `y`.
    private func rail(y: Double, items: [(symbol: String, count: String)]) -> some View {
        VStack(spacing: pt(38)) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: pt(6)) {
                    Image(systemName: item.symbol).font(iconFont).foregroundStyle(.white)
                    if !item.count.isEmpty {
                        Text(item.count).font(smallFont).foregroundStyle(.white)
                    }
                }
            }
        }
        .shadow(radius: 2)
        .frame(width: size.width * 0.16)
        .frame(width: size.width, height: size.height * y, alignment: .bottomTrailing)
    }

    private func footer(handle: String, follow: Bool, description: String, audio: String?) -> some View {
        VStack(alignment: .leading, spacing: pt(14)) {
            HStack(spacing: pt(16)) {
                Circle().fill(.white.opacity(0.85)).frame(width: pt(72), height: pt(72))
                Text("@\(handle)").font(textFont).foregroundStyle(.white)
                if follow {
                    Text("Follow").font(smallFont).foregroundStyle(.white)
                        .padding(.horizontal, pt(18)).padding(.vertical, pt(6))
                        .overlay(RoundedRectangle(cornerRadius: pt(10)).stroke(.white, lineWidth: max(1, pt(2))))
                }
            }
            Text(description).font(smallFont).foregroundStyle(.white).lineLimit(2)
            if let audio {
                Text(audio).font(smallFont).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            }
        }
        .shadow(radius: 2)
        .padding(.horizontal, pt(36))
        .padding(.bottom, pt(70))
        .frame(width: size.width * 0.82, alignment: .leading)
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
    }

    /// The landscape YouTube player: title gradient on top, transport and
    /// progress bar along the bottom.
    private var playerChrome: some View {
        let h = size.height
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: h * 0.16)
            HStack {
                Text("Video title goes here").font(.system(size: h * 0.045, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "airplayvideo").font(.system(size: h * 0.05)).foregroundStyle(.white)
                Image(systemName: "ellipsis").font(.system(size: h * 0.05)).foregroundStyle(.white)
            }
            .padding(.horizontal, h * 0.03).padding(.top, h * 0.025)
            Image(systemName: "play.fill").font(.system(size: h * 0.12)).foregroundStyle(.white.opacity(0.9))
                .frame(width: size.width, height: h)
            VStack(spacing: h * 0.02) {
                HStack {
                    Text("0:12 / 3:45").font(.system(size: h * 0.04)).foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "captions.bubble").font(.system(size: h * 0.045)).foregroundStyle(.white)
                    Image(systemName: "gearshape").font(.system(size: h * 0.045)).foregroundStyle(.white)
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: h * 0.045)).foregroundStyle(.white)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.35)).frame(height: h * 0.012)
                    Capsule().fill(.red).frame(width: size.width * 0.3, height: h * 0.012)
                }
            }
            .padding(.horizontal, h * 0.03).padding(.bottom, h * 0.03)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            .frame(width: size.width, height: h, alignment: .bottom)
        }
    }
}
