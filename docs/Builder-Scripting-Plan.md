# Builder scripting (JavaScript)

Status: revision 2 (September 11, 2026). Implementation plan checked against HEAD `3a2a7c6`; resolves review findings #1–12. New components below are planned, not present at HEAD. Recovery follows `462e7d4`.

## Goal

Humans and the AI Wizard author reusable, parameterized JavaScript for Builder / Wizard. Scripts query captured Library/timeline state, execute existing typed commands and disclosed prerequisites, then present a complete transient diff for manual snapshot Apply with one undo registration. Save scripts per profile.

## Non-goals

No new mutation vocabulary, other screens, script-accessible filesystem/network/shell/AI, DOM, timers, module loading, Apply/Revert or identity switching. No retained VM state between runs. Prerequisite Library effects are durable; scripts are not pure functions.

## D1. Engine and sandbox

`ScriptEngine` in `Services/Script/JS/` owns a dedicated `Thread` per run, never GCD or the cooperative pool, and one fresh `JSVirtualMachine` plus `JSContext`. Create, use and destroy every JSValue/context/VM on that worker, including exceptions and conversion temporaries. Evaluate user source inside a synchronous function wrapper so top-level return works.

Bound evaluation with exported `JSContextGroupSetExecutionTimeLimit`; declare its C prototype and callback typedef locally from [JSContextRefPrivate.h](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContextRefPrivate.h). This Developer ID app deliberately uses private API, not an App Store/public-API contract. Install before any evaluation; callback returns true to terminate. Use short execution slices to inspect a synchronized cancellation/deadline state; only return false while still admitted. The C callback touches neither MainActor nor JS objects. Verify symbol/ABI availability on supported macOS; unavailable termination disables execution.

A monotonic host wall deadline defaults to 10 s, hard maximum 60 s, including conversion and ordinary bridge waits. Its watchdog trips the cancel flag; every bridged call checks that flag before admission and after completion. JSC interruption handles call-free loops. D3 excludes prerequisite adapter time. Never abandon active evaluation or release its context underneath it.

There is no public heap cap. Bound UTF-8 source to 256 KiB, params to 64 KiB, per-call arguments/results to 1 MiB, and console log to 64 KiB. Tighter tool/list limits still apply. Allocation can exhaust process memory before interruption: residual risk remains, not a sandbox memory guarantee.

**S1 termination gate:** `while(true){}`, deep recursion and an allocation loop each stop within the configured limit (reserve measured interruption latency inside that limit); after each, another script succeeds in the same process. Test cancellation and supported macOS builds; failure blocks S1.

## D2. The API a script sees

Install immutable `builder`, `params`, bounded `console.log/warn/error`, and read-only `script` metadata. Extract private `BuilderTools.commandSchema` into shared `BuilderCommandCatalog`, generating MCP schemas, JS wrappers and reference documentation; the strict decoder remains authoritative.

```js
// With D4's header and confirmed concrete video target:
builder.ops.ensure_transcript({ video: params.video });
const sel = builder.selection;
if (!sel || sel.kind !== "clip") throw new Error("Select a clip");
const r = builder.run([
  { op: "split_clip_evenly", clip: sel.id, parts: params.parts,
    precision: "speech", bind: "pieces" },
  { command: { op: "set_clip_captions",
               clip: "$pieces.piece1", captions: "none" } }
]);
console.log("done", r.outcomes.length);
return { summary: `Split into ${params.parts} parts` };
```

Test this lowering/projection table over every catalog entry:

| JS input / Swift result | Wire / JS output |
| --- | --- |
| `run([{command:{op,…},bind?}])` | `run_script({steps:[…]})`, unchanged wire step |
| `run([{op,…,bind?}])` | Move op/arguments into `command`; retain `bind` outside |
| `ops.<op>(args)` | One-step `run`; extract optional `bind`; identical result envelope |
| `ops.query({query:q})` | Query command inside one list; no collision with `builder.query` |
| `ops.ensure_transcript/ensure_people/ensure_analysis({video})` | Separate disclosed ensure tool, never smuggled into a list |
| `query(q)` / `summary(page?)` | `query({query:q})` / `get_document_summary({offset,limit})` |
| `.applied(actualValues,createdIDs,warnings)` | `{status:"applied",actualValues,createdIDs,warnings}` |
| `.unchanged(reason)` | `{status:"unchanged",reason}` |
| `.refused(code,reason)` | `{status:"refused",code,reason}` |

