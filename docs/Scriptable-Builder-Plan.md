# Scriptable Builder: a command surface the app, tests and AI agents drive

Status: September 11, 2026: phases 1a–4 committed through aefff33; phase 5 implemented for the existing editable model surface, pending full build/test. See Scriptable-Builder-Phase5.md for exact limits and validation.
Scope: the D1 command/query surface, an isolated preview session, atomic
snapshot undo and persisted Revert, an MCP endpoint, and a Builder Wizard
sheet. Rendering and planning-Wizard internals remain out of scope.
File:line references below describe verified existing code; named new APIs,
records, and policies are implementation requirements, not existing features.

## Vocabulary as the app has it today

- `BuilderTimelineModel` owns the document, scene cache, selection and
  playhead (`ClipBuilder/App/BuilderStore.swift:124`). It has a default
  initializer; the target supplies MainActor isolation (`Clip Builder.xcodeproj/project.pbxproj:423`).
  Most mutations register undo and call `documentDidChange`, but compound
  helpers register more than once (`BuilderStore.swift:1462`), and scene/UI
  updates register none (`BuilderStore.swift:375`, `:133`).
- `TimelineDocument` is a value type (`ClipBuilder/Data/TimelineModels.swift:8`).
  Clip `uid` is not encoded; `originKey` survives loading but is shared by
  split pieces (`TimelineModels.swift:595`). Clone in memory, not through JSON.
- Library scenes are project-scoped and include excluded rows by default
  (`ClipBuilder/Data/Database.swift:1869`); `fetchPeople` includes hidden
  people (`Database.swift:2287`). Person tags use `person:<key>`
  (`ClipBuilder/Data/Models.swift:127`); B-roll is a scene tag (`Models.swift:445`),
  while highlight tags are also synthesized (`ClipBuilder/Services/Analyzer.swift:230`).
  A scene's B-roll tag and a timeline clip's cutaway role are distinct.
- `fetchTranscripts` returns optional word JSON (`Database.swift:2443`);
  `transcriptSegments` explicitly returns `words: nil` (`Database.swift:2463`).
  Features and proposals include timed classifications and proposal decisions
  (`Database.swift:2563`, `:2575`). `fetchVideoPeople` returns roster/portrait
  data, not ranges, although the writer stores `ranges_json`
  (`Database.swift:1563`, `:1601`). A range query needs a new typed accessor.
- `AppStore.analyze` and `transcribe` start tasks and return immediately
  (`ClipBuilder/App/AppStore.swift:1340`, `:3144`). `detectPeopleInVideo` is
  async but reports errors through UI and can queue rename review (`AppStore.swift:5219`).
  The analyzer contains the scene breakdown pass (`Analyzer.swift:529`).
- `AIService.call` launches Claude with stream-json, Codex with `exec`, and
  Gemini with `-p`; it also supports Qwen/Kimi (`ClipBuilder/Services/AIService.swift:244`,
  `:303`, `:453`, `:484`, `:549`). Timing includes failover; capture occurs
  only on success when a TaskLocal capture exists (`AIService.swift:195`).
  `AIRunCapture` stores roles/provenance and prompts, not tool events
  (`ClipBuilder/Services/AIRunCapture.swift:3`).
- Wizard parsing validates tags/templates/music folders and clamps duration;
  free-form text remains free-form (`ClipBuilder/Services/WizardEngine.swift:520`).
  Its local parser can accept residual words (`ClipBuilder/Services/WizardRequestParser.swift:83`);
  that confidence rule is unsuitable for destructive editing.
- Installed help was reviewed for Claude 2.1.267, Codex 0.153.4 and Gemini
  0.53.1. Their HTTP configuration forms are in D4. Help verifies flags, not
  interoperability or confinement; phase 1 must exercise all three clients.

## Goals

1. Every operation in D1 can be driven by validated JSON and previewed;
   an applied run has exactly one whole-document undo registration.
2. Models use the same surface through tools, with manual Apply and no UI
   automation. Failed or incomplete runs cannot apply.
3. Tests, macros and the planning Wizard can use the surface without a model.
   Sound/overlay editing, speed, captions, transitions, framing, track and
   render settings are later expansion, not initial UI parity.

## D1. Commands and queries (`BuilderScript`)

New module `ClipBuilder/Services/Script/`. `BuilderCommand` encodes an `op`
plus typed fields. IDs are scoped to the session; tracks are zero-based;
`at`/`between` use timeline seconds and source ranges use absolute file seconds.
Asset inputs are Library/resource IDs resolved by the app, never arbitrary paths
or caller-supplied media durations. Source metadata is authoritative.

Mutations wrap store logic, with validated outcomes and precision support added
there where needed. Locations below are in `ClipBuilder/App/BuilderStore.swift`.

