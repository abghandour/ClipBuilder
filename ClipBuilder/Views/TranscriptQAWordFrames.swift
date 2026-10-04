import SwiftUI

/// Visible word bounds in the Q&A transcript viewport's named coordinate space.
struct TranscriptQAWordFrames: PreferenceKey {
    nonisolated static var defaultValue: [Int: CGRect] { [:] }

    nonisolated static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