Reject mixed flat/wire fields and unknown keys. Preserve `{outcomes,completed,hasDocumentChanges}` around projected outcomes; do not expose synthesized enum Codable. Refusals throw worker-created JS `Error` with `code` and `reason`, unless `run(steps,{tolerate:true})` (also supported as wrapper options). Typed Swift failures retain their codes; map `ScriptError.invalid` to `invalid_script`, syntax failures to `syntax_error`, and other JS exceptions to `js_error`.

`summary()` defaults to offset 0, limit 50; maximum limit 200 and offset 1,000,000. Preserve `rows`, `total`, `nextOffset`; callers explicitly page. Read-only `selection`, `playhead`, `focusedTrack`, `tracks` use an audited summary call; `tracks` projects `trackLabels` to `{index,label}` rather than the summary's numeric track count. Selection may be non-clip or null; focusedTrack may be null. Queries retain existing kinds, filters and pagination. Find mode permits queries, summary and exactly one valid `builder.report_scenes(...)`, requiring a report before success; mutations/ensures remain unavailable.

Marshalling is JSON only: reject undefined (including array holes), functions, symbols, BigInt, cycles, non-finite numbers and unsafe numeric IDs; UUIDs remain strings. Preserve omitted fields versus explicit null for Phase 5 nullable patches. Reject non-JSON objects; no host objects escape. Enforce depth ≤ 32 and byte caps on the worker before crossing; bound returned script summaries to 64 KiB. An absent return means no summary, not a serialized undefined. Getters, proxies, `toJSON`, console stringification and result conversions all execute on the worker under termination control; never trust plain `JSON.stringify` to reject lossy values. Subtract injected wrapper lines from JS error locations to report user-source line/column.

## D3. Execution model

Extract `BuilderRunCoordinator` from `BuilderMCPServer.performCall`, endpoint admission/shutdown and Wizard lifecycle ownership. Both MCP and JS use it around async MainActor `BuilderTools.call`. Keep MCP transport/authentication at the endpoint.

1. Capture profile/database/project/timeline identity, revision, Library and selection/playhead. Create a transient `BuilderScriptSession`; use tools' recoverable mode. Coordinator checks identity/revision before admission, after awaits and before freeze/Apply eligibility.
2. Worker converts arguments to JSON `Data`, posts `Task { @MainActor in … }` to the coordinator, then blocks on `DispatchSemaphore`. Only Sendable bytes and synchronized completion/cancellation state cross threads. MainActor never blocks on the worker; JS values never enter its task captures.
3. Each call has a locked pending/completed latch and owned task handle. Cancellation latches the flag first, revokes admission and cancels the coordinator task, including registration races: registration rechecks latched cancellation. The callback's single completion path drains execution, encoding and auditing, writes result/error `Data`, atomically transitions pending→completed and signals exactly once. Cancellation before admission uses that same path; competing completion attempts cannot overwrite or signal twice. Cancellation during an adapter waits for its drain before signalling. Worker rechecks cancellation after waking; only it builds JS results/errors.
4. Coordinator owns budgets, duplicate requests, sanitization/redaction, `BuilderRunEvent` production and log charging. Same request ID/fingerprint replays cached bytes without mutation or double charge; changed fingerprint or exhausted dedup storage is terminal. Preserve endpoint caps (256 IDs, 16 MiB cache) and serialize admission. Script calls get monotonically unique IDs.
5. Budget/timeout/cancellation, stale identity/revision, uncaught JS errors, failed result sanitization or audit failure revoke admission and fail the session. Terminal remains terminal even if JS catches the thrown error: refuse all later calls and end failed, without an applicable candidate. Drain the complete callback and adapter before terminal accounting/freeze; retain captured audit ownership through dismissal/profile switches. No late callback may mutate or fail a frozen session.
6. Successful runs freeze for manual Apply/Discard; retain hydration until the terminal UI action, as today. Dispose failed/dismissed sessions after drain; asynchronously await worker exit and release JS state on its worker. S1 includes these lifecycle integrations for its debug runner. Write `builder_runs` with provider `script`, model script name/ad hoc, redacted bounded name/params request, events, summary and Library effects; existing statuses remain. Failed persistence prevents Apply and surfaces an error.

**Recovery:** `BuilderTools` uses `session.run(..., recoverRefusals:true)`; direct session calls currently default false. A recoverable refused list restores its starting document, selection, playhead, focus, zoom and entire binding map; prior successful lists survive and session stays ready. Earlier applied outcomes within that rolled-back list are diagnostic only. Caught/tolerated refusals do not become committed changes; uncaught refusals fail the overall run.

