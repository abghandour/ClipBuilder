import SwiftUI

/// The vendor mark for one AI provider — a template image from the asset
/// catalog tinted with the brand color, or an SF Symbol for unknown keys.
struct ProviderLogo: View {
    let brand: AIProviderBrand
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let asset = brand.logoAsset {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "sparkles")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .accessibilityLabel(brand.label)
    }

    private var tint: Color {
        brand.tintHex.flatMap(Color.init(hex:)) ?? .primary
    }
}

/// Which model produced an AI result: the provider's logo, optionally the
/// model name beside it, the full detail on hover, and a popover with
/// everything on record when clicked. One look everywhere provenance
/// appears — transcripts, analyze batches, curation picks, reels, lessons.
struct ProvenanceBadge: View {
    enum Style {
        /// Logo only — for dense rows and thumbnails.
        case icon
        /// Logo + "Haiku 4.5".
        case model
        /// Logo + "Claude · Haiku 4.5".
        case full
    }

    let provenance: AIProvenance
    var style: Style = .icon
    /// Leads the tooltip and popover: "Transcribed by", "Curated by"…
    var role: String? = nil
    var size: CGFloat = 14
    /// Draw on a translucent plate (for badges overlaid on media).
    var plated = false

    @State private var showingDetails = false

    var body: some View {
        HStack(spacing: 4) {
            ProviderLogo(brand: provenance.brand, size: size)
            if let text {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(plated ? .white : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, plated ? 5 : 0)
        .padding(.vertical, plated ? 3 : 0)
        .background {
            if plated {
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .fill(.black.opacity(0.6))
            }
        }
        .contentShape(Rectangle())
        .help(provenance.tooltip(role: role))
        .onTapGesture { showingDetails = true }
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            ProvenanceDetails(provenance: provenance, role: role)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(role ?? "AI"): \(provenance.shortLabel)")
    }

    private var text: String? {
        switch style {
        case .icon: return nil
        case .model: return provenance.modelDisplayName ?? provenance.brand.label
        case .full: return provenance.shortLabel
        }
    }
}

/// Everything recorded about one AI output, for the badge's popover.
struct ProvenanceDetails: View {
    let provenance: AIProvenance
    var role: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderLogo(brand: provenance.brand, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provenance.shortLabel)
                        .font(.headline)
                    Text(role.map { "\($0) \(provenance.brand.vendor)" } ?? provenance.brand.vendor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let model = provenance.model {
                    GridRow {
                        Text("Model id").foregroundStyle(.secondary)
                        Text(model).textSelection(.enabled)
                    }
                }
                if let task = provenance.taskLabel {
                    GridRow {
                        Text("Task").foregroundStyle(.secondary)
                        Text(task)
                    }
                }
                if let at = provenance.at {
                    GridRow {
                        Text("When").foregroundStyle(.secondary)
                        Text(AIProvenance.dateFormatter.string(from: at))
                    }
                }
                GridRow {
                    Text("Runs via").foregroundStyle(.secondary)
                    Text(runsVia)
                }
            }
            .font(.caption)
            if provenance.fellBack {
                Label("Ran as a fallback — the configured provider failed for this call.",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private var runsVia: String {
        if provenance.provider == AIProvenance.appleProvider {
            return "On-device (Apple \(provenance.model ?? "framework"))"
        }
        if let provider = AICatalog.provider(provenance.provider) {
            return "\(provider.label) (`\(provider.bin)`)"
        }
        return provenance.provider
    }
}

/// Several provenance badges in a row — a reel card's planner, caption
/// writer, critic, and cover picker. Roles that share a model collapse
/// into ONE badge whose tooltip lists them ("Planned · Caption · Critiqued
/// by Claude · Sonnet 4.6"); when different models did different jobs, one
/// badge per model with its model name, so they're tellable apart.
struct ProvenanceRow: View {
    /// (role, provenance) pairs; nil entries are skipped.
    let entries: [(role: String, provenance: AIProvenance?)]
    var size: CGFloat = 13

    private struct Group {
        var provenance: AIProvenance
        var roles: [String]
    }

    private var groups: [Group] {
        var result: [Group] = []
        for entry in entries {
            guard let provenance = entry.provenance else { continue }
            if let index = result.firstIndex(where: {
                $0.provenance.provider == provenance.provider && $0.provenance.model == provenance.model
            }) {
                result[index].roles.append(entry.role)
            } else {
                result.append(Group(provenance: provenance, roles: [entry.role]))
            }
        }
        return result
    }

    var body: some View {
        let groups = groups
        if !groups.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    ProvenanceBadge(provenance: group.provenance,
                                    style: groups.count > 1 ? .model : .icon,
                                    role: Self.combinedRole(group.roles), size: size)
                }
            }
        }
    }

    /// "Planned by" + "Caption by" + "Critiqued by" → "Planned · Caption · Critiqued by".
    static func combinedRole(_ roles: [String]) -> String {
        guard roles.count > 1 else { return roles.first ?? "AI" }
        let stems = roles.map { role -> String in
            role.hasSuffix(" by") ? String(role.dropLast(3)) : role
        }
        return stems.joined(separator: " · ") + " by"
    }
}

extension Color {
    /// "#RRGGBB" → Color; nil for anything else.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
