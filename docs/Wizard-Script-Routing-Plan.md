# Builder pane tabs and script-first Wizard routing

## Why

The Builder's left pane has two tabs (Scenes, Wizard) and the Wizard tab
carries three jobs in one scroll: the request and its result, the saved
script library, and the run outcome. Separately, a Wizard request that a
saved script already answers still wakes the full agent (several MCP round
trips on the big model) when one cheap classification could have run the
script directly. Decision (2026-09-13): three tabs, and a router in front
of the agent that prefers saved scripts, with the agent as the fallback.

## Part 1 — Three tabs: Scenes, AI Wizard, Scripts

1. `ClipBrowserPane`: the segmented `Picker("Browser")` gains a third tag
   `"scripts"` labelled "Scripts"; the Wizard tag is labelled "AI Wizard".
   The stored tab preference (`selectedTab` binding, AppStorage key in
   `BuilderView`) accepts the new value; an unknown stored value falls back to
   "scenes". Help text on the picker: "Scenes to add, the AI Wizard, or your
   saved scripts".
2. `BuilderWizardPanel` keeps: `BuilderWizardRequestHeader`,
   `BuilderWizardStatusBanner`, `BuilderWizardReplyForm`,
   `BuilderWizardFindResults`, `BuilderWizardResults` (timeline changes, tool
   outcomes, agent explanation, Save as script…), Discard / Revert last run /
   Apply. It no longer embeds `BuilderScriptsSection`.
3. New `BuilderScriptsPanel` (Views/Builder/BuilderScriptsPanel.swift) hosts
   `BuilderScriptsSection` full height with the same `WizardSheetModel` and
   `ScriptLibraryModel` instances (shared, not new ones): New Script, Write
   with AI…, Restore examples, import/export, the script list with
   run / edit / duplicate / share / delete, the parameter form and editor
   sheets, and the "Timeline identity or revision changed…" notice. Running a
   script from this tab shows its preview/result in the AI Wizard tab: after a
   run starts, switch `selectedTab` to "wizard" so Discard/Apply are visible
   (the model owns the run; the tab only presents it).
4. `BuilderScriptsSection`'s layout is adjusted for a full-height column (no
   inner header duplication, list scrolls, actions row stays pinned at top).
5. Keyboard: ⌘R from either tab keeps its current meaning.

## Part 2 — Script-first routing

6. New `nonisolated enum ScriptRequestMatcher` (Services/Script/JS/ScriptRequestMatcher.swift),
   value-only and testable: given the request text and the saved
   `[BuilderScriptRecord]` (name, description, `paramsJSON` decoded through
   `ScriptHeader`), returns `[Candidate]` with `record`, `score` (0…1) and
   `extractedParameters: [String: ScriptValue]`. Deterministic rules:
   normalised token overlap between the request and name+description
   (stemmed, stop words removed), phrase bonus when the whole name appears,
   parameter extraction for numbers ("into 6 pieces" → an int/number
   parameter), person names against roster keys/names already in the
   `ScriptCapture.library`, tag/choice words against `choices`. A candidate
   whose required parameters are all extracted or defaulted is `runnable`.
   Thresholds: `confident` ≥ 0.75 and a gap ≥ 0.2 to the runner-up;
   `ambiguous` when the best is ≥ 0.4.
