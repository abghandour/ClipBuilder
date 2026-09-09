import Foundation

nonisolated enum MetadataFileNamer {
    /// The rename pipeline preserves the existing extension; return the stem.
    static func stem(people: [String], hasResearch: Bool, fightDate: String?) -> String? {
        let names = people.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let people = names.joined(separator: hasResearch ? " vs " : " & ")
        guard let fightDate, let date = normalizedDate(fightDate) else { return people }
        return "\(people) - \(date)"
    }
    static func normalizedDate(_ text: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "MMMM d, yyyy", "MMM d, yyyy", "MMMM d yyyy", "MMM d yyyy", "MM/dd/yyyy", "MM/dd/yy", "d MMMM yyyy", "d MMM yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            }
        }
        return nil
    }
}