| op | fields | store method / location |
|---|---|---|
| `remove_clip` | clip | `removeClip` :1057 |
| `remove_clips` | filter | freeze matching IDs, then `removeClip` :1057 |
| `split_clip` | clip, at | new `splitClip`; primitive specified below; existing policy :1184 |
| `trim_clip` | clip, duration, precision? | `trimClip` :1004 |
| `set_source_range` | clip, start, end, precision? | `setClipSourceRange` :1031 |
| `place_clip` | clip, start, track | `placeClip` :976 |
| `add_scene` | scene, at?, track | `addScene` :812 |
| `add_cutaway` | scene or video, at?, track, duration?, source_start?, cover_all | `addCutaway` :888 |
| `set_clip_role` | clip, role | `setClipRole` :942 |
| `set_cutaway_audio` | clip, audio | `setCutawayAudio` :953 |
| `duplicate_clip` | clip | `duplicateClip` :1071 |
| `set_track_sequential` | track, sequential | `setTrackSequential` :1221 |
| `add_crop_block` | layout, at?, duration? | `addCropBlock` :1247 |
| `set_crop_layout` | block, layout | `setCropLayout` :1278 |
| `remove_crop_block` | block | `removeCropBlock` :1314 |
| `add_bumper` | bumper, at?, mode | `addBumper` :641 |
| `add_sound` | sound, at?, duration | `addSound` :1331 |
| `add_text` | at?, text | `addText` :1363 + `updateText` :1427 |
| `add_image` | image, at?, length | `addPhotoOverlay` :1462 |
| `remove_overlay` | overlay | `removeText` :1437 / `removeImage` :1487 / `removeOverlayBlock` :1411 |
| `set_playhead` | at | session playhead :133; not a document edit |

### Phase 5 additions

| op | fields | model path |
|---|---|---|
| `set_bumper_mode` | clip, mode (overlap / pause); bumper only | `setBumperMode` |
| `set_crop_block_duration` | block, duration (0.5...86400) | `resizeCropBlock` |
| `split_crop_block` | at (0...86400); covering block and two ≥0.5s pieces required | `splitCropBlock` |
| `remove_sound` | sound | `removeSound` |
| `add_overlay` | template, at?, duration? (0.5...86400), person?; query `templates` for names; person key/display name only for Lower Third | `addOverlayBlock`, `updateOverlayBlock` |
| `set_image_geometry` | overlay, x?, y?, width?, opacity?; at least one; x/y/opacity 0...1, width 0.05...1 | `updateImage` |
| `set_overlay_position` | overlay (text/image), x/y (0...1); fractions override text preset | `updateText` / `updateImage` |
| `set_text_style` | overlay, style (nonempty closed patch; see below) | `updateText` |
| `set_clip_volume` | clip, volume (integer 1...5); bumpers and B-roll only (the exporter ignores main-clip volume) | `updateClip` |
| `set_clip_position` | clip, position (top / center / bottom / null); wide Full Screen only, null restores track default | `updateClip` |
| `set_clip_crop` | clip, fraction (0...1 / null); wide Full Screen only, null clears clip crop | `updateClip` |
| `split_zoom_feeds` | clip, left, right; wide clip in Full Screen on track 0, captured source aspect, 50-50 Horizontal required, refuses existing partner | `splitZoomFeeds` |
| `clear_timeline` | no parameters; charges all lane items, resets document | `clear` |
| `set_sound_volume` | sound, volume (integer 1...5) | `updateSound` |
| `set_sound_range` / `move_sound` | sound, start, duration / sound, at | `updateSound`; timeline seconds |
| `set_text` / `set_text_position` | overlay, text / overlay, position (top/center/bottom) | `updateText`; position clears x/y overrides |
| `set_overlay_range` | overlay, at, duration | `updateText`, `updateImage`, `updateOverlayBlock` |
| `set_overlay_transitions` | overlay, trans_in, trans_out | text/image only; `TextOverlayItem.transitionChoices` |
| `set_clip_speed` | clip, speed (0.5...2) | `updateClip`; inspector rounding, source overflow refusal |
| `set_clip_fades` | clip, fade_in, fade_out | B-roll only; each ≤ half duration |
| `set_clip_captions` | clip, captions (inherit/none/top/middle/bottom) | `updateClip`; B-roll/bumpers only accept none |
| `set_clip_transitions` | clip, trans_in, trans_out | cut + canonical RenderEngine action/standard names |
| `set_clip_center_stage` | clip, enabled | wide main Full Screen clips |
| `set_clip_area_window` | clip, x, y, width, height | assigned area; bounded fractions, width ≥ 0.1, preserves proportions |
| `set_track_captions` / `set_track_muted` | track, captions / track, muted | `updateTrackSettings` |
| `set_track_position` / `set_track_crop` | track, position / track, fraction (null clears) | Full Screen track defaults |
| `set_render_settings` | settings {preset?, custom_width?, custom_height?, quality?, custom_crf?} | whitelisted patch through `setRenderSettings` |
| `set_pacing` | pacing {cadence, curve} | existing CutCadence/PaceCurve cases through `setPacing` |

`set_sound_fades` is not part of the surface because SoundItem has no fade fields.
`set_track_volume` is not part of the surface because TrackSettings has no volume field.
`set_clip_screen_crop` is not part of the surface because the underlying model has no editable per-clip screen-crop fields; legacy screenCrop state is migrated to the cropping row, so use `set_crop_layout`.

Overlay blocks have no
block-level transitions. No ineffective storage fields or render behavior were
invented. Track labels are retained/diffed but have no editing UI in this scope.

