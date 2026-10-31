import SwiftUI

/// Display-only structure for learned text. The stored text, the document
/// that is published, and every prompt keep the raw string; this only decides
/// how the AI Lessons page draws it.
nonisolated enum LearnedRichText {
    enum Block: Equatable, Sendable {
        case heading(String)
        /// A `#`-style markdown heading; level 1 is the document title.
        case titled(String, level: Int)
        /// A pipe table; the first row is the header. Separator rows are dropped.
        case table([[String]])
        case bullet(String, level: Int)
        case numbered(String, number: String)
        case paragraph(String)
    }

    static func blocks(_ text: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !table.isEmpty {
                result.append(.table(table))
                table = []
            }
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if let row = tableRow(line) {
                if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
                if let row { table.append(row) }
                continue
            } else if !table.isEmpty {
                result.append(.table(table))
                table = []
            }
            if let (level, title) = markdownHeading(line) {
                flush()
                result.append(.titled(title, level: level))
                continue
            }
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let bullet = bulletText(line) {
                flush()
                result.append(.bullet(bullet, level: min(indent / 2, 3)))
            } else if let (number, body) = numberedText(line) {
                flush()
                result.append(.numbered(body, number: number))
            } else if isHeading(line) {
                flush()
                result.append(.heading(headingTitle(line)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    /// Bold, italic and code spans when the text happens to use them; plain otherwise.
    static func inline(_ text: String) -> AttributedString {
        guard text.contains("*") || text.contains("_") || text.contains("`") else { return AttributedString(text) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// `# Title` through `### Title`. Returns nil for a bare `#`.
    private static func markdownHeading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 3, line.dropFirst(hashes.count).first == " " else { return nil }
        let title = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (hashes.count, title)
    }

    /// A `| a | b |` row as its cells; `.some(nil)` for a `|---|---|` separator row.
    private static func tableRow(_ line: String) -> [String]?? {
        guard line.hasPrefix("|"), line.count >= 2 else { return nil }
        var inner = line.dropFirst()
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        let cells = inner.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let separator = cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
        return separator ? .some(nil) : .some(cells)
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "• ", "* ", "– ", "— "] where line.hasPrefix(marker) {
            let body = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        return nil
    }

    private static func numberedText(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        let body = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, rest.dropFirst().first == " " else { return nil }
        return (String(digits), body)
    }

    /// "HOOK:", "DURATION & PACING:" and short title lines ending in a colon,
    /// or an all-caps label of two or more words with no sentence punctuation.
    /// A lone acronym ("MMA") or a shouted sentence ("KEEP THE KO.") is text.
    private static func isHeading(_ line: String) -> Bool {
        guard line.count <= 60, !line.contains(". ") else { return false }
        let letters = line.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        let uppercase = letters.allSatisfy(\.isUppercase)
        let words = line.split(separator: " ").count
        if line.hasSuffix(":") { return uppercase || words <= 5 }
        guard uppercase, words >= 2, let last = line.last else { return false }
        return !".!?,;".contains(last)
    }

    /// Case is kept as written: the model wrote it, and recasing changes meaning.
    private static func headingTitle(_ line: String) -> String {
        line.hasSuffix(":") ? String(line.dropLast()) : line
    }
}

/// Draws one learned text as headings, bullets and paragraphs.
struct LearnedRichTextView: View {
    let text: String

    var body: some View {
        let blocks = LearnedRichText.blocks(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let title):
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, index == 0 ? 0 : 6)
                case .titled(let title, let level):
                    Text(LearnedRichText.inline(title))
                        .font(level == 1 ? .title2.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, index == 0 ? 0 : level == 1 ? 10 : 6)
                case .table(let rows):
                    LearnedTableView(rows: rows)
                case .bullet(let body, let level):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(LearnedRichText.inline(body))
                    }
                    .padding(.leading, CGFloat(level) * 14)
                case .numbered(let body, let number):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                        Text(LearnedRichText.inline(body))
                    }
                case .paragraph(let body):
                    Text(LearnedRichText.inline(body))
                }
            }
        }
        .font(.body)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A markdown pipe table as a grid: header row bold, cells left-aligned.
private struct LearnedTableView: View {
    let rows: [[String]]

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(LearnedRichText.inline(column < row.count ? row[column] : ""))
                            .font(index == 0 ? .callout.weight(.semibold) : .callout)
                            .gridColumnAlignment(.leading)
                    }
                }
                if index == 0 { Divider() }
            }
        }
        .padding(.vertical, 2)
    }
}
