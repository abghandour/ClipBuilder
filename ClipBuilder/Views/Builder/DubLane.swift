import SwiftUI

struct DubLane: View {
    @Environment(AppStore.self) private var store
    let layout: BuilderDubLayout.Layout
    let contentWidth: CGFloat
    let rowHeight: CGFloat
    @State private var click = LaneClickLocator()

    var body: some View {
        let model = store.builder
        ZStack(alignment: .topLeading) {
            TimelineTrackStyle.laneShape.fill(.purple.opacity(0.12))
            ForEach(layout.blocks) { block in
                DubLaneBlock(block: block, rowHeight: rowHeight)
            }
        }
        .frame(width: contentWidth, height: CGFloat(layout.rows) * rowHeight, alignment: .topLeading)
        .laneClickTracking(click)
        .task(id: model.document.dubLines) {
            let lines = model.document.dubLines ?? [], profile = model.profileName
            let missing = await BuilderDubLayout.missingAudio(lines: lines)
            guard !Task.isCancelled, profile == model.profileName, lines == model.document.dubLines else { return }
            model.missingDubAudio = missing
        }
    }
}

private struct DubLaneBlock: View {
    @Environment(AppStore.self) private var store
    let block: BuilderDubLayout.Block
    let rowHeight: CGFloat

    private var speaker: String {
        store.people.first { $0.key == block.line.speakerKey }?.displayName ?? DubPlanning.speakerLabel(block.line.speakerKey)
    }

    var body: some View {
        let model = store.builder
        let pps = model.pointsPerSecond
        let width = max(1, block.duration * pps)
        let height = rowHeight - 8
        let audible = TimelineDocument.subtracting(block.freezes, from: block.line.start..<max(block.line.start, block.end))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .fill(.purple.opacity(block.prepared ? 0.5 : 0.06))
            ForEach(Array(audible.enumerated()), id: \.offset) { _, range in
                HStack(spacing: 4) {
                    Circle().fill(SpeakerColors.color(for: speaker)).frame(width: 6, height: 6)
                    Text(speaker).fontWeight(.semibold)
                    if !block.prepared { Text("not prepared") }
                    else if block.line.draft == true { Text("draft") }
                    if block.line.tight {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(block.line.text)
                }
                .font(.caption).lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 6)
                .frame(width: max(0, (range.upperBound - range.lowerBound) * pps), alignment: .leading)
                .clipped()
                .offset(x: (range.lowerBound - block.line.start) * pps)
            }
            ForEach(Array(block.freezes.enumerated()), id: \.offset) { _, range in
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.35)))
                    var hatch = Path()
                    for x in stride(from: -size.height, through: size.width, by: 8) {
                        hatch.move(to: CGPoint(x: x, y: size.height))
                        hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                    }
                    context.stroke(hatch, with: .color(.white.opacity(0.22)), lineWidth: 1)
                }
                .frame(width: (range.upperBound - range.lowerBound) * pps, height: height)
                .clipped().offset(x: (range.lowerBound - block.line.start) * pps)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(model.selection == .dubLine(block.id) ? Color.accentColor : .purple.opacity(block.prepared ? 0.4 : 1), lineWidth: 2)
        }
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { value in
            model.selectDubLine(block.id)
            if case .first = value { store.reviewTimelineDub(at: block.id) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(speaker): \(block.line.text)")
        .accessibilityValue(block.prepared ? (block.line.tight ? "Tight" : "Prepared") : "Not prepared")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selectDubLine(block.id) }
        .accessibilityAction(named: "Review lines") { store.reviewTimelineDub(at: block.id) }
        .help("Placed by the dub. Change it in Review lines…")
        .speakerColors(for: [speaker])
        .offset(x: block.line.start * pps, y: CGFloat(block.row) * rowHeight + 4)
    }
}
