import Foundation

nonisolated enum WizardRequestParser {
    struct Result: Sendable {
        var request: ParsedWizardRequest
        var confident: Bool
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(LocalTextMatcher.tokens(lhs).joined(separator: " "))
        let b = Array(LocalTextMatcher.tokens(rhs).joined(separator: " "))
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1]
            for (j, y) in b.enumerated() {
                row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = row
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    static func parse(_ description: String, tags: [String], templates: [String]) -> Result {
        var request = ParsedWizardRequest()
        var residual = description
        func consume(_ pattern: String, action: (NSTextCheckingResult, NSString) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            let source = residual as NSString
            let matches = regex.matches(in: residual, range: NSRange(location: 0, length: source.length))
            for match in matches { action(match, source) }
            for match in matches.reversed() {
                if let range = Range(match.range, in: residual) { residual.replaceSubrange(range, with: " ") }
            }
        }
        consume(#"(?:caption|title|text|overlay|saying|that says|legenda|titulo|título|texto|dizendo)\s*[:=]?\s*["“‘']([^"”’']+)["”’']"#) { match, source in
            if request.overlayText == nil { request.overlayText = source.substring(with: match.range(at: 1)) }
        }
        let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        let portuguese = ["um", "dois", "tres", "quatro", "cinco", "seis", "sete", "oito", "nove", "dez", "onze", "doze", "treze", "catorze", "quinze", "dezesseis", "dezessete", "dezoito", "dezenove", "vinte"]
        consume(#"\b(\d{1,3}):([0-5]\d)\b"#) { match, source in
            let seconds = (Int(source.substring(with: match.range(at: 1))) ?? 0) * 60 + (Int(source.substring(with: match.range(at: 2))) ?? 0)
            request.targetDurationSeconds = min(180, max(3, seconds))
        }
        let words = (numbers + portuguese + ["uma", "três"]).joined(separator: "|")
        consume("\\b(\\d+|" + words + ")[-\\s]*(seconds?|sec|s|minutes?|min|m|segundos?|minutos?)\\b") { match, source in
            let token = LocalTextMatcher.tokens(source.substring(with: match.range(at: 1))).joined()
            let value = Int(token) ?? numbers.firstIndex(of: token).map { $0 + 1 } ?? portuguese.firstIndex(of: token).map { $0 + 1 } ?? 1
            let unit = source.substring(with: match.range(at: 2)).lowercased()
            request.targetDurationSeconds = min(180, max(3, value * (unit.hasPrefix("m") ? 60 : 1)))
        }
        consume(#"\b(?:no music|without music|sem m[uú]sica)\b"#) { _, _ in request.useMusic = false }
        consume(#"\b(?:music|m[uú]sica)\b"#) { _, _ in if request.useMusic == nil { request.useMusic = true } }
        consume(#"\b(?:subtitles|closed captions|spoken captions|legendas)\b"#) { _, _ in request.addCaptions = true }
        consume(#"\b(?:on-screen text|overlay|texto na tela)\b"#) { _, _ in request.enableTextOverlays = true }
        let normalized = LocalTextMatcher.tokens(residual)
        for template in templates {
            let count = LocalTextMatcher.tokens(template).count
            guard count > 0, normalized.count >= count else { continue }
            for start in 0...(normalized.count - count) {
                let phrase = normalized[start..<(start + count)].joined(separator: " ")
                if similarity(phrase, template) >= 0.8 {
                    request.overlayTemplate = template
                    consume(NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: " ", with: "[-\\s]+")) { _, _ in }
                    break
                }
            }
        }
        let synonyms = ["luta": "fight", "lutas": "fight", "treino": "training", "treinamento": "training", "entrevista": "interview", "multidao": "crowd"]
        var content = Set(LocalTextMatcher.tokens(residual))
        for (word, tag) in synonyms where content.contains(word) {
            content.insert(tag)
            consume("\\b" + word + "\\b") { _, _ in }
        }
        for tag in tags {
            let words = LocalTextMatcher.tokens(tag)
            if !words.isEmpty && (words.allSatisfy(content.contains) || (content.contains("fight") && words.contains("fight"))) {
                request.contentTags.append(tag)
                consume(NSRegularExpression.escapedPattern(for: tag).replacingOccurrences(of: "-", with: "[-\\s]+")) { _, _ in }
            }
        }
        if request.overlayText != nil || request.overlayTemplate != nil { request.enableTextOverlays = true }
        request.residualInstructions = residual.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let structured = request.targetDurationSeconds != nil || request.overlayText != nil || request.overlayTemplate != nil || !request.contentTags.isEmpty || request.addCaptions != nil || request.useMusic != nil || request.enableTextOverlays != nil
        return Result(request: request, confident: structured && LocalTextMatcher.tokens(request.residualInstructions).count < 8)
    }

    static func merge(_ model: ParsedWizardRequest, local: ParsedWizardRequest) -> ParsedWizardRequest {
        var result = model
        result.targetDurationSeconds = result.targetDurationSeconds ?? local.targetDurationSeconds
        result.overlayText = result.overlayText ?? local.overlayText
        result.overlayTemplate = result.overlayTemplate ?? local.overlayTemplate
        result.enableTextOverlays = result.enableTextOverlays ?? local.enableTextOverlays
        result.addCaptions = result.addCaptions ?? local.addCaptions
        result.useMusic = result.useMusic ?? local.useMusic
        if result.contentTags.isEmpty { result.contentTags = local.contentTags }
        return result
    }
}