New numeric inputs are finite; range edits require duration ≥ 0.5 and end ≤
one day. Render custom dimensions are even integers 240...7680; CRF is 10...35.
Unknown keys are refused at every new object boundary. Document-dependent
eligibility and IDs are validated before mutation. Track fields now have
individual diff paths; render/pacing and all indirect changes are reflected.
Any ID field accepts `selected` (the timeline selection, also reported by the
`timeline` query and `get_document_summary`). Local phrases accept "this clip",
"the selected scene" and "the current clip" interchangeably, "split … in 4
separate ones", and "remove the selected sound/text/image/overlay/crop block".
Local phrases add selected-clip speed/captions, unique music volume, track
captions/mute, with full recognition. Track-volume phrases remain unsupported.

### Validation and execution

> Refusal semantics below are superseded by the recoverable-edit rule (462e7d4); see [revision 2](Builder-Scripting-Plan.md#d3-execution-model).

- Reject unknown fields/enums, nonfinite times, invalid ranges/tracks,
  out-of-scope or missing IDs, unavailable assets and excessive payloads.
  Resolve media bounds from the Library; file-only source-range edits currently
  lack that ceiling (`BuilderStore.swift:1034`). Do not silently clamp invalid
  tracks as existing UI methods do (`BuilderStore.swift:986`).
- `CommandOutcome` is `applied(actualValues, createdIDs, warnings)`,
  `unchanged(reason)`, or `refused(code, reason)`. Missing targets are refused;
  valid idempotent setters may be unchanged. Convert silent store refusals into
  typed results; do not infer success from a Void return or current selection.
  Each step may bind returned IDs by name for later steps, including split tails.
- Execute in declared order on MainActor against the transient model; finish
  each mutation's layout/normalization before the next step. Freeze bulk target
  IDs before deletion. Serialize agent calls, including across awaited passes;
  no mutation may overtake an earlier pending step. Queries see completed steps.
- A list is atomic: any refused command aborts the run, disables Apply and drops
  its candidate document. Agent refusal, timeout, cancellation, budget exhaustion
  or process failure likewise makes the run non-applicable. A partial diff is
  diagnostic only. Previously completed Library passes remain (see below).
- Default positions are explicit: `add_scene` appends at track end; other `at?`
  additions use the seeded session playhead (`BuilderStore.swift:828`, `:892`).
  Selection changes remain local. Return actual placement after repacking.
  Empty/query-only runs have no Apply or undo action.
- Preserve sequential semantics: packing starts at zero, leaves cutaways fixed,
  and splits around pausing bumpers (`BuilderStore.swift:1169`). A pause bumper
  inserts/removes a gap across lanes (`BuilderStore.swift:641`, `:1057`). Role
  conversion can remove captions/framing and repack (`BuilderStore.swift:939`).
  Diff all indirect changes; do not defer packing to the end of a list.
- Precision: retain half-second snapping for ordinary placement/UI defaults
  (`BuilderStore.swift:522`). Add an explicit `.speech` precision policy to
  split/trim/source-range store APIs: preserve supplied timestamps to millisecond
  precision, allow pieces down to 0.05 s, and remove their current half-second
  minimum and tenth-second duration rounding for that policy (`BuilderStore.swift:1022`,
  `:1036`). Validate bounds after rounding; derive screen duration through speed.
  Do not route precise edits through the old snapped helpers. Export remains
  subject to frame/sample quantization; speech precision excludes bumpers.

### Standalone split primitive

Extract shared split math from `resolveLayout` (`BuilderStore.swift:1195`) into
an undo-free, notification-free document primitive. `splitClip(uid, at:)` wraps
it with validation, normal layout handling and one change notification. Ordinary
UI use may register undo; transient use has no manager.

`at` is absolute timeline time, strictly inside a non-bumper main/cutaway clip.
Reject endpoints, nonfinite values and pieces below the chosen precision minimum.
Compute source cut as `sourceStart + (at - startTime) * effectiveSpeed`; require
resolved source bounds. The head keeps its UID and ends at the cut; the tail
gets a new UID, starts at `at`, and covers the remaining played source window.
Both retain `originKey`; only duplication creates a new origin (`BuilderStore.swift:1075`).
The head retains incoming transition/fade, the tail outgoing transition/fade;
clear the two new internal boundaries. Preserve role/audio/framing and source
continuity. Return both IDs and actual ranges. The bumper packing caller may
place a tail after its obstacle; standalone splitting opens no gap. Shared
packing must preserve precise pieces rather than re-snap them.

### Queries and filters

`ClipFilter` supports track, role, explicit bumper inclusion (off by default),
people (all roster keys), tags (all), any_tags, between (half-open overlap), and
scene_score_below. Unknown scores do not satisfy numeric comparisons. People
filters initially use scene tags, not an invented per-frame presence guarantee.
`SceneFilter` has people/tags/video/text/min_score; timeline-only fields are
invalid there. Other queries have their own schemas, not a universal ClipFilter.
All results have deterministic ordering, limits and pagination where needed.

| query | returns / policy |
|---|---|
| `timeline` | document lanes, IDs, roles, source ranges, timing, audio, crops, bumpers and duration |
| `clips` | matching clips with scene tags/people and unknown-data markers |
| `scenes` | project-scoped scenes, excluded off by default, score descending then ID |
| `people` | roster keys/names/descriptors, hidden off by default |
| `transcript` | original-language rows with decoded optional word JSON, clipped to requested source range |
| `silences` | classified silence or thresholded gaps in available word timings; evidence and precision included |
| `tags` | profile vocabulary plus supported synthetic tags |
| `layouts` | snapshotted Screen Crop layouts and areas |
| `templates` | name, kind (`template` / `lower_third`), duration; saved overlay snapshot plus built-in Lower Third |
| `capabilities` | pass state per video, including completion with no data |

Use `Database.swift:2443` for word JSON, not `:2463`; features/proposals come
from `:2563`/`:2575`. Missing timings are unknown, never whole-clip silence.
Respect rejected proposals; map source intervals through clip speed and clip
bounds. Snapshot resource definitions as well as scene data; existing layout
lookup reads shared resources (`BuilderStore.swift:1240`).

### Prerequisite service adapters

`ensure_transcript`, `ensure_people`, `ensure_analysis` are separately disclosed
Library operations, not reversible document mutations. New awaitable adapters
call services below AppStore's UI entry points (`AppStore.swift:1340`, `:3144`,
`:5219`). Capture database/profile/project/settings once, deduplicate in-flight
work, propagate cancellation and return `unavailable`, `running`, `failed`,
`completed-empty` or `completed-with-data`, with reason/job/data version as needed.
A dependent command waits for terminal completion; `running` is not success.
No rename sheets, consumed UserDefaults or implicit UI error presentation.

