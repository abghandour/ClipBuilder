import SwiftUI

/// Chart series hues shared with the peace-grappler web reports (indigo,
/// pink, green, orange, red). Chrome stays native — these color data only.
enum ReportColors {
    static let accent = Color(red: 0x63 / 255, green: 0x66 / 255, blue: 0xF1 / 255)
    static let pink = Color(red: 0xEC / 255, green: 0x48 / 255, blue: 0x99 / 255)
    static let green = Color(red: 0x10 / 255, green: 0xB9 / 255, blue: 0x81 / 255)
    static let orange = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
    static let red = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)
    static let purple = Color(red: 0xA7 / 255, green: 0x8B / 255, blue: 0xFA / 255)
    static let sky = Color(red: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255)
    static let gold = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x06 / 255)
    static let silver = Color(red: 0x6B / 255, green: 0x72 / 255, blue: 0x80 / 255)
    static let bronze = Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)

    static let series: [Color] = [accent, pink, green, orange, purple, sky, red]

    static func series(_ index: Int) -> Color { series[index % series.count] }

    static func forType(_ type: String) -> Color {
        switch type.uppercased() {
        case "REELS", "REEL": return pink
        case "CAROUSEL", "CAROUSEL_ALBUM": return orange
        case "STORY": return purple
        case "AD": return silver
        default: return accent
        }
    }
}

/// One report section: title, optional subtitle, and its content on a card.
struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(Theme.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(.separator))
    }
}