7. New `ScriptRequestRouter` (actor, Services/Script/JS/ScriptRequestRouter.swift):
   `route(request:scripts:capture:ai:log:) async -> Decision` where
   `Decision` is `.runScript(record, parameters, reason)`,
   `.escalate(reason)`. Order: matcher first; if `confident` and runnable →
   run without any model call. If `ambiguous`, or confident but missing
   parameters, one call to the cheap model through `AIService.call(task:
   "route", …)` — new task key `route` in `AICatalog.tasks`, label "Wizard
   routing", default provider claude with model `claude-haiku-4-5-20251001`,
   chain haiku → gemini flash → codex mini, no images. Prompt: the request,
   the candidate scripts (name, description, parameters with types/choices),
   and a strict JSON schema reply `{"script": "<id or null>", "parameters":
   {…}, "confidence": 0-1, "reason": "…"}`; parse with `AIResponseParser`,
   validate parameters against the header (types, min/max, choices), and
   accept only when confidence ≥ 0.8 and the script id is among the
   candidates. Anything else → `.escalate`. A router failure (provider down,
   timeout 20 s, unparseable) never blocks: it escalates. Log one line for
   each decision ("Routed to saved script 'Mute all B-roll' (deterministic,
   0.91)" / "Escalating to the agent: no saved script matches").
8. `WizardSheetModel.run(...)`: before building the agent program, when the
   request is free text (not a replay, not a scripted run, not a reply to an
   `ask_user` form), call the router. `.runScript` starts the existing
   JavaScript run path (`beginJavaScript(source:params:expectedCapture:)`)
   with the record's source and the decided parameters, and records the run
   with origin `routed` so the outcome shows "Matched saved script: <name>"
   in `BuilderWizardStatusBanner` with two buttons: "Ask the agent instead"
   (discards the preview and re-runs the same request with routing disabled)
   and the usual Apply/Discard. Nothing applies without Apply, exactly as
   today. `.escalate` continues into the agent unchanged.
9. Setting: `ScriptPreferences` (Settings → AI or the Wizard's ⓘ popover)
   gains "Prefer saved scripts" (default on) with help text; off means always
   escalate. A per-request escape is the "Ask the agent instead" button.
10. Agent guidance: extend the Wizard system prompt (where `run_script` is
    described) with one paragraph: prefer writing a single self-contained
    script through `run_script` over many individual edit tools when the
    change is expressible as one; keep scripts parameterised so they can be
    saved. No other prompt changes.
11. Save loop: after Apply of an agent run whose transcript contains exactly
    one `run_script` call that produced the whole change (the existing
    `ScriptReplayExporter.verify` already establishes this for Save as
    script…), show a one-line prompt in the results: "Save this as a reusable
    script?" with Save / Not now; Save opens the existing Save as script flow
    with the name pre-filled from the request. Remember "Not now" per timeline
    revision only (no nagging on every Apply). Scripts saved this way get
    origin `ai`.
12. Telemetry in the App Log only: the Wizard log line for a routed run
    includes "0 model calls" or "1 routing call (Haiku)"; the agent path is
    unchanged.

## Tests

13. `ScriptRequestMatcherTests`: "mute all b-roll" → Mute all B-roll
    confident, no parameters; "split the selected clip into 6 parts" → Split
    selection evenly with count 6; "remove clips with Aljo" → Remove clips with
    a person with the roster key resolved; "make the intro punchier" → no
    candidate; two near-equal candidates → ambiguous; a required parameter
    missing → not runnable.
14. `ScriptRequestRouterTests` with the stub AI (`StubAI`, stream-json
    assistant line): deterministic confident match makes zero AI calls;
    ambiguous request makes exactly one `route` call and accepts a valid JSON
    reply; invalid JSON, low confidence, unknown script id and a thrown
    provider error all escalate; the setting off escalates without calls.
15. `WizardSheetModel` test: a routed run produces the same preview/apply
    state as a manual script run, `ask the agent instead` re-runs with routing
    disabled, and the save prompt appears only after a single-`run_script`
    apply.
16. `ClipBrowserPane` tab preference: stored "scripts" restores; unknown
    value falls back to "scenes".

## Acceptance

- Scenes / AI Wizard / Scripts tabs; nothing script-library related remains
  on the AI Wizard tab except "Save as script…" and the save prompt.
- A request matching a saved script never calls the big model; the App Log
  shows the routing decision; "Ask the agent instead" always works.
- Full suite passes. No commit until asked. `.help()` on every new control;
  no "…" More menus.