Ensure means reuse a sufficient successful result, including a completed-empty
result; no force refresh tool. These services can still replace data:

- Transcription replaces matching language/translation rows and regenerates
  features and silence/filler/false-start/noise proposals; some decisions are
  matched back (`Database.swift:2415`, `:2521`; `TranscriptionService.swift:62`).
- People detection replaces the video's roster and updates detection provenance
  (`Database.swift:1586`); it can update shared identities through the analyzer.
- Analysis creates another analysis batch and may update video classification,
  people and associated analysis data; it is not an append-only guarantee
  (`AppStore.swift:1338`, `:1430`; `Analyzer.swift:1526`).

Report actual replacements and persistent effects before/after execution. They
survive Discard, failed runs, Undo and Revert. Do not silently run them as a
supposedly read-only query. Completion refreshes the session's data explicitly;
coordinate/defer live hydration while the session is open, because ordinary
refresh hydrates the live Builder (`AppStore.swift:1178`). Any external document
change instead invalidates the session baseline. Ship these tools only after
these service contracts and side-effect tests pass.

## D2. Sessions, dry run, diff, apply

`BuilderScriptSession` captures timeline/profile/project identity, a monotonic
live-document revision and an exact baseline value. Revisions advance for all
document changes, including hydration and undo. Every tool edits a second model.

Add a permanent `.transient` model mode and explicit seeding API: value-copy the
document, seed a private scene-map snapshot through `updateScenes`, snapshot
resources/Drive-backed paths, and copy selection/playhead/focused track/zoom.
Seed before exposure to tools. No JSON cloning, UI subscriptions or undo manager.
The mode disables autosave scheduling, flushes and all persistence/UI callbacks
for its lifetime while preserving normalization/cache invalidation. Nil callbacks
alone are unsafe: current `documentDidChange`/flush fall back to file writes
(`BuilderStore.swift:461`, `:504`; `ClipBuilder/Data/BuilderStateStore.swift:20`).
Do not use `loadDocument` as a pure clone: it registers undo, resets UI state,
hydrates and schedules saving (`BuilderStore.swift:327`).

`diff()` compares the candidate to the fixed baseline, not the changing live
model. Compare every document field, including sequential flags, source/audio,
transitions/fades, captions/framing lost by role changes, indirect bumper/crop
changes, track/render settings and duration. Show Library effects separately.
Before preview completion, close mutation admission, cancel/drain outstanding
work and freeze the candidate. `discard()` releases the transient state.

### Atomic undo by snapshot (requirement)

Exactly **one undo registration per applied run**, independent of command count.
Never reverse individual commands or register their undos on the live manager.
The working copy is edited with **no undo manager**.

- Add a named `BuilderTimelineModel.applyScriptSnapshot` API. Check captured
  identity and revision against live state immediately before commit; refuse
  stale Apply, including a timeline/profile switch or intervening manual edit.
  Capture `before = document` by value. Normalize/validate the candidate before
  freezing it so installation cannot silently change the approved diff.
- After durable commit succeeds, register exactly one whole-document undo with
  action name `Wizard: <request>`, then install the approved snapshot. Preserve
  live timeline identity and autosave callbacks, invalidate caches, retain valid
  live selection and clamp live playhead; session playhead is not transferred.
  Undo installs `before` wholesale, registering the applied snapshot as redo;
  redo restores it exactly. Do not rehydrate against changed scene metadata in
  this exact restore path (current `restore` does: `BuilderStore.swift:228`).
  UI state is reconciled, not part of document undo.
- Keep the existing snapshot mechanism (`BuilderStore.swift:214`) but expose
  this named atomic API; do not use `loadTimeline`, which resets undo history
  (`BuilderStore.swift:286`). No UndoManager means Apply must wait until the
  window manager is attached; no silent loss of the one-step requirement.
- Persist one **before last Wizard run** version per timeline, with request,
  time and run ID. A successful new Apply replaces it; failed/discarded runs do
  not. `Revert last run` restores this whole document without requiring undo
  history. Preview/confirm Revert because it also removes later manual edits;
  use a fresh revision check and one snapshot undo if a manager is available.
  Manual edits otherwise stack normally above the single Wizard undo step.