/// A headline number with its label, optional delta line, note, and
/// breakdown chips.
struct StatCard: View {
    let stat: InstagramReport.Stat
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            Text(stat.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(stat.value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(accent ? ReportColors.accent : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let delta = stat.delta {
                DeltaText(delta: delta)
            } else if let note = stat.note {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
            if !stat.breakdown.isEmpty {
                BreakdownChips(items: stat.breakdown)
            }
        }
        .padding(Theme.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

/// "+12 today" / "↓ 17% vs previous period" in green, red, or grey.
struct DeltaText: View {
    let delta: InstagramReport.Delta

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: delta.isPositive ? "arrow.up" : delta.isNegative ? "arrow.down" : "minus")
                .font(.caption2.bold())
            if let percent = delta.percent {
                Text("\(Int(abs(percent).rounded()))%")
            } else {
                Text(Int(abs(delta.amount)).formatted())
            }
            Text(delta.suffix).foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(delta.isPositive ? ReportColors.green : delta.isNegative ? ReportColors.red : .secondary)
        .lineLimit(1)
    }
}

/// Follower delta card (Yesterday / Last 7 Days / Last 30 Days).
struct GrowthCardView: View {
    let card: InstagramReport.GrowthCard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            Text(card.label).font(.caption).foregroundStyle(.secondary)
            if let delta = card.delta {
                Text(delta > 0 ? "+\(delta.formatted())" : delta.formatted())
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(delta > 0 ? ReportColors.green : delta < 0 ? ReportColors.red : .secondary)
            } else {
                Text("–").font(.title2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            Text("followers").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(Theme.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

/// #1 / #2 / #3 in gold, silver, bronze; the rest in the accent.
struct RankBadge: View {
    let rank: Int

    private var color: Color {
        switch rank {
        case 1: return ReportColors.gold
        case 2: return ReportColors.silver
        case 3: return ReportColors.bronze
        default: return ReportColors.accent
        }
    }

    var body: some View {
        Text("\(rank)")
            .font(.badge)
            .foregroundStyle(.white)
            .frame(minWidth: 22, minHeight: 22)
            .background(color, in: Circle())
    }
}

/// REELS / FEED / CAROUSEL pill.
struct TypeBadge: View {
    let type: String

    var body: some View {
        Text(type)
            .font(.badgeCompact)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ReportColors.forType(type).opacity(0.15), in: Capsule())
            .foregroundStyle(ReportColors.forType(type))
    }
}

/// Small value · label chips that wrap onto as many lines as needed.
struct BreakdownChips: View {
    let items: [InstagramReport.LabeledValue]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(items) { item in
                HStack(spacing: 3) {
                    Text(item.intValue.formatted()).font(.caption2.bold().monospacedDigit())
                    Text(item.label).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
        }
    }
}

/// Left-to-right, top-to-bottom wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Label / proportional bar / value rows (top cities, link taps, …).
struct HorizontalBars: View {
    let items: [InstagramReport.LabeledValue]
    var color = ReportColors.accent
    var percent = false

    var body: some View {
        // Once per render, not once per bar (the maximum used to be
        // re-derived inside every row's GeometryReader).
        let total = items.reduce(0) { $0 + $1.value }
        let maximum = items.map(\.value).max() ?? 1
        VStack(spacing: 6) {
            ForEach(items) { item in
                HStack(spacing: Theme.spaceS) {
                    Text(item.label)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 140, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary.opacity(0.5))
                            Capsule().fill(color)
                                .frame(width: max(2, proxy.size.width * CGFloat(item.value / max(maximum, 1))))
                        }
                    }
                    .frame(height: 8)
                    Text(percent && total > 0
                         ? String(format: "%.0f%%", item.value / total * 100)
                         : item.intValue.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }
}

/// 7 × 24 weekly activity grid (Monday first, UTC hours).
struct CommentHeatmap: View {
    let counts: [Int]

    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private var maximum: Int { max(1, counts.max() ?? 1) }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text("").frame(width: 32)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 3 == 0 ? "\(hour)" : "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 3) {
                    Text(days[day]).font(.caption2).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let value = counts.indices.contains(day * 24 + hour) ? counts[day * 24 + hour] : 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(value == 0 ? Color.secondary.opacity(0.12)
                                  : ReportColors.accent.opacity(0.15 + 0.85 * Double(value) / Double(maximum)))
                            .frame(maxWidth: .infinity)
                            .frame(height: 16)
                            .help("\(days[day]) \(hour):00 UTC — \(value) comment\(value == 1 ? "" : "s")")
                    }
                }
            }
            HStack(spacing: 6) {
                Spacer()
                Text("Lower").font(.caption2).foregroundStyle(.secondary)
                LinearGradient(colors: [ReportColors.accent.opacity(0.15), ReportColors.accent],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 100, height: 8)
                    .clipShape(Capsule())
                Text("Higher").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }
}

/// A post's thumbnail — the cached file when the grid downloaded it,
/// else the Graph CDN URL — at a small fixed size.
struct PostThumbnail: View {
    let media: IGReportMediaRow
    var size: CGFloat = 38

    var body: some View {
        Group {
            if let local = media.localThumbnailURL {
                CachedImage(url: local, maxPixel: 160) { placeholder }
            } else if let remote = media.thumbnailURL.flatMap(URL.init(string:)) {
                AsyncImage(url: remote) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Theme.mediaRadius)
            .fill(.quaternary)
            .overlay(Image(systemName: media.isReel ? "play.rectangle" : "photo")
                .font(.caption).foregroundStyle(.secondary))
    }
}

/// Caption + date + type for ranked lists and tables.
struct PostCell: View {
    let media: IGReportMediaRow
    var showThumbnail = true

    var body: some View {
        HStack(spacing: Theme.spaceS) {
            if showThumbnail { PostThumbnail(media: media) }
            VStack(alignment: .leading, spacing: 2) {
                Text(media.caption.isEmpty ? "(no caption)" : media.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    TypeBadge(type: media.typeLabel)
                    if let date = media.postedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// "Open on Instagram" for a post.
struct OpenPostButton: View {
    let media: IGReportMediaRow

    var body: some View {
        if let url = media.permalinkURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open on Instagram")
        }
    }
}

/// Centered secondary note for empty sections.
struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }
}
