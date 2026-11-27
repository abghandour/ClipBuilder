import SwiftUI

/// The system's borderless button, with a patch behind it while the pointer
/// is over it: a button with no border has nothing else to say which one a
/// click will land on. Every borderless button in the app uses it.
struct BorderlessHoverButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering(configuration: configuration)
    }

    private struct Hovering: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            Button(configuration)
                .buttonStyle(.borderless)
                // Drawn past the label's edges, so the layout is the borderless button's own.
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(hovered && isEnabled ? 0.14 : 0))
                        .padding(-3)
                        .allowsHitTesting(false)
                }
                .onHover { hovered = $0 }
        }
    }
}

extension PrimitiveButtonStyle where Self == BorderlessHoverButtonStyle {
    /// Borderless, highlighted under the pointer.
    static var borderlessHover: BorderlessHoverButtonStyle { BorderlessHoverButtonStyle() }
}