Bindings persist across lists. Successful rebinding deletes both `name` and every `name.*`, then installs returned UUID members. Bare `$name` uses precedence `tail`, `clip`, `piece1`, `overlay`, `block`, `sound`; absent preferred IDs leave no bare alias. Binding requires an ID-producing command and nonempty returned IDs; merged-away creations refuse. A later refusal restores the entire pre-list namespace, including old aliases. Terminal `limit`, `timeout`, `cancelled` outcomes never recover.

**Prerequisites:** resolve header targets before disclosure; the exact confirmed commands become `confirmedPrerequisites`. Tools enforce ensures before any mutation, including after a refused mutation attempt; queries may occur in the prefix. Undeclared/wrong-target/late ensures refuse. Pause the script wall clock only while an admitted prerequisite adapter runs; charge that interval to the separate 600 s prerequisite budget. Use a pause-aware clock in the script coordinator/tools budget, replacing raw elapsed checks for this path; keep ScriptRunner's 10 s synchronous-list limit. Resume remaining script time after drain, never grant a fresh allowance. Cancellation drains adapter and receipts/effect inventory before ending; report saved Library effects even after timeout, dismissal or profile change, against the original database.

**Validate:** syntax + header + parameter checks, then isolated evaluation in a throwaway transient session over copied captured values. Add an explicit validation capability with no hydration ownership, production services/database handles or run-record sink. Its prerequisite stub returns “requires user-run validation” for any ensure without executing it; report partial validation, never prerequisite success. Required clip/scene params without defaults need caller-supplied samples. The model or form supplies them; never guess IDs. Apply is unavailable.

## D4. Scripts, parameters, storage

The first non-whitespace token must be a leading `/** clipbuilder-script … */` block containing strict JSON, without comments, duplicate keys or unknown fields:

```js
/** clipbuilder-script
{
  "name": "Split selection evenly",
  "description": "Prepare transcript, then split the selected clip.",
  "mode": "edit",
  "params": [
    {"name":"parts","type":"number","min":2,"max":12,"step":1,"default":6},
    {"name":"video","type":"number","min":0,"step":1}
  ],
  "requires": [{"kind":"transcript","video":"$video"}]
}
*/
```

Require nonempty name, description, mode `edit|find`, params and requires arrays. Parameter names are unique ASCII identifiers; labels optional. Types: string, number, boolean, choice, clip, scene, track, time. Validate type-specific fields, finite ordered min/max, positive step, step alignment from min or zero, distinct nonempty choices, and defaults against identical runtime rules. All parameters are required; defaults fill omissions, otherwise request values. Time is finite 0…86400 seconds, defaulting to capture-time playhead; tracks are zero-based visible indices with labels I, II, etc. Clip UUIDs and safe integer scene IDs must match kind and captured project membership. Pickers enumerate the captured session across all pages; identity/revision changes invalidate choices, samples and disclosure. Install `params` as a frozen object behind a host-installed Proxy whose undeclared reads throw.

`requires` entries allow only `kind: transcript|people|analysis` and `video`: literal safe nonnegative video ID or `$parameterName` resolved to one. Validate membership against captured videos, reject duplicate targets and more than 12 entries, prohibit find-mode requirements. Confirm resolved targets, not names or wildcards.

S2 adds `builder_scripts` to each profile database: `id TEXT PRIMARY KEY NOT NULL` (host-validated UUID); `name`, `description`, `source`, `params_json`, `requires_json`, `mode`, `origin`, `created_at`, `updated_at` all `TEXT NOT NULL`; nullable `last_run_at`, `last_run_status TEXT`. CHECK nonempty trimmed name, mode in `edit|find`, origin in `human|ai|app`, status null or existing run statuses `completed|applied|failed|discarded|reverted`. Host validates JSON, source caps and ISO-8601 timestamps. Names need not be unique; no timeline foreign key. Index `(updated_at DESC,id)` for listing. Source header is authoritative for duplicated metadata, re-parsed and updated atomically with source; origin/timestamps are host-owned. Duplicate/import creates a fresh UUID; `.js` export includes the header.

In the same S2 commit, add the idempotent migration and bump `Database.schemaVersion` 14→15: databases stamped with the current version skip migrations. Update hard-coded 14 assertions in `DatabaseTests`/`SchemaVersionGateTests`; test fresh creation, upgrade from 14 and older versions, constraints, metadata atomicity and reopen without data loss.

## D5. UI (Wizard tab)