- Runs ending in refusal, timeout, budget, cancellation or error cannot apply;
  display the diagnostic partial diff and discard it. No live undo registration.
  Library passes are explicitly **not undone**: e.g. “Transcribed X; saved
  transcript/features remain after Undo or Revert.”

### Persistence and commit boundary

There is no existing timeline AI-record field (`ClipBuilder/Data/TimelineRecord.swift:3`,
`TimelineModels.swift:8`); `Database.saveTimeline` only updates document/name,
thumbnail and edit time (`Database.swift:1298`). Add a schema migration:

- `builder_runs`: run UUID, timeline foreign key, request/time, provider/model,
  duration, status, baseline/applied revisions, summary, Library effects and
  bounded structured events JSON. Record local-parser runs as local. Completed,
  failed and discarded runs are distinguishable; keep history under a retention
  limit without deleting the referenced last before-version.
- `timeline_wizard_before`: timeline primary/foreign key, run UUID, request/time,
  the before-document as ordinary `TimelineDocument` JSON, and the applied
  document revision. One row per timeline; timeline deletion cascades. Ordinary
  JSON is sufficient on disk: clip `uid`s are runtime-only and regenerate on
  load exactly as they do for any reopened timeline, and hydrated fields are
  refilled from the Library on load. Only the **in-memory** undo snapshot must be
  a value copy (to keep live identities for the current session). Reviewer note:
  a dedicated snapshot codec was considered and rejected as unnecessary.
- Both tables are added in `Database.migrate()` **and `Database.schemaVersion`
  is bumped** in the same change (migrations run only when the stamped version
  differs; 1.60 shipped broken because this was missed).
- Add a persisted timeline document revision and an AppStore commit coordinator.
  Route all timeline writes through the same serialized save path
  (`AppStore.swift:3825`). Under a short edit/switch/hydration gate, drain earlier
  saves, recheck identity/revision, and schedule **one** commit transaction that
  writes the candidate timeline, run record and before-version together. A DB
  compare-and-swap refuses conflicting revisions. On write failure, change no
  live state and register no undo; on success install synchronously on MainActor
  before releasing the gate. Pending ordinary autosave must not overwrite this
  transaction. The atomic API uses this coordinated save, not a second debounced
  document write; ordinary callbacks remain installed for later edits.
- Undo/redo/Revert use the same save coordinator and advance revision. Update the
  run's application status consistently with the restored document while keeping
  its immutable audit and before-version. Revert works with an empty manager;
  a missing/corrupt snapshot refuses without mutation. Reopen after a crash shows
  either the old transaction or the complete new one, never a mixed run/version.

## D3. The MCP server

Use `modelcontextprotocol/swift-sdk` with an HTTP hosting adapter, bound to
127.0.0.1 on a random port. Pin wire protocol **2025-06-18** and a compatible
SDK release after the phase-1 spike; record the exact dependency version before
implementation proceeds. The installed Gemini client includes this version
(`/usr/local/lib/node_modules/@google/gemini-cli/bundle/chunk-2NH5AG3B.js:301697`).
Do not assume newer protocol revisions or SDK main are compatible.

The adapter owns listener lifecycle, request limits and authentication; SDK
handlers dispatch validated commands/queries to the session on MainActor.
Implement `initialize` with version/serverInfo/capabilities, then accept
`notifications/initialized`; handle `tools/list`, `tools/call`, `ping` and
cancellation. Advertise only implemented capabilities. Notifications receive no
JSON-RPC response; accepted HTTP notifications return empty 202. Validate the
negotiated protocol header and reject unsupported versions. Return JSON for
ordinary calls; GET may return 405 when no SSE stream is offered. If using SSE
for progress, implement framing, cancellation and reconnection semantics; do not
confuse Streamable HTTP with legacy HTTP+SSE. Prefer no transport session IDs
unless needed; issuing one requires the full session lifecycle.

Use a per-run bearer token on every request, validate Origin (reject unexpected
browser origins, accept absent Origin from native clients), enforce Host/path
and loopback binding, and never expose Apply/Revert as agent tools. Revoke token
and stop admission before draining work and closing the endpoint. Redact tokens
from configuration diagnostics and logs. HTTP is chosen to avoid a separate app
bridge; SDK-backed stdio plus an authenticated bridge is the fallback if the
three-client spike fails, not a hand-written HTTP/JSON-RPC stack.

References: [Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk),
[MCP lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle),
[Streamable HTTP](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports).
Compatibility and confinement are release gates, not claims established by help.

## D4. Running an agent

`BuilderAgentRun` is a separate adapter over `ProcessRunner`, not an extra mode
of `AIService.call`. The latter buffers output, parses after exit and retries/
fails over (`AIService.swift:269`, `:318`, `:358`). `ProcessRunner` already has
streaming stdout and cancellation (`ClipBuilder/Services/ProcessRunner.swift:71`,
`:95`); extend it for controlled cwd/environment, bounded stderr alongside
streaming stdout, and descendant cleanup (`ProcessRunner.swift:101`, `:152`, `:203`).

Use incremental, bounded per-provider parsers for split UTF-8/JSONL chunks,
progress/tool events, final response and terminal error. No automatic retry or
provider fallback: either could repeat mutations. The CLI owns the multi-turn
agent loop; tool round-trips use MCP, not ongoing stdin writes. A new attempt
requires a new session and explicit user Run.

Verified launch/configuration forms (help versions in Vocabulary):

