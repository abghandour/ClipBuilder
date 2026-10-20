import SwiftUI

/// The bold / italic / underline / strikethrough bar found in text inspectors
/// (Pages, Keynote): one segmented group of on/off buttons, one per trait.
/// Traits the caller does not pass are left out of the bar.
struct TextStyleBar: View {
    var bold: Binding<Bool>?
    var italic: Binding<Bool>?
    var underline: Binding<Bool>?
    var strikethrough: Binding<Bool>?

    var body: some View {
        ControlGroup {
            if let bold { segment("bold", "Bold", bold) }
            if let italic { segment("italic", "Italic", italic) }
            if let underline { segment("underline", "Underline", underline) }
            if let strikethrough { segment("strikethrough", "Strikethrough", strikethrough) }
        }
        .fixedSize()
    }

    private func segment(_ symbol: String, _ name: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Image(systemName: symbol) }
            .help(name)
            .accessibilityLabel(name)
    }
}

/// A point-size field with a stepper, as in a text inspector's "11 pt" box.
struct PointSizeField: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(
                get: { value },
                set: { value = min(range.upperBound, max(range.lowerBound, $0)) }
            ), format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .accessibilityLabel("Size in points")
            Text("pt").foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Stepper("", value: $value, in: range, step: step).labelsHidden()
        }
    }
}
