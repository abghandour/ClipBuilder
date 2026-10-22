import Foundation

/// A wizard pauses at the root review without keeping synthesis work in a sheet.
@MainActor
final class DubReviewCoordinator {
    weak var store: AppStore?
    private var pending: [UUID: CheckedContinuation<DubPreparation.Prepared, Error>] = [:]

    func review(_ prepared: DubPreparation.Prepared, projectID: Int64?, profileName: String) async throws -> DubPreparation.Prepared {
        try Task.checkCancellation()
        guard let store, store.activeProfile.profileName == profileName else { throw CancellationError() }
        let id = UUID()
        let generation = store.profileGeneration
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                let review = DubReview(prepared: prepared, target: .render(id), profileGeneration: generation)
                let project = store.projects.first { $0.id == projectID }
                store.jobs.start(.dub, title: "Review dub", project: project, profileGeneration: generation) { _ in
                    .dub(review)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    func isPending(_ id: UUID) -> Bool { pending[id] != nil }

    func apply(_ id: UUID, prepared: DubPreparation.Prepared) {
        pending.removeValue(forKey: id)?.resume(returning: prepared)
    }

    func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
        guard let store else { return }
        for job in store.jobs.items {
            if case .dub(let review) = job.result, review.target == .render(id) { store.jobs.dismiss(job.id) }
        }
    }
}