- **Claude:** `-p <request> --output-format stream-json --verbose --tools ""
  --allowedTools "mcp__clipbuilder__*" --mcp-config <file>
  --strict-mcp-config --permission-mode dontAsk`. The JSON file is
  `{"mcpServers":{"clipbuilder":{"type":"http","url":"http://127.0.0.1:PORT/mcp",
  "headers":{"Authorization":"Bearer TOKEN"}}}}`.
  `--tools ""` removes built-ins; the allowedTools glob preapproves this server,
  not all tools. Strict MCP config does not disable hooks/plugins/instructions:
  suppress unrequested settings/customizations in the tested adapter, preserving
  the intended authentication route. Never use bypassPermissions. Do not assume
  bare mode preserves subscription authentication.
- **Codex:** `exec --json --ephemeral --ignore-user-config --ignore-rules`
  with `-c 'mcp_servers.clipbuilder.url="http://127.0.0.1:PORT/mcp"'` and
  `-c 'mcp_servers.clipbuilder.bearer_token_env_var="CLIPBUILDER_MCP_TOKEN"'`.
  Supply the token only in the child environment; configure server startup/tool
  timeouts and scoped MCP approvals. Use a controlled cwd, read-only sandbox and
  no approval prompts; exclude unrelated servers, plugins, instructions and
  native shell/file/web capabilities in the version-tested configuration.
  Read-only sandbox alone does not prevent file reads. These verified flags do
  not themselves prove complete tool confinement: keep this adapter disabled
  until the spike verifies its effective tool set and negative tests. Do not
  use persistent `codex mcp add` for an ephemeral endpoint.
- **Gemini:** `-p <request> --output-format stream-json
  --allowed-mcp-server-names clipbuilder --approval-mode default --policy <file>`.
  Settings contain `{"mcpServers":{"clipbuilder":{"httpUrl":"http://127.0.0.1:PORT/mcp",
  "headers":{"Authorization":"Bearer TOKEN"}}}}`. Use Policy Engine rules
  denying built-ins/unrelated tools and allowing only this server, with tested
  rule precedence; never yolo. Suppress unrelated extensions/hooks/settings.
  Child-scoped `GEMINI_CLI_HOME=<root>` puts runtime settings at
  `<root>/.gemini/settings.json`; it also relocates OAuth credential lookup
  (installed `chunk-2NH5AG3B.js:251979`, `:253034`, `:253147`). Define secure
  authentication provisioning; a blank temporary root is not already signed in.

All adapters use argv arrays, a controlled environment/cwd and private temporary
configuration cleaned on termination. Never change the user's global CLI config.
System policy may refuse a launch; surface that rather than weaken confinement.
Verify built-in and unrelated MCP tools are unavailable before enabling an adapter.

The prompt describes the model, tools and rules: query first, resolve IDs, use
only disclosed prerequisites, and finish with a short explanation. Model text
is a summary, never evidence of success. Structured events drive progress.
`BuilderRunEvent` records run/sequence/request ID, tool name, sanitized arguments,
argument byte size, outcome, result byte size and duration. Bound/redact payloads;
record failures and Library effects too. This is separate from `AIRunCapture`
(`AIRunCapture.swift:24`); explicitly associate callbacks with the run. Reuse
AIProvenance for provider/model/timing, persist through D2's new run record.

