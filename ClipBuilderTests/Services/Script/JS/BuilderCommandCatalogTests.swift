import Foundation
import MCP
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Shared command catalog")
struct BuilderCommandCatalogTests {
    @Test func previousSchemaIsByteIdenticalForEveryOperation() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(BuilderCommandCatalog.commandSchema) == encoder.encode(LegacyBuilderSchema.commandSchema))
        #expect(try encoder.encode(BuilderCommandCatalog.querySchema) == encoder.encode(LegacyBuilderSchema.querySchema))
        let legacy = try #require(LegacyBuilderSchema.commandSchema.objectValue?["oneOf"]?.arrayValue)
        #expect(legacy.count == BuilderCommandCatalog.operations.count)
        for schema in legacy {
            let op = try #require(schema.objectValue?["properties"]?.objectValue?["op"]?.objectValue?["const"]?.stringValue)
            let generated = try #require(BuilderCommandCatalog.operations[op])
            #expect(try encoder.encode(generated) == encoder.encode(schema))
            #expect(BuilderCommandCatalog.referenceText.contains(op))
        }
    }

    @Test func allOutcomeProjections() throws {
        let values: [CommandOutcome] = [
            .applied(actualValues: .object(["nullable": .null]), createdIDs: ["clip": "UUID"], warnings: ["warning"]),
            .unchanged(reason: "same"), .refused(code: "unknown_id", reason: "missing")
        ]
        for outcome in values {
            let projected = ScriptBridge.project(outcome)
            guard case .object(let fields) = projected else { Issue.record("Expected object"); continue }
            switch outcome {
            case .applied(let actual, let ids, let warnings):
                #expect(fields["status"] == .string("applied"))
                #expect(fields["actualValues"] == actual)
                #expect(fields["createdIDs"] == .object(ids.mapValues(ScriptValue.string)))
                #expect(fields["warnings"] == .array(warnings.map(ScriptValue.string)))
            case .unchanged(let reason): #expect(fields == ["status": .string("unchanged"), "reason": .string(reason)])
            case .refused(let code, let reason):
                #expect(fields == ["status": .string("refused"), "code": .string(code), "reason": .string(reason)])
            }
        }
    }
}

extension BuilderCommandCatalogTests {
    @Test func everyOperationLowersWireFlatAndWrapperIdentically() async throws {
        let session = ScriptFixtures.session()
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()),
            confirmedPrerequisites: [.ensureTranscript(video: 1), .ensurePeople(video: 1), .ensureAnalysis(video: 1)],
            ensure: { _ in .init(outcomes: [], completed: true, hasDocumentChanges: false) })
        let bootstrap = try ScriptBridge.bootstrap(params: Data("{}".utf8), name: "Lowering", mode: "edit", tools: tools)
        let encoder = JSONEncoder()
        var calls: [(String, Data)] = []
        var source = ""
        for (op, schema) in BuilderCommandCatalog.operations.sorted(by: { $0.key < $1.key }) {
            let properties = try #require(schema.objectValue?["properties"]?.objectValue)
            let required = try #require(schema.objectValue?["required"]?.arrayValue)
            var args: [String: Value] = [:]
            for key in required.compactMap({ $0.stringValue }) where key != "op" {
                args[key] = sample(properties[key] ?? .null)
            }
            let arguments = String(decoding: try encoder.encode(args), as: UTF8.self)
            let command = String(decoding: try encoder.encode(args.merging(["op": .string(op)]) { old, _ in old }), as: UTF8.self)
            source += "builder.run([{command:\(command)}]);\nbuilder.run([\(command)]);\nbuilder.ops.\(op)(\(arguments));\n"
        }
        for op in ["ensure_transcript", "ensure_people", "ensure_analysis"] { source += "builder.ops.\(op)({video:1});\n" }
        source += "builder.query({kind:'clips'});builder.summary();"
        let result = await ScriptEngine().evaluate(source: source, bootstrap: bootstrap) { name, data in
            calls.append((name, data))
            return Data(#"{"value":{"outcomes":[],"completed":true,"hasDocumentChanges":false}}"#.utf8)
        }
        #expect(result.diagnostic == nil)
        #expect(calls.count == BuilderCommandCatalog.operations.count * 3 + 5)
        for index in stride(from: 0, to: BuilderCommandCatalog.operations.count * 3, by: 3) {
            let wire = try JSONDecoder().decode(ScriptValue.self, from: calls[index].1)
            let flat = try JSONDecoder().decode(ScriptValue.self, from: calls[index + 1].1)
            let wrapper = try JSONDecoder().decode(ScriptValue.self, from: calls[index + 2].1)
            #expect(wire == flat && wire == wrapper)
            #expect(calls[index].0 == "run_script")
        }
        #expect(calls.suffix(5).map { $0.0 } == ["ensure_transcript", "ensure_people", "ensure_analysis", "query", "get_document_summary"])
    }

    private func sample(_ schema: Value) -> Value {
        let fields = schema.objectValue ?? [:]
        if let value = fields["const"] { return value }
        if let value = fields["enum"]?.arrayValue?.first { return value }
        if let value = fields["oneOf"]?.arrayValue?.first { return sample(value) }
        switch fields["type"]?.stringValue {
        case "number", "integer": return fields["minimum"] ?? .int(0)
        case "boolean": return .bool(false)
        case "array": return .array([])
        case "object":
            let properties = fields["properties"]?.objectValue ?? [:]
            let keys = fields["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            return .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, sample(properties[$0] ?? .null)) }))
        default: return .string("fixture")
        }
    }
}
