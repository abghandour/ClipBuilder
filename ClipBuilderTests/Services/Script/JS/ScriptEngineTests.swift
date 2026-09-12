import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("JavaScript worker", .serialized, .timeLimit(.minutes(1)))
struct ScriptEngineTests {
    private func evaluate(_ source: String, seconds: Double = 10) async -> ScriptEngineResult {
        await ScriptEngine(seconds: seconds).evaluate(source: source, bootstrap: "__clipbuilderReturn=JSON.stringify;") { _, _ in
            Data("{\"value\":null}".utf8)
        }
    }

    @Test(arguments: [
        "while(true){}",
        "function f(){return f()} f();",
        "const retained=[];for(let i=0;;i++){retained[i%64]=new Array(16384).fill(i);}"
    ])
    func terminationGate(source: String) async {
        let start = ContinuousClock.now
        let result = await evaluate(source, seconds: 1)
        #expect(result.diagnostic?.code == "timeout")
        // The JavaScriptCore limit counts the worker's CPU time; under the parallel
        // suite one CPU-second can stretch to a few wall-seconds, so allow slack here.
        // mainActorRemainsResponsive keeps the strict responsiveness bound.
        #expect(start.duration(to: .now) < .seconds(5))
        let next = await evaluate("return 42;")
        #expect(next.diagnostic == nil)
        #expect(next.summary == Data("42".utf8))
    }

    @Test func mainActorRemainsResponsive() async throws {
        let engine = ScriptEngine(seconds: 3)
        let job = Task { await engine.evaluate(source: "while(true){}", bootstrap: "") { _, _ in Data() } }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        let ping = Task { @MainActor in ContinuousClock.now }
        let ran = await ping.value
        #expect(started.duration(to: ran) < .milliseconds(100))
        let result = await job.value
        #expect(result.diagnostic?.code == "timeout")
    }

    @Test func cancellationBeforeRegistrationAndExactlyOnceCompletion() async {
        let latch = ScriptCallLatch()
        latch.cancel()
        let job = Task { @MainActor in
            #expect(Task.isCancelled)
            latch.complete(Data("cancelled".utf8))
            #expect(!latch.complete(Data("late".utf8)))
        }
        latch.register(job)
        await job.value
        #expect(latch.signalCount == 1)
        let engine = ScriptEngine()
        engine.cancel()
        let result = await engine.evaluate(source: "while(true){}", bootstrap: "") { _, _ in
            Issue.record("Cancelled worker admitted a callback")
            return Data()
        }
        #expect(result.diagnostic?.code == "cancelled")
    }

    @Test func userSourceLineOffsets() async {
        let result = await evaluate("const x=1;\nthrow new Error('line two');")
        #expect(result.diagnostic?.line == 2)
        #expect(result.diagnostic?.code == "js_error")
        let syntax = await evaluate("return (;")
        #expect(syntax.diagnostic?.code == "syntax_error")
        #expect(syntax.diagnostic?.line == 1)
    }

    private func run(_ body: String, seconds: Double = 10) async throws -> ScriptRunModel {
        let session = ScriptFixtures.session()
        let header = try ScriptHeader.parse(ScriptHeaderTests.source())
        let run = ScriptRunModel(session: session, header: header, params: Data("{}".utf8), seconds: seconds)
        await run.run(source: body)
        return run
    }

    @Test func tolerateThrowBindingsAndRollback() async throws {
        let run = try await run("""
        builder.ops.add_text({text:"first"}, {bind:"t"});
        const rolled = builder.run([
          {op:"add_text",text:"rolled",bind:"t"},
          {command:{op:"remove_clip",clip:"not-an-id"}}
        ],{tolerate:true});
        if(rolled.completed || rolled.outcomes[1].status!=="refused") throw Error("projection");
        builder.ops.remove_overlay({overlay:"$t.overlay"});
        try { builder.ops.remove_clip({clip:"missing"}); throw Error("did not refuse"); }
        catch(e) { if(!e.code) throw e; }
        builder.ops.add_text({text:"last"}, {bind:"t"});
        """)
        #expect(run.diagnostic == nil)
        #expect(run.coordinator.tools.session.candidate?.textOverlays.map { $0.text } == ["last"])
        let uncaught = try await self.run("builder.ops.remove_clip({clip:'missing'});")
        #expect(uncaught.diagnostic != nil)
        #expect(uncaught.coordinator.tools.session.frozenCandidate == nil)
    }

