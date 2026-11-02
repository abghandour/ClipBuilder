import SwiftUI

/// One row of the Sources table; the sort keys are plain values so the
/// header click sorts without touching the store.
nonisolated struct SourceRow: Identifiable, Sendable {
    var video: VideoRecord
    var id: Int64 { video.id }
    var filename: String { video.filename }
    var createdDate: Date { video.createdDate }
    var duration: Double { video.duration }
    var typeLabel: String { video.type?.label ?? "" }
    var language: String { video.language ?? "" }
}

/// The sortable Sources columns and the local, per-Mac record of the sort
/// the user chose ("created:desc,file:asc"); column order and visibility
/// are the table's own customization, stored next to it.
nonisolated enum SourcesTableSort {
    enum Column: String, CaseIterable, Sendable {
        case file, created, duration, type, lang

        var keyPath: PartialKeyPath<SourceRow> {
            switch self {
            case .file: \SourceRow.filename
            case .created: \SourceRow.createdDate
            case .duration: \SourceRow.duration
            case .type: \SourceRow.typeLabel
            case .lang: \SourceRow.language
            }
        }

        func comparator(ascending: Bool) -> KeyPathComparator<SourceRow> {
            let order: SortOrder = ascending ? .forward : .reverse
            switch self {
            case .file: return KeyPathComparator(\.filename, comparator: .localizedStandard, order: order)
            case .created: return KeyPathComparator(\.createdDate, order: order)
            case .duration: return KeyPathComparator(\.duration, order: order)
            case .type: return KeyPathComparator(\.typeLabel, order: order)
            case .lang: return KeyPathComparator(\.language, order: order)
            }
        }
    }

    static func encode(_ comparators: [KeyPathComparator<SourceRow>]) -> String {
        comparators.compactMap { comparator in
            Column.allCases.first { $0.keyPath == comparator.keyPath }
                .map { "\($0.rawValue):\(comparator.order == .forward ? "asc" : "desc")" }
        }.joined(separator: ",")
    }

    static func decode(_ text: String) -> [KeyPathComparator<SourceRow>] {
        text.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard let column = parts.first.flatMap(Column.init(rawValue:)) else { return nil }
            return column.comparator(ascending: parts.count < 2 || parts[1] != "desc")
        }
    }
}
