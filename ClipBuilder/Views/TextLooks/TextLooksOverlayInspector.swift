import SwiftUI

/// Timing and content stay with the selected item; its look uses the shared inspector.
struct TextLooksOverlayInspector: View {
    @Binding var composition: OverlayComposition
    @Binding var selection: OverlayItemSelection?

    var body: some View {
        ScrollView {
            selectedItem.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var selectedItem: some View {
        switch selection {
        case .text(let uid):
            if let index = composition.texts.firstIndex(where: { $0.uid == uid }) {
                let binding = $composition.texts[index]
                VStack(alignment: .leading, spacing: 12) {
                    Text("Text Item").lineLimit(1).fixedSize()
                        .font(.headline)
                    timingControls(
                        start: binding.startTime, end: binding.endTime,
                        transIn: binding.transIn, transOut: binding.transOut,
                        unbounded: binding.unbounded)
                    Toggle("AI Wizard may replace this text", isOn: binding.isDynamic)
                        .help(
                            "When on, the wizard writes its own copy into this text; static texts and images always render exactly as designed"
                        )
                    TextOverlayForm(item: binding, showsPreview: false)
                }
            }
        case .image(let uid):
            if let index = composition.images.firstIndex(where: { $0.uid == uid }) {
                let binding = $composition.images[index]
                VStack(alignment: .leading, spacing: 12) {
                    Text("Image Item").lineLimit(1).fixedSize()
                        .font(.headline)
                    timingControls(
                        start: binding.startTime, end: binding.endTime,
                        transIn: binding.transIn, transOut: binding.transOut,
                        unbounded: binding.unbounded)
                    ImageOverlayControls(item: binding, name: composition.images[index].displayName)
                }
            }
        case nil:
            Text("Select an item to edit its look, timing, and effects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Timing on the composition's own clock (t=0 is when the overlay begins
    /// in the video), with the matching effect beside each field: the appear
    /// effect plays at Start, the disappear effect as the duration ends.
    private func timingControls(
        start: Binding<Double>, end: Binding<Double>,
        transIn: Binding<String>, transOut: Binding<String>,
        unbounded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Stepper(
                    String(format: "Start: %.1fs", start.wrappedValue),
                    value: Binding(
                        get: { start.wrappedValue },
                        set: { newStart in
                            let duration = end.wrappedValue - start.wrappedValue
                            start.wrappedValue = max(0, newStart)
                            end.wrappedValue = start.wrappedValue + duration
                        }),
                    in: 0...120, step: 0.5)
            }
            HStack {
                effectPicker("Appear", selection: transIn)
            }
            HStack(spacing: 12) {
                if unbounded.wrappedValue {
                    Text("Duration: unbounded")
                } else {
                    Stepper(
                        String(format: "Duration: %.1fs", end.wrappedValue - start.wrappedValue),
                        value: Binding(
                            get: { end.wrappedValue - start.wrappedValue },
                            set: { end.wrappedValue = start.wrappedValue + max(0.5, $0) }),
                        in: 0.5...120, step: 0.5)
                }
            }
            HStack {
                effectPicker("Disappear", selection: transOut)
            }
            Toggle("Unbounded", isOn: unbounded)
                .help("Stays as long as the overlay is visible")
                .font(.caption)
        }
        .font(.callout)
    }

    private func effectPicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            ForEach(TextOverlayItem.transitionChoices, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .fixedSize()
    }

}
