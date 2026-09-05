import SwiftUI

struct ProposedCutsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: ProposedCutReviewRequest

    @State private var plan: WizardPlan
    @State private var rejected: Set<Int>

    init(request: ProposedCutReviewRequest) {
        self.request = request
        _plan = State(initialValue: request.plan)
        _rejected = State(initialValue: [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Proposed Cuts").font(.headline)
                    Text("Accept, reject, or trim each cut before any rendering starts.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: dismiss.callAsFunction)
                Button("Edit Accepted Cuts in Builder", action: editInBuilder)
                    .disabled(acceptedCount == 0)
                Button("Render Accepted Cuts", action: render)
                    .buttonStyle(.borderedProminent)
                    .disabled(acceptedCount == 0)
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(plan.clips.indices, id: \.self) { index in
                        cutRow(index)
                    }
                }
                .padding()
            }
        }
        .frame(width: 820, height: 680)
    }

    private var acceptedCount: Int { plan.clips.count - rejected.count }

    private func cutRow(_ index: Int) -> some View {
        let clip = plan.clips[index]
        let scene = request.sceneMap[clip.sceneID]
        let isRejected = rejected.contains(index)
        return HStack(alignment: .top, spacing: 12) {
            if let scene {
                VideoThumbnail(
                    url: scene.videoURL,
                    time: (clip.start + clip.end) / 2,
                    cornerRadius: 8
                )
                .frame(width: 180, height: 102)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cut \(index + 1)").bold()
                    Text(scene?.videoFilename ?? "Missing source")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle(
                        "Include",
                        isOn: Binding(
                            get: { !rejected.contains(index) },
                            set: { include in
                                if include { rejected.remove(index) } else { rejected.insert(index) }
                            })
                    )
                    .toggleStyle(.switch)
                }
                Text(clip.reason ?? "Planner did not provide a reason.")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("In", value: $plan.clips[index].start, format: .number)
                    TextField("Out", value: $plan.clips[index].end, format: .number)
                    Text("\((clip.end - clip.start).formatted(.number.precision(.fractionLength(1))))s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .disabled(isRejected)
            }
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .opacity(isRejected ? 0.55 : 1)
    }

    private func render() {
        let approved = approvedPlan()
        store.renderApprovedCuts(approved, options: request.options)
        dismiss()
    }

    private func editInBuilder() {
        store.openReviewedPlanInBuilder(approvedPlan(), request: request)
        dismiss()
    }

    private func approvedPlan() -> WizardPlan {
        var approved = plan
        approved.clips = plan.clips.enumerated().compactMap { index, clip in
            guard !rejected.contains(index), let scene = request.sceneMap[clip.sceneID] else { return nil }
            var clip = clip
            clip.start = min(scene.endTime, max(scene.startTime, clip.start))
            clip.end = min(scene.endTime, max(clip.start + 0.5, clip.end))
            return clip.end > clip.start ? clip : nil
        }
        approved.transitions = Array(plan.transitions.prefix(max(0, approved.clips.count - 1)))
        while approved.transitions.count < max(0, approved.clips.count - 1) {
            approved.transitions.append("cut")
        }
        return approved
    }
}
