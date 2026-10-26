import SwiftUI

struct BuilderScriptsPanel: View {
    let model: WizardSheetModel
    @Binding var selectedTab: String
    var tools: BuilderScriptTools? = nil

    var body: some View {
        BuilderScriptsSection(wizard: model, model: model.scriptLibrary,
                              showWizard: { selectedTab = "wizard" }, tools: tools)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .controlSize(.small)
            .padding(Theme.spaceS)
    }
}
