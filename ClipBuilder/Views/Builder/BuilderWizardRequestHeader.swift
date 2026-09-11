import SwiftUI

struct BuilderWizardRequestHeader: View {
    @Bindable var model: WizardSheetModel
    @State private var showHelp = false

    private let guidance = "B-roll chooses the first matching scene by ID; omit track to use the focused track. Clip numbers count visible clips on the track from left to right, including B-roll. ‘Cover all areas’ targets the selected B-roll clip."

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            Text("Builder Wizard").font(.headline)
            TextField("For example: " + (model.examples.first ?? "remove the selected clip"), text: $model.request, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .disabled(model.busy || model.phase == .awaitingPrerequisites)
                #if DEBUG
                .help("Enter an editing request. Times are timeline positions. Debug builds also accept JSON arrays of script steps.")
                #else
                .help("Enter an editing request. Times are timeline positions. Review the preview before applying.")
                #endif
            HStack(spacing: Theme.spaceM) {
                Picker("Provider", selection: $model.provider) {
                    ForEach(BuilderAgentProvider.allCases) { provider in
                        Text(provider.label).tag(provider).disabled(provider.disabledReason != nil)
                    }
                }
                .fixedSize()
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
                Spacer()
                if model.phase == .running {
                    Button("Cancel run", action: model.cancelRun)
                        .help("Cancel and wait for active work to stop. No timeline changes are applied; saved Library work remains.")
                }
                Button(model.failure == .staleRevision ? "Run again" : "Run", action: model.beginRun)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy || model.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Run against a fresh timeline snapshot. ⌘Return. Replaces the previous preview.")
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
                            Text(example).lineLimit(1).frame(maxWidth: 260)
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
