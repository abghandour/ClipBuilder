# AI Lessons page: make it self-explaining

Status: revision 4 (September 10, 2026) after Codex reviews 1 to 3 (all REVISE; the third was code-level). Scope is
the AI Lessons page (`ClipBuilder/Views/LearnedPreferencesView.swift`,
`ReelModelsLearnedSection.swift`, `WizardLearningSettingsSection.swift`, new
`Views/Learned/*`), its entry points, and the Training Guide. No changes to the
learned wire format, the merge, redaction, or Drive sync. Phase 1 is already
implemented on the working tree.

## Problem

The page is a faithful ledger of everything the app has learned, but it never
answers three questions a user has when they open it:

1. What is each section for?
2. Which feature actually reads it, and when?
3. Where do I change it?

## Ground truth: what each section feeds

Verified against `LearnedDocumentBuilder`, `WizardEngine.planPrompt`
(731–820), `legacyPlanPrompt` (972–1256), the caption prompt (1589–1620),
`ReelCritic` (168–182), `PerformanceLessons` (15–20), `AccountBenchmarks`.
"Used by" on the page means "some fields in this section, when the feature
runs"; the per-field qualifiers below are shown as hover help on the chips.

| Section | Source fields | Consumed by (qualifier) | Edited today |
|---|---|---|---|
| Style | `houseStyle`, `learnedHookStyle`, `learnedLayoutPreference`, `defaultPacing`, `captionLanguages` | Wizard plans (house style always; hook/layout only when `useLearnedEditingDefaults`, and then `EditingPerformanceView.load` rewrites them from results each time that screen opens); reel critic (house style); captions (languages) | House style: Settings › Taste › House Style. Pacing: Settings › Profile › Default Output. Caption languages: Settings › Profile › Brand Kit |
| Taste | `tasteRubric` + exemplar frames, `tasteCategories` | Wizard plans (rubric and category chosen by the run's taste preset; frames attached as images); reel critic (rubric only); analysis: rubric adds `highlight`, each category with a rubric adds `highlight:<key>` | Settings › Taste |
| Lessons | `wizard_lessons` rows minus `dismissedLessons` | Wizard plans (dismissed rows removed; a shared copy with the same merge key replaces the local one when newer; local and shared winners together are capped at 12,000 characters before the shared block is split out) | AI Lessons only (done) |
| Vocabulary | `tagSchema`, `hashtags` | Wizard plans (LEARNED VOCABULARY block once a Drive home is configured, contributors not required); captions (pinned hashtags seed up to seven candidates, only in the `localHashtags` branch); analysis tagging (built-in schema when empty) | Tag schema: Settings › Profile › Tag Schema. Hashtags: Settings › Profile › Brand Kit, and inline on the page |
| Benchmarks | `AccountBenchmarks` numbers, slots, hashtag lift, traits | Wizard plans (planner block); reel critic (critic block); performance-lesson distill; captions (caption block: hashtag lift, hot subjects, caption length; not posting slots). The legacy blocks carry more than the learned lines (reach, watch time, strongest/weakest reels) | Read-only here; Refresh after an Instagram import |
| People | registered people + descriptors | Wizard plans (people list); captions (people matching the reel's tags become hashtag candidates, `localHashtags` branch only) | Project › People |
| Research | fight research summaries, saved query plans | Wizard plans (local: research block when `useFightResearch`, scoped to selected footage; shared: generic SHARED LEARNING block when a contributor enables the section); captions (sentiment, story angle) | Read-only here; produced and saved from the Fight Research sheet |

Sharing: People and Research default to not shared (`Kind.defaultEnabled`).
The Share toggles never change what this Mac uses (`LearnedMerge.merge` line
42 ignores local flags); each consumer still applies its own gates above and
the merge budget. Contributor lines arrive as a separate
`## SHARED LEARNING` block. Merge conflicts resolve per matching identity:
single-value fields (house style, hook, layout, pacing, rubric, benchmark
summary) are local-wins; other identical ids are newest-wins, ties keep the
earlier candidate. Pinning affects reading order and survives re-distill; it
does not change merge precedence.

## Design

### D1. Section metadata lives in one place  (done)

`ClipBuilder/Views/Learned/LearnedSectionInfo.swift`: per `Kind` a `title`,
`purpose`, `usedBy: [Consumer]` with a per-consumer `qualifier` string (shown
as hover help), `editLocations: [EditLocation]` (zero or more; each a deep
link), and `readOnlyReason`. `ReelModelInfo` per `ReelModelItem` with
model-specific copy: Outcome predicts numeric lift over the account median,
Clip ranker predicts `keep` per clip, Taste similarity contributes visual
similarity to the critic. Tests assert every `Kind`, `Consumer`, and
`ReelModelItem` has a complete entry.

### D2. Section header becomes a card header  (done, adjust)

Title, count pill, purpose, "Used by" chips with qualifier help, trailing
action (Edit here / deep link / Refresh / read-only reason). Adjustments from
review: Vocabulary shows "Using built-in vocabulary" when the section is empty;
Style shows a caption when learned defaults are off ("Hook and layout are
stored but not used until Learned editing defaults is on") and, when on, that
opening Instagram › Editing performance rewrites them from results.

### D3. Edit here, not elsewhere  (done)

Inline editors for plain profile fields, as transactional sheets:

- Drafts initialise from the **raw profile fields**, never from displayed
  document text (the displayed document is redacted; categories are shown as
  "label: rubric").
- Sheet captures `profileName` on open; Save re-checks
  `store.activeProfile.profileName` and updates only the edited fields, then
  `saveActiveProfile()` (which timestamps and invalidates the cache).
  `saveActiveProfile` presents its own error and returns nothing, so the sheet
  closes on Save; the store's error alert covers persistence failure.
- Style: house style, hook style, layout preference (text). Pacing and caption
  languages link to Settings.
- Taste: rubric text. Categories: edit **label and rubric**, key, frames and
  study count untouched. Drop category stays.
- Vocabulary: hashtags via the existing `CommaListField` bound to a draft
  array. Tag schema links to Settings › Tag Schema.

### D4. One Lessons UI  (done)

Lessons card gains: Add a rule (saved pinned, evidence "added by you"),
Distill rules from reviews with progress and the store's error alert, and
Delete next to Dismiss. Row shows AI provenance via `AIInfoButton` when a
lesson has `provenance`.

- Refresh: `AppStore.addLesson/updateLesson/deleteLesson/distillLessons` stay
  fire-and-forget for other callers; the page observes `store.lessons` and
  `store.isDistillingLessons` (`.onChange`) and reloads its document when they
  change. No immediate `reload()` after the call.
- Dismiss remains local-only (it needs a database row) and is described
  accurately: "Hide this lesson from the Wizard and from publishing. A future
  distill may produce a similar rule with different wording." Delete: "Remove
  the row; distill may recreate it from the same reviews."
- Distill help states what it replaces: all unpinned lessons, including
  performance-derived ones.
- A "Dismissed (n)" disclosure at the bottom of the Lessons card lists
  dismissed ids with their text (looked up from `store.lessons`) and a Restore
  action that removes the id from `dismissedLessons` and bumps the lessons
  timestamp.
- Settings › AI: the Learned Rules section becomes the existing Learning
  section with a count of active local rules (rows not dismissed) and the
  existing "AI Lessons" button. `WizardLearningSettingsSection` is deleted.

### D5. "This Mac" vs "Sharing" separation  (done, adjust)

Header: title, description, sync status line, then the "Reviewing" segmented
picker **outside** the collapsible panel whenever there are visible
contributors, so the reviewed origin is never hidden. The collapsible
"Sharing with other Macs" panel holds nickname, the share checklist headed
"What leaves this Mac when you publish (these switches never change what
this Mac uses; each feature still applies its own conditions)", Preview, Publish, and mute toggles. A one-line note says trained
models are published separately from these sections. Panel auto-expands only
when a Drive home exists and no nickname is saved.

### D6. Two previews, honestly labelled  (done)

Replace the JSON-only sheet with three tabs:

1. **Learning overview** (default): `LearnedMerge.merge` output for this
   profile grouped by section, each line with origin. Losers listed with a
   reason from a new `LearnedMerge.mergeReport` that returns winners plus
   `excluded: [(line, reason)]` with reasons `overriddenByLocal`,
   `olderThanWinner`, `contributorMuted`, `sectionNotShared`, `empty`,
   `overBudget`. Labelled "What is available to the Wizard from this profile.
   Each run selects from this."
2. **Last plan prompt**: the exact text of the most recent Wizard plan
   request for this profile. `AIRunCapture` only keeps 2,000-character
   previews and the Markdown run report is written only next to a rendered
   video, so a dedicated record is added: `LastPlanRecord` (Codable) with
   `profile`, `capturedAt`, `attempts: [Attempt]` where each attempt has
   `prompt` (full text), `frames: [String]` (attachment labels), `requestedAt`,
   `provider`/`model` when known, and `acceptedAttempt: Int?`. The plan
   function writes the record after the request/retry block resolves, so a
   retry appears as attempt 2 and the accepted index says which one the
   reel used. Stored as a hidden per-profile file under the learned
   directory (`LearnedLibrary.directory/.last-plan-<stableID(profile)>.json`,
   skipped by `documents()`), overwritten each run. The tab shows the
   accepted attempt by default, a picker for the others, the attachment
   labels, and provider/model. If no record exists it says so and points at
   Generate. This is the only view labelled "exactly what the Wizard read".
3. **Shared document**: the redacted JSON, labelled "Snapshot now. Publish
   runs a pending distill first, so the uploaded document can differ."

Copy buttons on tabs 1 and 2.

### D7. Guided empty state with real predicates  (done)

Checklist rows with explicit predicates, not section counts:

- House style written: `!profile.houseStyle.isEmpty`
- Taste rubric written: `!profile.tasteRubric.isEmpty`
- Reels reviewed: count of reviews from `database.learnedEvidence().reviews`,
  shown as "n reviewed" with a hint that distill works best after a few; no
  threshold enforced
- Rules distilled or added: any non-dismissed lesson row
- Instagram insights imported: `benchmarks?.reelCount ?? 0 > 0`
- People registered: any person record

Full card when nothing is true; a compact "n of 6 sources feeding the Wizard"
strip above the sections otherwise, collapsible and remembered in AppStorage.

### D8. Trained models cards  (done)

Each card shows the model-specific copy and three states: **Requested**
(`onDeviceOverrides[item]`), **Eligible** (`report.passed && report.localEvaluation`
and the runtime check in `ReelModelEvaluation` for traits version and artifact
hash, exposed as a static helper), **Effective** (requested, eligible, and
`preferOnDevice`). The toggle binds to `onDeviceOverrides` with a `false`
default and calls `store.saveSettings()` on change. It is always available to
turn off; turning on is allowed only when eligible. When requested but
`preferOnDevice` is off the card says "Requested, inactive while on-device
processing is off" with a link to Settings › AI. A caption states the switch is
app-wide while the model itself belongs to the active profile.

### D9. Training Guide  (done, screenshot pending)

Rewrite, not append, in `ClipBuilder/Resources/TrainingGuide.html` (the
in-app guide): sections 5 and 6 now point at AI Lessons for distilling,
pinning, adding, dismissing and restoring rules (the Wizard tab no longer
hosts them); the "never runs on its own" claim becomes "runs when you click
Distill, and before Publish when reviews changed since the last distill";
section 7's table gains Style, Taste, Vocabulary, Benchmarks, People and
Research rows in user words with the same qualifiers as the page. A new
section "What the AI knows: the AI Lessons page" describes the page and its
previews, with `help-lessons.png`. `docs/ClipBuilder-Getting-Started.html`
gets the same edits. Add a capture step to `scripts/capture_help_screenshots.sh`
(the page is a sidebar destination; capture via its keyboard shortcut or
sidebar click); the script keeps the old PNG on failure, so the release
checklist requires a confirmed fresh `help-lessons.png` before the guide
change ships.

## Phases

All four phases are implemented on the working tree (September 10, 2026):
metadata, headers and sharing panel (D1, D2, D5); editing (D3, D4); previews
and checklist (D6, D7); model cards and guide (D8, D9). `help-lessons.png` still
needs a real capture before release.

Each phase builds clean and passes the unit suite before the next starts.

## Tests

- `LearnedSectionInfoTests`: complete coverage of `Kind`, `Consumer`,
  `ReelModelItem`; every consumer has a qualifier.
- `LearnedMergeTests`: `mergeReport` reasons for local-wins, older-loses,
  muted, section not shared, over budget; winners equal `merge` output.
- `LastPlanRecordTests`: prompt above 2,000 characters survives verbatim;
  attachment labels stored; retry recorded as attempt 2 with accepted index;
  two profiles write two files and reading one never returns the other.
- `LearnedFieldEditTests`: `commit` returns nil when the active profile name
  differs from the one captured at open (editor profile switching); drafts
  come from raw fields, not redacted text.
- Async refresh (page reload on `store.lessons` change) is a manual check in
  the running app: add a rule, confirm the row appears without leaving the page.
- `LearnedEditingTests`: restore dismissed lesson; category label/rubric edit
  preserves key, frames and studied count.
- `LearnedOnboardingTests` (D7 predicates) on a fixture profile and evidence.
- `ReelModelStateTests` (D8): requested/eligible/effective truth table.
- `LearnedPreferencesViewTests`: sidebar reachability; Settings › AI has no
  add-rule field; the Learning section reports the active local rule count.

## Out of scope

Wire-format changes, Drive sync behaviour, redaction rules, model training,
dismissing shared lessons (tracked as a follow-up), token-style hashtag entry.

## Resolved questions

1. Settings › AI keeps a count of active local rules plus the AI Lessons link.
2. Never auto-enable `preferOnDevice`; show requested-but-inactive with a link.
3. Hashtags use the existing comma-separated field bound to a draft.