Scripts list: Run…, Edit, Duplicate, Export, Delete, New Script. Use `.help()` on controls and shared explanatory captions. Run captures params, discloses concrete prerequisites, then presents existing diff, Library effects and logs. Editor supplies Save, Run and Validate with sample-value form and source locations; malformed headers cannot save. ⌘R runs selected script.

**Save as script:** both local-parser execution (currently bypassing tools) and agent execution retain a bounded replay transcript: successful lists' steps/outcomes/created IDs, call boundaries and separate prerequisite entries/reports. Retain immutable transcript/baseline metadata after Apply clears the session. Cap at 128 entries/4 MiB; overflow disables export with an explanation, never silently truncates replay.

Export preserves list order and binding replacement, excludes rolled-back lists, rewrites created UUIDs referenced later into collision-free bindings, and parameterizes baseline clip/scene references. Ensures become separate prefix calls and concrete header requirements. Baseline sound/overlay/crop or other unsupported references, missing provenance, unresolved generated IDs, oversized source, or unverifiable equivalence disable Save with the reason. Offer export only after isolated replay produces the equivalent normalized diff with consistent ID renaming; prerequisite replay uses recorded snapshot transitions/stubs, never production adapters. This exports the observed replay, not inferred JS control flow.

## D6. AI authoring

“Write a script” exposes only captured `query`, `get_document_summary`, generated `script_reference`, and `submit_script(source,sampleParams)`. Submission uses D3 Validate; return syntax/header/parameter/runtime diagnostics or explicit partial validation. Bound submissions to three total attempts under coordinator budgets. Show accepted source in the editor for explicit Save/Run; no automatic user run. Deterministic Save as script remains subject to D5 eligibility.

## D7. Safety

Closed catalog, existing mode/prerequisite gates and manual snapshot Apply remain authoritative. Existing tool arguments are capped at 256 KiB (stricter than bridge ceiling); lists at 200 steps/256 KiB, results 1 MiB, affected items 2,000 per list plus cumulative run budget. Calls default 64/max 128; ensures max 12. Console and audit charging are bounded separately; audit defaults to 256 KiB, hard maximum 1 MiB, reserving terminal-event space. All limit breaches are terminal. Redact string values before JSON encoding; record field names rather than raw argument values. Retain no cross-run JS references or late executable callbacks.

## Phases

- **S1:** catalog/coordinator extraction, engine, bridge, termination, marshalling, headers/params, isolated validation capability, records, debug runner and complete lifecycle integration. Gate: full build/suite green, D1 termination gate, responsive MainActor, snapshot Apply with exactly one undo.
- **S2:** storage/migration, Wizard UI, parameter form, editor + Validate, bounded transcripts and Save as script. Gate: full build/suite green, fresh/upgrade/reopen tests and replay round trip, including export after Apply.
- **S3:** AI authoring tools, reference and bounded resubmission. Gate: full build/suite green, broken→fixed submission and zero production writes across three submissions, including ensures.
- **S4:** app-origin examples, shortcuts, recent scripts and user docs. Gate: full build/suite green and example/interaction checks.

Each phase must stand alone; commit/push only when explicitly requested. Historical phase reports do not certify these gates.

## Tests

- Every lowering/projection row, all wrappers, warnings/IDs/actual values, pagination and nullable patches.
- Cross-list bindings, whole-namespace replacement, missing preferred alias, merged creation, rollback/retry; caught refusal versus caught terminal error and stale revision.
- Adversarial conversion/getters/proxies/toJSON/stringification; invalid JSON values, depth/bytes, safe IDs, user-source line offsets, worker confinement and post-termination reuse.
- Cancellation before task registration, during execution/completion/conversion/prerequisites; exactly-once signal, dismissal/profile switch, adapter drain/effects, no late callback after freeze, failed auditing and find-report requirements.
- Header grammar/defaults/ranges/steps, frozen undeclared reads, later-page pickers and invalidation; validation creates no hydration hold, service call, receipt, autosave or run record across three attempts.
- Replay generated IDs/rebinding, refused-list exclusion, prerequisites, unsupported baseline kinds, overflow and post-Apply retention; migration constraints and metadata rollback.

## Decisions

D1–D7 are settled: JavaScriptCore/private termination API, dedicated worker, shared coordinator, recoverable lists, explicit JSON API/header, isolated validation, profile storage and conditional replay export. Apply stays manual; saved Library effects survive Discard/Undo/Revert. Implementation remains gated by S1 termination and acknowledged heap risk.