    @Test func caughtTerminalStaysTerminal() async throws {
        let run = try await run("""
        try { console.log("x".repeat(70000)); } catch(e) {}
        try { builder.ops.add_text({text:"must not survive"}); } catch(e) {}
        """)
        #expect(run.diagnostic != nil)
        #expect(run.coordinator.tools.session.state == .failed)
        #expect(run.coordinator.tools.session.frozenCandidate == nil)
    }

    @Test(arguments: [
        "({x:undefined})", "[,1]", "({x:()=>1})", "({x:Symbol('x')})",
        "({x:1n})", "({x:Infinity})", "({id:9007199254740992})",
        "(()=>{const x={};x.x=x;return x})()", "new Date()",
        "({toJSON(){return {}}})", "({get x(){while(true){}}})",
        "new Proxy({}, {ownKeys(){while(true){}}})",
        "(()=>{let x={};for(let i=0;i<34;i++)x={x};return x})()"
    ])
    func adversarialMarshalling(expression: String) async throws {
        let run = try await run("builder.query(\(expression));", seconds: 0.2)
        #expect(run.diagnostic != nil)
        #expect(run.coordinator.tools.session.frozenCandidate == nil)
    }

    @Test func frozenParamsAndUndeclaredReads() async throws {
        for body in ["params.missing;", "params.n=2;", "delete params.n;"] {
            let session = ScriptFixtures.session()
            let header = try ScriptHeader.parse(ScriptHeaderTests.source(params: #"[{"name":"n","type":"number","default":1}]"#))
            let run = ScriptRunModel(session: session, header: header, params: Data("{\"n\":1}".utf8))
            await run.run(source: body)
            #expect(run.diagnostic != nil)
        }
    }

    @Test func staleReadRevokesAndNoLateEventAfterFreeze() async throws {
        let live = ScriptFixtures.model()
        let session = BuilderScriptSession(live: live, library: ScriptFixtures.library())
        let header = try ScriptHeader.parse(ScriptHeaderTests.source())
        let run = ScriptRunModel(session: session, header: header, params: Data("{}".utf8))
        live.document.textOverlays.append(TextOverlayItem(text: "Manual"))
        await run.run(source: "try { builder.summary(); } catch(e) {}")
        #expect(run.diagnostic != nil)
        #expect(session.frozenCandidate == nil)
        let good = try await self.run("builder.ops.add_text({text:'preview'});")
        let count = good.coordinator.events.count
        _ = await good.coordinator.call(name: "get_document_summary", arguments: [:])
        #expect(good.coordinator.events.count == count)
        #expect(good.coordinator.tools.session.state == .completed)
    }
}

extension ScriptEngineTests {
    @Test func bridgedCodeIsConfinedToNamedDedicatedThread() async {
        let engine = ScriptEngine(onWorkerBridge: {
            #expect(!Thread.isMainThread)
            #expect(Thread.current.name == ScriptEngine.threadName)
        })
        let result = await engine.evaluate(source: "__clipbuilderHost('probe','{}');", bootstrap: "") { _, _ in
            MainActor.assertIsolated()
            return Data("{\"value\":null}".utf8)
        }
        #expect(result.diagnostic == nil)
    }

    @Test func cancellationDuringPrerequisiteDrainsBeforeCompletion() async throws {
        let live = ScriptFixtures.model()
        let library = ScriptFixtures.library()
        let session = BuilderScriptSession(live: live, library: library)
        let video = try #require(library.videos.first)
        let header = try ScriptHeader.parse(ScriptHeaderTests.source())
        var entered = false
        var drained = false
        let run = ScriptRunModel(session: session, header: header, params: Data("{}".utf8),
            confirmed: [.ensureTranscript(video: video.id)], ensure: { _ in
                entered = true
                do { try await Task.sleep(for: .seconds(5)) } catch {}
                // Simulate an adapter with cleanup that must finish after cancellation.
                let cleanup = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(40))
                    drained = true
                }
                await cleanup.value
                return .init(outcomes: [.refused(code: "cancelled", reason: "Drained")],
                             completed: false, hasDocumentChanges: false)
            })
        let job = Task { await run.run(source: "builder.ops.ensure_transcript({video:\(video.id)});") }
        let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !entered, ContinuousClock.now < admissionDeadline, !Task.isCancelled { await Task.yield() }
        #expect(entered, "Prerequisite must enter before testing cancellation")
        run.cancel()
        await job.value
        #expect(drained)
        #expect(session.frozenCandidate == nil)
        #expect(run.diagnostic != nil)
        let count = run.coordinator.events.count
        _ = await run.coordinator.call(name: "get_document_summary", arguments: [:])
        #expect(run.coordinator.events.count == count)
        session.discard()
    }

