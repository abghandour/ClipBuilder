import SwiftUI

struct ProfileStarterReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let provenance: AIProvenance?
    @State private var rubric: String
    @State private var houseStyle: String
    @State private var categories: [TasteCategory]
    @State private var applyRubric = true
    @State private var applyHouseStyle = true
    @State private var applyCategories = true

    init(jobID: UUID, result: ProfileStarter.Result, provenance: AIProvenance?) {
        self.jobID = jobID
        self.provenance = provenance
        _rubric = State(initialValue: result.rubric)
        _houseStyle = State(initialValue: result.houseStyle)
        _categories = State(initialValue: result.categories)
    }

    var body: some View {
        review
            .frame(minWidth: 540, idealWidth: 580, minHeight: 380, idealHeight: 520)
            .modalCloseButton { dismiss() }
    }

    private var review: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("Review the generated style")
                        .font(.headline)
                    if let provenance {
                        AIInfoButton(provenance: provenance, style: .full, role: "Written by")
                    }
                }
                Text("Edit anything, uncheck what you don't want written, then Apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(store.activeProfile.tasteRubric.isEmpty
                           ? "Taste rubric"
                           : "Taste rubric (replaces the current one)", isOn: $applyRubric)
                        .font(.callout.bold())
                    TextEditor(text: $rubric)
                        .font(.callout)
                        .frame(minHeight: 90)
                        .disabled(!applyRubric)

                    Toggle(store.activeProfile.houseStyle.isEmpty
                           ? "House style"
                           : "House style (replaces the current one)", isOn: $applyHouseStyle)
                        .font(.callout.bold())
                    TextEditor(text: $houseStyle)
                        .font(.callout)
                        .frame(minHeight: 90)
                        .disabled(!applyHouseStyle)

                    if !categories.isEmpty {
                        Toggle("Video-type categories (\(categories.map(\.label).joined(separator: ", "))) — added alongside existing ones",
                               isOn: $applyCategories)
                            .font(.callout.bold())
                        ForEach(categories) { category in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.label)
                                    .font(.caption.bold())
                                Text(category.rubric)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply to Profile") {
                    store.applyProfileStarter(
                        ProfileStarter.Result(rubric: rubric, houseStyle: houseStyle,
                                              categories: categories),
                        rubric: applyRubric, houseStyle: applyHouseStyle,
                        categories: applyCategories, provenance: provenance)
                    store.jobs.markReviewed(jobID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!applyRubric && !applyHouseStyle && !applyCategories)
            }
            .padding()
        }
    }
}
