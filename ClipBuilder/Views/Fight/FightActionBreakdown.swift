import SwiftUI

struct FightActionBreakdown: View {
    let model: FightActionDetail.Model

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .top)], alignment: .leading, spacing: 16) {
            ForEach(["Technique", "Landed on", "Impact", "Limb", "Attempts", "Rounds"], id: \.self) { title in
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline).lineLimit(1).fixedSize()
                    ForEach(model.breakdowns[title] ?? []) { row in
                        VStack(spacing: 2) {
                            Text(row.title).font(.caption).lineLimit(1).fixedSize()
                            HStack(spacing: 8) {
                                ForEach(Array(model.fighters.enumerated()), id: \.element.id) { index, fighter in
                                    let count = row.values[fighter.id] ?? 0
                                    HStack(spacing: 4) {
                                        if index == 0 { Text("\(count)").monospacedDigit() }
                                        GeometryReader { geometry in
                                            HStack(spacing: 0) {
                                                if index == 0 { Spacer(minLength: 0) }
                                                Rectangle().fill(fighter.id.isEmpty ? Color.gray : index == 0 ? .red : .cyan)
                                                    .frame(width: geometry.size.width * Double(count) / Double(max(1, row.values.values.max() ?? 1)))
                                                if index != 0 { Spacer(minLength: 0) }
                                            }
                                        }.frame(height: 5)
                                        if index != 0 { Text("\(count)").monospacedDigit() }
                                    }.font(.caption).accessibilityElement(children: .ignore)
                                        .accessibilityLabel("\(fighter.name), \(row.title), \(count)")
                                }
                            }
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