References: [Claude MCP](https://code.claude.com/docs/en/mcp),
[Claude permissions](https://code.claude.com/docs/en/permissions),
[Claude streaming](https://code.claude.com/docs/en/headless),
[Codex MCP](https://developers.openai.com/codex/mcp),
[Gemini MCP](https://geminicli.com/docs/tools/mcp-server/),
[Gemini configuration](https://geminicli.com/docs/reference/configuration/),
[Gemini policies](https://geminicli.com/docs/reference/policy-engine/).

### Phase 1c spike results (September 11, 2026, reviewer-run)

Harness: `spike/mcp-spike` (throwaway, SDK `modelcontextprotocol/swift-sdk`
0.12.1 pinned, `StatelessHTTPServerTransport` behind a Network.framework
listener, protocol 2025-06-18). Server on 127.0.0.1 with a per-run bearer
token; requests without the token get 401, GET gets 405, Origin is checked.

- **Claude 2.1.268: pass.** With `--tools "" --allowedTools "mcp__clipbuilder__*"
  --mcp-config <file> --strict-mcp-config --permission-mode dontAsk` the
  server log shows initialize, notifications/initialized, tools/list and the
  three tools/call; the client output carries the results and no built-in
  tool events. HTTP config form `{"type":"http","url":…,"headers":{"Authorization":…}}`
  works.
- **Codex 0.153.4: transport pass, confinement flag gap.** Initialize and
  tools/list reached the server, but every tools/call failed client-side with
  "MCP tool call requires approval, but approval policy is never": `-a never`
  blocks MCP calls unless the server's tools are pre-approved. D4 must add the
  per-server approval configuration (Codex config `mcp_servers.<name>`
  tool-approval keys, to be confirmed against `codex --help`/docs in phase 3)
  instead of relying on `-a never` alone. Codex's model backend also logged
  websocket 307 redirects during the run (network), which did not affect the
  MCP path.
- **Gemini 0.53.1: not run.** The harness requires `GEMINI_API_KEY` in the
  environment because `GEMINI_CLI_HOME` relocates OAuth lookup; none was set.
  Remains unverified until a key is provisioned for the spike.
- Port 8765 was occupied by an unrelated local Python server; the harness
  should pick a random free port rather than a fixed one (phase 3 note).

## D5. Local fallback

`BuilderRequestParser` handles a small grammar: remove matching clips, find
people/tags, cut silence on a track/selected clip, add B-roll at a time.
Return `BuilderProgram(steps: [query, ensure, mutate], bindings, presentation)`;
query results can bind IDs and feed deterministic expansion into atomic mutation
lists. A find program returns candidates without creating document edits.
Silence expansion resolves source-to-timeline intervals and piece IDs before
applying its ordered split/remove steps under D1's precision policy.

Confidence requires full recognition of the action, targets, qualifiers,
negation and all meaningful input. Ambiguous person names, unknown IDs/tags or
unconsumed instructions are not confident; never partially execute a request.
Unlike `WizardRequestParser.swift:83`, residual word count is not acceptance.
Confident programs need no model; otherwise offer clarification or the selected
agent. Without a configured provider, supported local requests still work.

## D6. The Wizard button

Builder toolbar “Wizard” (`wand.and.stars`, no More menu). Sheet: multiline
request, last ten requests, provider picker routed through `builder_agent`,
live log, then a complete diff with Apply/Discard. Show persistent Library effects
separately and disclose them before running prerequisites. Apply is always manual;
refused/incomplete/stale runs have no enabled Apply. “Revert last run” previews
the saved before-version and warns that later document edits will also be removed.

Finds show candidates without an Apply step; later connect them to the B-roll
picker's Suggested group, with the request as the reason. Adding a found item
uses the same command surface. ⌘Return runs; Escape cancels/drains and discards.
Closing/switching the timeline cancels the session. Error and cancellation state
must distinguish “no timeline changes applied” from Library work already saved.

## D7. Safety and limits

- Dry run for document changes; exactly one snapshot undo per successful Apply,
  plus persisted Revert. Library effects are neither rolled back nor undone.
- Captured identity/revision, scoped IDs and fixed baselines prevent cross-profile
  writes and stale overwrites. Never accept arbitrary paths or invented metadata.
- Treat transcript/tag/narrative/filename text as untrusted input, not instructions.
  Enforce permissions in adapters/server, not prompts; local transport is not a
  sandbox for the CLI's other tools.
- Bound wall time, tool calls, affected-item count, query/payload size and logged
  bytes. Enforce before admission; one bulk tool is not one unit of work. Bound
  prerequisite jobs separately. Defaults are settings, with hard maximums.
- Serialize mutations; deduplicate request IDs within a run and reject reused IDs
  with different arguments. A new CLI attempt never silently resumes/replays.
  On stop, refuse new calls, cancel/drain active calls and child processes, then
  freeze the diagnostic diff. Late callbacks cannot revive or mutate a session.
- Redact secrets and cap sensitive log content; retain structured outcomes rather
  than claim the entire agent's internal activity was captured. No agent tools
  for Apply, Revert, profiles/settings, arbitrary files or other timelines.

## Phases

1a. **Commands on a transient model** (D1 without prerequisites, D2 session
   and diff, no persistence): `.transient` mode with zero persistence hooks and
   explicit seeding; `BuilderCommand` and `ClipFilter` with JSON round trip;
   validation and typed outcomes with bound ids; the standalone split primitive
   and the `.speech` precision policy; queries; `ScriptRunner` and
   `BuilderScriptSession` with `diff()` and `discard()`; a `#if DEBUG` menu item
   that runs a JSON script against a session and shows the diff. Tests for all
   of it. Shippable on its own: nothing touches the live document yet.
1b. **Atomic apply and persistence** (rest of D2): persisted document revision,
   the `builder_runs` and `timeline_wizard_before` migration with the schema
   version bump, the commit coordinator, `applyScriptSnapshot` with the single
   snapshot undo, Revert last run, stale-Apply refusal, crash-consistency tests.
1c. **Transport spike** (parallel workstream, no product code): a throwaway
   SDK-backed HTTP endpoint exercised against the three installed clients for
   initialization, auth, JSON/SSE handling, effective tool confinement and
   shutdown; pin the Swift SDK release. No implementation commitment to an
   unverified transport/config. Prerequisite tools stay unavailable until their
   service adapters and side-effect tests are complete (phase 2).
2. **D5 + D6 without a model:** fully recognized programs, find results, sheet,
   Apply/Discard/Revert, history, conflicts and failure states. Complete the
   prerequisite service gate here before exposing ensure tools.
3. **D3 + D4 production:** SDK endpoint, separate agent adapter, incremental
   parsers, structured events, budgets and cleanup. Enable Claude first, then
   Codex/Gemini only after their real-client confinement tests pass.
4. **Integration/polish:** finds into the picker, tuned examples and planning
   Wizard post-plan fixes through the same surface.
5. **Explicit surface expansion:** sound/overlay editing, speed, captions,
   transitions, framing, track and render settings, each with typed validation,
   complete diff coverage and atomic-run tests. Implemented against the existing
   editable model, excluding the unsupported operations described above. Full Xcode validation remains
   pending. No initial UI-parity claim.

## Tests

- `ClipFilterTests`: people/tags/role/track/time overlap, bumper exclusion,
  unknown scores/timings, project scope, hidden/excluded defaults and pagination.
- `BuilderScriptTests`: JSON round-trip, reject malformed/oversized/nonfinite
  input and unauthorized assets; typed refusals/unchanged outcomes, created-ID
  bindings, actual clamped values, fixed bulk targets and declared ordering.
  Any refused step makes the entire run non-applicable, even after valid edits.
- Split/precision: speed-adjusted source continuity, endpoint/sliver rejection,
  main/cutaway identity and fade/transition policy; millisecond speech cuts survive
  packing. Test pause bumpers across lanes, role loss, crop merging/orphans,
  and different `at?` defaults with meaningful multi-command sequences.
- `BuilderScriptSessionTests`: exact in-memory clone identities; zero writes,
  pending saves, UI callbacks and undo registrations during transient editing,
  including flush/discard/load paths. Scene/resource changes obey snapshot policy.
  Diff every document field and indirect layout effect against a fixed baseline.
- **Atomic undo:** N commands (including compound helpers) produce exactly one
  registration on Apply; undo equals the full before snapshot, redo equals the
  applied snapshot, even if scene metadata later changes. Manual edits stack on
  top. Missing manager refuses Apply. Query-only/failed runs register nothing.
- **Persisted Revert/commit:** full snapshot envelope round-trips IDs/hydrated
  values; Revert works after relaunch with no undo history. New Apply replaces
  only the last before-version; failed/discarded runs do not. Test stale revision,
  timeline/profile switches, save ordering, transaction failure/crash recovery,
  missing/corrupt snapshots, run status on undo/redo and later-edit Revert preview.
- Prerequisite adapters: every capability outcome, completed-empty reuse,
  deduplication, cancellation/profile switches, errors without sheets, exact
  replacement scope and decision preservation, controlled live hydration.
  Library changes remain after failed run, Discard, Undo and Revert.
- `BuilderRequestParserTests`: find/query programs and mutation expansion;
  full recognition, negation, ambiguous names, unknown phrases/qualifiers,
  query-only results and provider-free operation. No partial interpretation.
- `MCPServerTests`: negotiated initialize/initialized, protocol rejection, tool
  schemas and typed errors, JSON POST/202 notification/GET 405 or correct SSE,
  bearer/Origin/Host rejection, limits, cancellation, duplicate requests and
  shutdown with active calls. Test SDK transport, not only hand-built requests.
- `BuilderAgentRunTests`: exact per-provider launch/config/token delivery;
  split UTF-8/JSONL, partial/final/error events, bounded stdout/stderr/logs,
  no retry/fallback, time/call/item budgets and no late mutation after freeze.
  Verify environment/cwd isolation, credential handling and process-tree cleanup.
- Integration: StubAI exercises known query/mutation/diff flows; **real installed
  Claude/Codex/Gemini clients** exercise handshake/auth/tool calls and stream
  parsing against scratch data. Negative tests attempt native shell/file/web,
  unrelated MCP and inherited hooks/plugins. A stub HTTP caller cannot replace
  these compatibility/confinement tests. Never use the user's live Library.

## Resolved questions

1. **Always manual Apply.** One small-looking operation can move every lane or
   drop framing; change count is not a safety threshold (`BuilderStore.swift:1057`, `:939`).
2. **No Library tagging/marking tools in this scope.** Timeline snapshots cannot
   undo them. Only explicitly disclosed prerequisite adapters may write Library
   data, with the persistent replacement effects specified in D1.
3. **Route `builder_agent` like other tasks, restricted to validated adapters.**
   Claude-first rollout is practical, not a permanent default or sandbox claim.
   Strict MCP configuration alone does not confine native tools (D4).

### Builder screen command parity

`set_text_style.style` accepts only `fontsize` (integer 8...400), `fontcolor`,
`fontfamily`, `bold`, `italic`, `bgcolor`, `box_opacity` (0...1), `box_radius`
(finite ≥0), `opacity` (0...1), `stroke_color`, `stroke_width_em` (0...1),
`shadow_opacity` (0...1), `highlight_color`, `design` (`hero` / `tag` / null), `kicker`, `accent_color`.
Omitted fields stay unchanged. Explicit null clears `bgcolor`, `box_radius`,
`stroke_color`, `highlight_color`, `design`, `kicker`, and `accent_color`.
Colors follow the renderer: white/black/red/yellow, #RGB/#RRGGBB or 0x hex
(the renderer reads the first six digits of longer hex values). Unknown fields,
wrong types, nonfinite numbers and out-of-range values are refused.
`set_text_position` clears free x/y placement; `set_overlay_position` sets it.
Crop edits retain store normalization: adjacent Full Screen blocks merge immediately,
so splitting a Full Screen stretch may be unchanged. Named crop blocks retain splits.

Timeline and clips results expose clip bumperMode, volume, position, cropFraction,
and muted. On the first page they also expose sound rows (id/name/volume/start/duration)
and text, image and overlay-block rows. Text includes preset and fractional placement,
fontsize, fontcolor, bold, italic and design; images include name, x/y, width and opacity.
`get_document_summary` uses the same compact lane rows without asset paths; text is
bounded to 1000 characters. Saved templates and the Lower Third logo are captured at
session creation, with no live template lookup during execution. The built-in name
Lower Third is reserved. Duplicate case-insensitive template/person names are refused.
No MCP tools or agent tool permissions are added.
