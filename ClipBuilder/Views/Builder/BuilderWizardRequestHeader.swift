import SwiftUI

struct BuilderWizardRequestHeader: View {
    @Bindable var model: WizardSheetModel
    let hide: () -> Void
    @State private var showHelp = false

    private let guidance = "B-roll chooses the first matching scene by ID; omit track to use the focused track. Clip numbers count visible clips on the track from left to right, including B-roll. ‘Cover all areas’ targets the selected B-roll clip."

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            TextField("For example: " + (model.examples.first ?? "remove the selected clip"), text: $model.request, axis: .vertical)
                .lineLimit(1...2)
                .textFieldStyle(.roundedBorder)
                .disabled(model.busy || model.phase == .awaitingPrerequisites)
                #if DEBUG
                .help("Enter an editing request. Times are timeline positions. Debug builds also accept JSON arrays of script steps.")
                #else
                .help("Enter an editing request. Times are timeline positions. Review the preview before applying.")
                #endif
            HStack(spacing: Theme.spaceS) {
                Picker("Provider", selection: $model.provider) {
                    ForEach(BuilderAgentProvider.allCases) { provider in
                        Text(provider.label).tag(provider).disabled(provider.disabledReason != nil)
                    }
                }
                .frame(maxWidth: 180)
                .disabled(model.busy || model.phase == .awaitingPrerequisites)
                .onChange(of: model.provider) { _, _ in model.saveProviderPreference() }
                .help("Local works without a provider. Claude uses only Builder tools. Codex and Gemini await confinement and credential validation.")
                Menu("Recent Requests") {
                    ForEach(model.history, id: \.self) { request in
                        Button(request) { model.request = request }
                            .help("Use this request again against the current timeline.")
                    }
                }
                .fixedSize()
                .disabled(model.history.isEmpty || model.busy || model.phase == .awaitingPrerequisites)
                .help("The last ten distinct requests for this profile.")
                Spacer(minLength: 0)
                if model.phase == .running {
                    Button("Cancel run", action: model.cancelRun)
                        .help("Cancel and wait for active work to stop. No timeline changes are applied; saved Library work remains.")
                }
                Button(model.failure == .staleRevision ? "Run again" : "Run", action: model.beginRun)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy || model.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Run against a fresh timeline snapshot. ⌘Return. Replaces the previous preview.")
                Button("Hide Wizard panel", systemImage: "xmark.circle", action: hide)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Hide the Wizard panel. Any active run continues. ⇧⌘W shows it again.")
            }
            HStack(alignment: .top, spacing: Theme.spaceS) {
                HStack(spacing: Theme.spaceXS) {
                    Text("Try:").font(.caption).foregroundStyle(.secondary)
                    Button("Supported requests", systemImage: "questionmark.circle") { showHelp.toggle() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("See all supported examples and how B-roll, tracks, and clip numbers work.")
                        .popover(isPresented: $showHelp) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: Theme.spaceM) {
                                    Text("Supported requests").font(.headline)
                                    Text(guidance).font(.callout).textSelection(.enabled)
                                    ForEach(model.examples, id: \.self) { example in
                                        Button(example) { model.request = example; showHelp = false }
                                            .buttonStyle(.link)
                                            .disabled(model.busy || model.phase == .awaitingPrerequisites)
                                            .help("Fill the request field with: \(example)")
                                    }
                                }
                                .padding(Theme.spaceL)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(width: 480, height: 360)
                        }
                }
                .padding(.top, Theme.spaceXS)
                FlowLayout(spacing: Theme.spaceS) {
                    ForEach(model.examples.prefix(4), id: \.self) { example in
                        Button { model.request = example } label: {
                            Text(example).lineLimit(1).truncationMode(.tail).frame(maxWidth: 190)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.busy || model.phase == .awaitingPrerequisites)
                        .help("Fill the request field with: \(example)")
                    }
                }
            }
        }
    }
}