    @Test func prerequisiteClockResumesRemainingAllowance() async throws {
        let session = ScriptFixtures.session()
        let header = try ScriptHeader.parse(ScriptHeaderTests.source())
        var drained = false
        let run = ScriptRunModel(session: session, header: header, params: Data("{}".utf8),
            confirmed: [.ensureTranscript(video: 1)], seconds: 0.2, ensure: { _ in
                try? await Task.sleep(for: .milliseconds(300))
                drained = true
                return .init(outcomes: [.unchanged(reason: "fixture")], completed: true, hasDocumentChanges: false)
            })
        await run.run(source: "builder.ops.ensure_transcript({video:1}); return 1;")
        #expect(drained)
        #expect(run.diagnostic == nil)
    }
}

extension ScriptEngineTests {
    @Test func duplicateFingerprintsReplayAndConflictsAreTerminal() throws {
        let session = ScriptFixtures.session()
        let coordinator = BuilderRunCoordinator(tools: BuilderTools(session: session, budget: BuilderRunBudget(.init())))
        let fingerprint = Data("request".utf8)
        let response = Data("response".utf8)
        #expect(try coordinator.cached(id: "1", fingerprint: fingerprint) == nil)
        coordinator.cache(id: "1", fingerprint: fingerprint, response: response)
        #expect(try coordinator.cached(id: "1", fingerprint: fingerprint) == response)
        #expect(coordinator.events.isEmpty)
        #expect(throws: (any Error).self) { try coordinator.cached(id: "1", fingerprint: Data("changed".utf8)) }
        #expect(coordinator.stopping)
        #expect(session.state == .failed)
    }

