# One AI icon, an AI info popup, and copy/paste of run settings

September 6, 2026. Same format as the other plans: numbered build order,
effort (S = a day or two, M = about a week), dependencies, decisions.

## The ask

Replace the per-vendor AI logos scattered through the app with one standard
AI icon shown on analyzed files, scenes, and generated videos. Clicking it
opens a popup with everything AI-related about that item: which model did
which job (tagging, transcript, people, naming, curation, planning,
captions, critique, cover) and every setting the run used (prompts,
instructions, sample interval, durations, format, framing, music, and so
on). The popup has Copy Settings with a choice of what to copy (only model
settings, only prompts, options, sources, or everything). The user can then
paste those settings into the Wizard or the Analyze options and run again.

## What exists

- `AIProvenance` (provider, model, task, date, fellBack) and per-record
  accessors: `VideoRecord.visualAnalysisProvenance`, `.speech…`, `.people…`,
  `.naming…`; `SceneRecord.curationProvenance`, `.framingProvenance`;
  `GeneratedVideoRecord.planProvenance`, `.caption…`, `.critique…`, `.cover…`.
- `ProvenanceBadge` / `ProviderLogo` / `ProvenanceDetails` / `ProvenanceRow`
  in `ClipBuilder/Views/ProvenanceBadge.swift`, used in AnalyzeView,
  ScenesView, LibraryView/reel cards, transcript and curate sheets, settings.
- `analysis_runs` stores name, instructions, provider, model, sample_interval,
  notes_json. `generated_videos` stores wizard/caption/cover/critique
  provider+model, rationale, quality_json, plan_clips_json, timeline_json.
- `WizardOptions` (not Codable) is built from `@AppStorage("wizard.*")` keys
  in WizardView; `AppStore.lastWizardOptions` holds the last run in memory
  only. Analyze options live in `UserDefaults` keys `analysis.*`.

## Decisions (settled)

- **D1.** One icon everywhere: SF Symbol `sparkles`, neutral tint, same size
  as today's badge. Vendor logos survive only inside the popup.
- **D2.** Settings are captured at run time and stored with the record, so
  the popup shows what actually ran, not the current defaults. Older rows
  without a snapshot show "Settings not recorded for this run".
- **D3.** Copy goes to the system pasteboard as a custom JSON type
  (`com.mokotti-solutions.clipbuilder.ai-settings`) plus a readable
  plain-text fallback. Paste reads the custom type. Works across projects,
  profiles, and app relaunches.
- **D4.** Paste never runs anything. It fills the Wizard form or the Analyze
  options and shows a banner "Settings pasted from <name>" with Undo. The
  user still presses Generate / Analyze.
- **D5.** Copy scopes are checkboxes: Models, Prompts & instructions,
  Options, Sources. "Everything" ticks all. Sources means the selected
  analysis runs, source people, scene stack level, and for outputs the
  source videos/scenes the plan used; pasting Sources that no longer exist
  in the target project skips them and says so.

## Phase A — Capture

### 1. Codable run settings  (S)
`AnalysisRunSettings` (instructions, sampleInterval, includeTranscript,
language, detectPeople, autoZoomUnframed, breakdownTags, trimRange, notes,
provider/model chosen) and `WizardRunSettings` (every WizardOptions field
that is user-chosen: format, target duration, audio/text/caption settings,
instructions, taste preset, template label+JSON, framing, layouts,
transitions, branding, critique loop, review cuts, podcast framing,
selected run ids, source people, curated-only, stack level, model override).
Make WizardOptions convertible to/from it. Exclude derived blobs
(accountBenchmarks) and anything not user-chosen.
- Depends on: nothing.

### 2. Persist snapshots  (S)
`analysis_runs.settings_json` and `generated_videos.settings_json` (TEXT,
via the migration list, bump schemaVersion). Write them where runs start
(`AppStore.analyze` → saveAnalysis; `runWizard` → insertGeneratedVideo, also
for Builder renders with the Builder's export settings). Add a
`models_json` per record listing (role → provider, model, date) so the popup
has one source of truth: analysis roles (tagging, transcript, people,
naming, podcast exchanges), scene roles (curation, framing, narrative),
output roles (plan, captions, critique, cover, lower thirds).
- Depends on: 1.

## Phase B — One icon and the popup

### 3. `AIInfoButton`  (S)
Replaces `ProvenanceBadge`/`ProvenanceRow` at every call site with one
`sparkles` button, tooltip "AI details". Hidden when the record has no AI
data at all. Sources row, scene card, output card, Wizard results, review
and transcript sheets.
- Decisions: D1. Depends on: 2.

### 4. `AIInfoSheet`  (M)
Popover (or sheet when tall) with three sections: **Models** (a row per
role: role, vendor logo, model name, date, fallback flag), **Settings**
(grouped as Prompts & instructions, Options, Sources; values rendered
readably, long prompts in a scrollable box with Copy), and **Result notes**
(rationale, critique summary, quality report link) when present. A footer
with Copy Settings… and, for outputs, Open in Builder.
- Decisions: D2. Depends on: 2, 3.

## Phase C — Copy and paste

### 5. Copy Settings…  (S)
Popover from the footer: four checkboxes (Models, Prompts & instructions,
Options, Sources), Everything toggle, Copy. Writes the JSON envelope
{kind: analysis|wizard, sourceName, copiedAt, scopes, settings} to the
pasteboard (D3) and shows "Copied" for two seconds.
- Decisions: D3, D5. Depends on: 4.

### 6. Paste into the Wizard  (M)
Wizard toolbar: Paste Settings, enabled when the pasteboard holds a wizard
envelope. Applies chosen scopes onto the `wizard.*` AppStorage keys and the
in-form state, then a banner "Settings pasted from <output name>" with
Undo (restores the previous values). Sources that don't exist in the
current project are skipped and listed in the banner. Model settings set
the model override.
- Decisions: D4, D5. Depends on: 5.

### 7. Paste into Analyze  (S)
Same for the Analyze options sheet: Paste Settings applies instructions,
sample interval, transcript, people, auto-zoom, breakdown tags, trim (only
if the same video), and provider/model; banner with Undo.
- Decisions: D4. Depends on: 5.

## Phase D — Verification

### 8. Tests  (S)
Round-trip Codable for both settings types; snapshot written on analyze and
wizard runs; envelope encode/decode; scope filtering leaves other fields
untouched; paste skips missing sources and reports them; old rows render
"not recorded"; no view references `ProviderLogo` outside the popup.
- Depends on: 1–7.

## Suggestions

- Keep `AIProvenance` and its accessors; the popup is built from them plus
  the new snapshots, so nothing already recorded is lost.
- A later "Save as preset" from the same popover would reuse the envelope.
