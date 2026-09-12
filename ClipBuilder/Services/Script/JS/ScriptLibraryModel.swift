import Foundation
import Observation

@MainActor @Observable
final class ScriptLibraryModel {
    struct Choice: Identifiable, Equatable {
        var id: String
        var label: String
    }
    var scripts: [BuilderScriptRecord] = []
    var selectedID: UUID?
    var source = ""
    var values: [String: String] = [:]
    private(set) var header: ScriptHeader?
    private(set) var capture: ScriptCapture?
    private(set) var diagnostic: ScriptDiagnostic?
    private(set) var message = ""
    private(set) var busy = false
    private(set) var editingID: UUID?
    private(set) var origin: BuilderScriptRecord.Origin = .human
    @ObservationIgnored private let database: Database?
    @ObservationIgnored private var generation = 0

    init(database: Database?) { self.database = database }

    var selected: BuilderScriptRecord? { scripts.first { $0.id == selectedID } }

    func refresh() async {
        do { scripts = try await database?.fetchBuilderScripts() ?? [] }
        catch { message = error.localizedDescription }
    }

    func open(_ record: BuilderScriptRecord?, capture: ScriptCapture) {
        generation += 1
        self.capture = capture; editingID = record?.id; origin = record?.origin ?? .human
        source = record?.source ?? Self.newSource
        parse()
    }

    func openAuthored(_ submission: ScriptAuthorSubmission, capture: ScriptCapture) throws {
        open(nil, capture: capture)
        source = submission.source
        origin = .ai
        parse()
        let samples = try JSONDecoder().decode([String: ScriptValue].self, from: submission.sampleParams)
        for (name, value) in samples {
            switch value {
            case .string(let text): values[name] = text
            case .number(let number): values[name] = String(number)
            case .bool(let flag): values[name] = flag ? "true" : "false"
            default: break
            }
        }
    }

    func parse() {
        generation += 1
        diagnostic = nil; message = ""; values = [:]
        do {
            header = try ScriptHeader.parse(source)
            for p in header?.params ?? [] {
                let value = p.defaultValue ?? (p.type == "time" ? capture.map { .number($0.playhead) } : nil)
                switch value {
                case .string(let text): values[p.name] = text
                case .number(let number):
                    values[p.name] = number.isFinite && abs(number) <= 9_007_199_254_740_991 && number.rounded() == number
                        ? String(Int64(number)) : String(number)
                case .bool(let flag): values[p.name] = flag ? "true" : "false"
                default: break
                }
            }
        } catch { header = nil; fail(error) }
    }

    func invalidate() {
        generation += 1
        capture = nil; values = [:]
        message = "Timeline identity or revision changed. Close and reopen the script to capture fresh choices."
    }

    func invalidate(ifChanged model: BuilderTimelineModel) {
        if let capture, !capture.matches(model) { invalidate() }
    }

    func choices(for parameter: ScriptHeader.Parameter) -> [Choice] {
        guard let capture else { return [] }
        switch parameter.type {
        case "clip":
            return capture.document.videoTrack.enumerated().map { index, clip in
                .init(id: clip.uid.uuidString, label: "Clip \(index + 1) · \(clip.uid.uuidString.prefix(8))")
            }
        case "scene":
            return capture.library.scenes.map { .init(id: String($0.id), label: "Scene \($0.id) · \($0.videoFilename)") }
        case "track":
            return (0..<capture.document.trackCount).map { .init(id: String($0), label: Self.trackLabel($0)) }
        case "choice": return (parameter.choices ?? []).map { .init(id: $0, label: $0) }
        case "boolean": return [.init(id: "true", label: "Yes"), .init(id: "false", label: "No")]
        default: return []
        }
    }

    static func trackLabel(_ index: Int) -> String {
        let labels = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
        return "Track " + (labels.indices.contains(index) ? labels[index] : String(index + 1))
    }

    func parameters() throws -> Data {
        guard let capture else { throw ScriptError.invalid("Capture expired. Reopen the script.") }
        let parsed = try ScriptHeader.parse(source)
        var fields: [String: ScriptValue] = [:]
        for p in parsed.params {
            guard let raw = values[p.name] else { continue }
            switch p.type {
            case "number", "scene", "track", "time":
                guard let value = Double(raw), value.isFinite else { throw ScriptError.invalid("Enter a finite number for " + p.name) }
                fields[p.name] = .number(value)
            case "boolean":
                guard raw == "true" || raw == "false" else { throw ScriptError.invalid("Choose Yes or No for " + p.name) }
                fields[p.name] = .bool(raw == "true")
            default: fields[p.name] = .string(raw)
            }
        }
        return try parsed.resolve(JSONEncoder().encode(fields), capture: capture).0
    }

    func validate() async {
        guard let capture, !busy else { return }
        busy = true
        let token = generation
        defer { busy = false }
        do {
            let params = try parameters()
            let result = await ScriptValidation.validate(source: source, sampleParams: params, capture: capture)
            guard token == generation else { return }
            diagnostic = result.diagnostic; message = result.message
        } catch { fail(error) }
    }

    @discardableResult
    func save() async throws -> BuilderScriptRecord {
        _ = try ScriptHeader.parse(source)
        guard let database else { throw ScriptError.invalid("Profile database is unavailable.") }
        let record = try await database.saveBuilderScript(source: source, id: editingID ?? UUID(), origin: origin)
        editingID = record.id; selectedID = record.id
        await refresh()
        message = "Saved."
        return record
    }

    func duplicate(_ record: BuilderScriptRecord) async {
        do { selectedID = try await database?.duplicateBuilderScript(id: record.id).id; await refresh() }
        catch { fail(error) }
    }

    func delete(_ record: BuilderScriptRecord) async {
        do { try await database?.deleteBuilderScript(id: record.id); await refresh() }
        catch { fail(error) }
    }

    func importFile(_ url: URL) async {
        do { selectedID = try await database?.importBuilderScript(from: url).id; await refresh() }
        catch { fail(error) }
    }

    func export(_ record: BuilderScriptRecord, to url: URL) async {
        do { try await database?.exportBuilderScript(id: record.id, to: url) }
        catch { fail(error) }
    }

    func fail(_ error: any Error) {
        diagnostic = ScriptHeader.diagnostic(source: source, error: error)
        message = error.localizedDescription
    }

    static let newSource = """
    /** clipbuilder-script
    {"name":"New script","description":"Describe this script.","mode":"edit","params":[],"requires":[]}
    */
    // Query captured state and preview edits with builder.ops.
    return {summary: "No edits yet."};
    """
}