    @Test func failedPersistenceAndIdentitySwitchDuringAuditPreventApply() async throws {
        for changeIdentity in [false, true] {
            let live = ScriptFixtures.model()
            let session = BuilderScriptSession(live: live, library: ScriptFixtures.library())
            // A persistent timeline identity is needed for a run-record sink.
            let persistent = BuilderTimelineModel()
            persistent.loadTimeline(id: 1, document: live.document)
            persistent.onTimelineAutosave = { _, _ in }
            session.discard()
            let captured = BuilderScriptSession(live: persistent, library: ScriptFixtures.library())
            let header = try ScriptHeader.parse(ScriptHeaderTests.source())
            let run = ScriptRunModel(session: captured, header: header, params: Data("{}".utf8))
            var statuses: [BuilderRunStatus] = []
            await run.run(source: "builder.ops.add_text({text:'preview'});") { record in
                statuses.append(record.status)
                if changeIdentity { persistent.document.textOverlays.append(TextOverlayItem(text: "Manual")) }
                else { throw ScriptError.invalid("Audit unavailable.") }
            }
            #expect(run.diagnostic != nil)
            #expect(captured.frozenCandidate == nil)
            #expect(captured.state == .failed)
            if changeIdentity { #expect(statuses == [.completed, .failed]) }
            captured.discard()
        }
    }
}

extension ScriptEngineTests {
    @Test(arguments: [
        "builder.run([{command:{op:'add_text',text:'x'},text:'mixed'}]);",
        "builder.ops.add_text({text:'x',unknown:1});",
        "builder.ops.add_text({text:'x'},{unknown:true});",
        "builder.ops.add_text({text:'x'},{tolerate:'yes'});",
        "builder.selection=null;",
        "builder.ops={};",
        "builder.query({x:Symbol()});",
        "builder.query(Object.assign({},{[Symbol('key')]:1}));",
        "builder.query(new Proxy({}, {getPrototypeOf(){while(true){}}}));",
        "builder.query({get toJSON(){while(true){}}});",
        "console.log({get value(){while(true){}}});",
        "return 'x'.repeat(65537);",
        "builder.query({kind:'clips',extra:'x'.repeat(1048577)});"
    ])
    func structuralAndConversionLimits(source: String) async throws {
        let result = try await run(source, seconds: 0.2)
        #expect(result.diagnostic != nil)
        #expect(result.coordinator.tools.session.frozenCandidate == nil)
    }

    @Test func successfulRebindingRemovesEntireOldNamespace() async throws {
        let run = try await run("""
        const clip=builder.summary().rows.find(r=>r.lane==="video");
        builder.ops.split_clip_evenly({clip:clip.id,parts:2,precision:"ordinary"},{bind:"made"});
        builder.ops.add_text({text:"replacement"},{bind:"made"});
        try { builder.ops.remove_clip({clip:"$made.piece2"}); throw Error("stale member survived"); }
        catch(e) { if(!e.code) throw e; }
        builder.ops.remove_overlay({overlay:"$made"});
        """)
        #expect(run.diagnostic == nil)
        #expect(run.coordinator.tools.session.candidate?.textOverlays.isEmpty == true)
        #expect(run.coordinator.tools.session.candidate?.videoTrack.count == 2)
    }

    @Test func sourceAndParameterCaps() async throws {
        let oversized = await evaluate(String(repeating: " ", count: 256 * 1024 + 1))
        #expect(oversized.diagnostic?.code == "limit")
        let header = try ScriptHeader.parse(ScriptHeaderTests.source(params: #"[{"name":"text","type":"string"}]"#))
        let model = ScriptFixtures.model()
        let capture = ScriptCapture(model: model, library: ScriptFixtures.library())
        let params = try JSONEncoder().encode(["text": String(repeating: "x", count: 64 * 1024)])
        #expect(throws: (any Error).self) { try header.resolve(params, capture: capture) }
    }

    @Test func findRequiresOneValidReportAndCannotMutate() async throws {
        let header = try ScriptHeader.parse(ScriptHeaderTests.source(mode: "find"))
        let missing = ScriptRunModel(session: ScriptFixtures.session(), header: header, params: Data("{}".utf8))
        await missing.run(source: "builder.query({kind:'scenes'});")
        #expect(missing.diagnostic != nil)
        let valid = ScriptRunModel(session: ScriptFixtures.session(), header: header, params: Data("{}".utf8))
        await valid.run(source: "builder.report_scenes({scenes:[],summary:'No matches'});")
        #expect(valid.diagnostic == nil)
        #expect(valid.coordinator.tools.session.sceneReport?.scenes.isEmpty == true)
        let mutation = ScriptRunModel(session: ScriptFixtures.session(), header: header, params: Data("{}".utf8))
        await mutation.run(source: "builder.ops.add_text({text:'forbidden'});")
        #expect(mutation.diagnostic != nil)
    }
}
