import SwiftUI

struct ShadowOffsetPad: View {
    @Binding var x: Double
    @Binding var y: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            Path { path in
                path.move(to: CGPoint(x: 22, y: 0))
                path.addLine(to: CGPoint(x: 22, y: 44))
                path.move(to: CGPoint(x: 0, y: 22))
                path.addLine(to: CGPoint(x: 44, y: 22))
            }.stroke(.secondary.opacity(0.4))
            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                .position(ShadowOffsetMapping.position(x: x, y: y))
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
                let offset = ShadowOffsetMapping.offset(at: value.location)
                x = offset.x
                y = offset.y
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shadow offset; edit X and Y in the adjacent fields")
        .accessibilityValue("X \(x.formatted()), Y \(y.formatted())")
        .help(WizardFieldHelp.textDecor["shadowOffset"]!.tooltip)
    }
}
