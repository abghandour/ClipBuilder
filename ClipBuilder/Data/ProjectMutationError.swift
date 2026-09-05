import Foundation

nonisolated enum ProjectMutationError: LocalizedError, Equatable {
    case homeIsPermanent
    case destinationMustBeHome

    var errorDescription: String? {
        switch self {
        case .homeIsPermanent:
            "Home is permanent and cannot be renamed, archived, or deleted."
        case .destinationMustBeHome:
            "Timelines from a deleted project can only be moved to Home."
        }
    }
}
