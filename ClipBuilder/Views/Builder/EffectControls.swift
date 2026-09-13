import SwiftUI

/// Track defaults and clip overrides share the same controls; a supplied
/// inheritance label enables the clip-only Inherit / None distinction.
struct EffectControls: View {
    @Binding var effect: EffectSpec?
    var inheritedLookName: String?
    @State private var availableIDs: Set<String>?

    static let groups = ["looks", "film", "adjust", "detail", "stylize"]

    var body: some View {
        Picker("Look", selection: Self.selectionBinding(effect: $effect,
                                                       inherits: inheritedLookName != nil)) {
            if let inheritedLookName {
                Text("Inherit from area (\(inheritedLookName))").tag("inherit")
                    .help("Use the area's look, including future changes to it")
            }
            Text("None").tag("none")
                .help("Show this footage without a look")
            ForEach(Self.groups, id: \.self) { group in
                Section(group.capitalized) {
                    ForEach(EffectCatalog.presets.filter { $0.group == group && $0.id != "none" }, id: \.id) { preset in
                        let available = availableIDs?.contains(preset.id) == true
                        Text(preset.name).tag(preset.id)
                            .disabled(!available)
                            .help(available ? "Apply \(preset.name)"
                                  : availableIDs == nil ? "Checking local look support"
                                  : "Unavailable: the local ffmpeg lacks a required filter or the LUT is missing")
                    }
                }
            }
        }
        .help(inheritedLookName == nil
              ? "Apply a look to footage in this area"
              : "Inherit the area's look, turn it off, or override it for this clip")
        .task { availableIDs = await Self.availablePresetIDs() }

        if let effect, effect.preset != "none", let preset = EffectCatalog.preset(for: effect.preset) {
            ForEach(preset.params, id: \.name) { param in
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    HStack {
                        Text(param.name.replacingOccurrences(of: "_", with: " ").capitalized)
                        Spacer()
                        Text(Self.parameterBinding(effect: $effect, param: param).wrappedValue,
                             format: .number.precision(.fractionLength(0...2)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Self.parameterBinding(effect: $effect, param: param), in: param.min...param.max)
                        .accessibilityLabel(param.name.replacingOccurrences(of: "_", with: " ").capitalized)
                        .help("\(param.name): \(param.min.formatted())…\(param.max.formatted())")
                }
                .font(.caption)
            }
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                HStack {
                    Text("Intensity")
                    Spacer()
                    Text(effect.intensity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Self.intensityBinding(effect: $effect), in: 0...1)
                    .accessibilityLabel("Look intensity")
                    .help("Intensity: 0…1. Blend from the original footage to the full look.")
            }
            .font(.caption)
        }
    }

    /// Explicit bindings keep every write on the caller's undo/save path.
    static func selectionBinding(effect: Binding<EffectSpec?>, inherits: Bool) -> Binding<String> {
        Binding(
            get: { effect.wrappedValue?.preset ?? (inherits ? "inherit" : "none") },
            set: { selection in
                if selection == "inherit" || (selection == "none" && !inherits) {
                    effect.wrappedValue = nil
                } else if EffectCatalog.preset(for: selection) != nil {
                    effect.wrappedValue = EffectSpec(preset: selection)
                }
            })
    }

    static func parameterBinding(effect: Binding<EffectSpec?>, param: EffectCatalog.ParamSpec) -> Binding<Double> {
        Binding(
            get: { min(param.max, max(param.min, effect.wrappedValue?.params[param.name] ?? param.default)) },
            set: { value in
                guard value.isFinite, var updated = effect.wrappedValue,
                      EffectCatalog.preset(for: updated.preset)?.params.contains(param) == true else { return }
                updated.params[param.name] = min(param.max, max(param.min, value))
                effect.wrappedValue = updated
            })
    }

    static func intensityBinding(effect: Binding<EffectSpec?>) -> Binding<Double> {
        Binding(
            get: { min(1, max(0, effect.wrappedValue?.intensity ?? 1)) },
            set: { value in
                guard value.isFinite, var updated = effect.wrappedValue else { return }
                updated.intensity = min(1, max(0, value))
                effect.wrappedValue = updated
            })
    }

    @concurrent
    nonisolated static func availablePresetIDs() async -> Set<String> {
        let filters = EffectCatalog.availableFilters
        return Set(EffectCatalog.ids.filter { EffectCatalog.isAvailable($0, filters: filters) })
    }
}
