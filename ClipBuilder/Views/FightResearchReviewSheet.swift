import SwiftUI

/// The job's saved research is the source for the existing editable story form.
struct FightResearchReviewSheet: View {
    let jobID: UUID
    let video: VideoRecord

    var body: some View {
        FightResearchSheet(video: video, reviewJobID: jobID)
    }
}
