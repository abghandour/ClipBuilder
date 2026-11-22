# Fight Action detail: watch, correct, retry, learn

Date: 2026-11-21. Status: approved by the user as a direction (mockup accepted), not implemented.
Mockup: design canvas "Fight Action Popup" (scoreboard, momentum chart, breakdown, action list).
This plan adds what the mockup lacks: a preview player in the popup, editing of wrong
metrics, and a retry that learns from the edits.

## What the user asked for

1. A popup for the inspector's Fight Action section with more detail and a better picture
   of the fight (the accepted mockup).
2. Watch an action inside the popup: preview player, strike highlight optional, loop optional.
3. When a metric is wrong, the user edits it.
4. Then the user asks the AI to retry, and the AI learns from the mistake.

## Ground truth (read before coding)

| Thing | Where |
| --- | --- |
| Inspector section, loop, highlight, pause on impact | `Views/AnalyzeView.swift` ~1395–1500 (state and `loopFightAction`, `findStrikeHighlight`, `holdOnImpact`), ~1795–1875 (section) |
| Sheets for this inspector are presented by the PARENT (`onResearch`, `onStory`): a `.sheet` inside the split-view child crashes AppKit layout | `AnalyzeView.swift` near `let onResearch` |
| Totals and entries behind the counts | `Services/FightScoreDigest.swift` (`fighters`, `entries`, `Entry.loopRange`) |
| Dedup and attempt pairing | `Services/StrikeStatsSummary.swift` |
| Strike detail stored in `detail` as `technique|limb|target|side` | `Services/StrikeDetail.swift` |
| Rounds, only when boundaries are known | `Services/StrikeStatsScope.swift` (`FightRoundRange`) |
| Graph | `Views/FightGraph.swift` (`FightGraphView`) |
| Highlight overlay and saved tracks | `StrikeHighlightOverlay`, `AppStore.strikeHighlight(video:time:fighterKey:detail:eventGeneration:)` in `App/AppStore+FightResearch.swift`, table `strike_highlights` |
| Events table, whole-list replace on a scoring pass, generation stamp | `Data/Database.swift` (`fight_events`), `Data/Database+Fights.swift` |
| Scoring pass, prompt, per-window call | `Services/Analyzer.swift` (`fightScorePrompt`, `scoreFightActionClaimed`, `scoreFightWindow`), `Services/FightSampling.swift`, `Services/FightAttemptParser.swift` |
| Job entry points | `AppStore.scoreFightAction(video:)`, `markStrikes(video:)` (`AppJobs`, kind `.fightScore`) |
| Points per action | `FightScoring.actionPoints` |
| Team Sync of events (natural key `video_id, at_time, fighter_key, action`) | `Services/TeamSync/SyncTable.swift`, `Data/Database+BrandSync.swift` |
| Existing learned-things page | `Views/LearnedPreferencesView.swift`, `docs/AI-Lessons-UX-Plan.md` |

## Design decisions

- **The popup is a sheet presented by the parent of `AnalyzeView`**, opened by a visible
  expand button in the Fight Action header (SF Symbol `arrow.up.left.and.arrow.down.right`,
  label "Details"). The inspector section stays as it is.
- **The popup has its own `AVPlayer`** on the same file. The inspector's player pauses
  while the popup is open. Playback logic lives in a new `@MainActor @Observable
  FightActionPlayback` (loop, highlight lookup, pause on impact, speed), written for the
  popup. `AnalyzeView` keeps its own copy for now (Phase 5 moves it over).
- **Loop, Highlight and Pause on impact use the same `@AppStorage` keys** as the inspector
  (`analyze.fight.strikeHighlight`, `analyze.fight.pauseOnImpact`) plus a new
  `analyze.fight.loop` (default true), so the choice is one choice.
- **Corrections are their own record.** A scoring pass deletes and rewrites the whole
  event list, so an edit made only in `fight_events` would be lost on Re-score. Every
  edit is saved in a new local table `fight_corrections` AND applied to `fight_events`.
  After any scoring pass the corrections are applied again.
- **`fight_corrections` stays on this Mac in this plan.** A synced table needs a Supabase
  migration and a schema-version bump that must ship with the client. The corrected
  `fight_events` rows sync as events already do. Syncing corrections is a later, separate change.
- **No new column on `fight_events`.** Whether a row was corrected is answered by joining
  the corrections.
- **Retry is an `AppJobs` job**, never work held by the sheet. The popup may stay open; it
  shows the job as running and refreshes when the events change. Closing it does not stop the job.
- **Learning has two levels.** (a) This fight: the retry prompt states the reviewer's
  corrections for the window, and corrections are re-applied on the result. (b) Every
  later fight of the profile: corrections are distilled into a short list of scoring
  lessons that `fightScorePrompt` includes. Lessons are visible and removable.
- **`AnalysisPipeline.fightScorePass` is not bumped** by adding lessons or correction notes
  to the prompt: a bump would mark every scored fight as stale.
- Pure rules go in `nonisolated enum`s under `Services/` with tests next to them.

## Layout

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Fight Action   A vs B · 15:00 · scored v3   [Whole|R1|R2|R3]  [Retry…] [Done] │
│  33  A ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  B  28  │
│ ┌ Momentum (tall graph, round dividers, one marker per action, playhead) ───┐ │
│ └───────────────────────────────────────────────────────────────────────────┘ │
│ ┌ Preview ──────────────────┐ ┌ Actions · 51  [All][A][B][Significant][TD]  ┐ │
│ │        player 16:9        │ │ 11:39  B left kick to the legs    +1        │ │
│ │  (highlight overlay)      │ │ 11:48  A right punch to the head  +3  ✎     │ │
│ │ ◀frame ▶/❚❚ frame▶  0.5×  │ │ 11:52  B right punch to the head  +2  ✓     │ │
│ │ [Loop][Highlight][Pause]  │ │ …                                           │ │
│ ├ Selected action ──────────┤ │                                             │ │
│ │ Fighter [A▾] Action [▾]   │ │                                             │ │
│ │ Technique Limb Landed on  │ │                                             │ │
│ │ Time 11:48.2 [Set to play]│ ├─────────────────────────────────────────────┤ │
│ │ [Correct ✓][Not an action]│ │ [+ Add action at playhead]   3 corrections  │ │
│ └───────────────────────────┘ └─────────────────────────────────────────────┘ │
│ ┌ Breakdown: technique · landed on · impact · by round (mirrored bars) ─────┐ │
└──────────────────────────────────────────────────────────────────────────────┘
```

Minimum sheet size 1100 × 820, resizable. The breakdown row scrolls with the sheet's
content if the window is short; the player keeps a bounded frame (no fixed-height
sections inside a split child: see the SplitView crash note in memory).
Rows are described by fighter and action, never by transcript words. The list is a
`ScrollView` + `LazyVStack` of rows, not `Table` (Table in a collapsing container crashed
on the macOS 26 beta). All header and control text is `lineLimit(1)` + `fixedSize` or
`ViewThatFits`.

## Phase 1: the popup, read-only, with the preview player

New:
- `Services/FightActionDetail.swift`: `nonisolated enum`. From `[FightEventRecord]`, the
  people and optional round ranges: per-fighter points and share; rows for the list (one
  per deduplicated strike and per attempt sequence, the same units the totals count, each
  with fighter, sentence "right punch to the head", impact label, points, `loopRange`);
  breakdown tables (technique incl. knee and elbow when present, landed on, impact,
  left/right limb, takedowns and submissions as done/attempted, per round); marker list for
  the graph lanes. Scope filter (whole fight or one round). Unattributed events are a
  third, grey group, never dropped.
- `Views/Fight/FightActionDetailSheet.swift` (+ small files for the list, breakdown,
  preview column), `Views/Fight/FightActionPlayback.swift`.
- Preview column: player, play/pause, frame back/forward, speed (0.25×, 0.5×, 1×), toggles
  Loop, Highlight, Pause on impact. Selecting a row seeks to its `loopRange` start and
  plays; with Loop on it repeats, with Loop off it plays the range once and pauses at the
  end. Clicking the graph seeks and selects the nearest action within 1 s, else just seeks.
- Graph: reuse `FightGraphView` taller; add the two marker lanes and round dividers either
  as options on it or as an overlay view. Do not change how the inspector's small graph looks.
- Expand button in the Fight Action header; parent presents the sheet; inspector player
  pauses on open.

Done when: opening, selecting, looping, highlight on/off, pause on impact, scope switch all
work on a scored fight, and the counts in the popup equal the inspector's counts.

Tests: `FightActionDetailTests` (counts equal `FightScoreDigest.fighters`, scope filter,
unattributed group, sentences, breakdown sums equal strike totals).

## Phase 2: corrections

New table (local, in `Database.swift` schema + migration-free `CREATE TABLE IF NOT EXISTS`):

```
fight_corrections(
  id INTEGER PRIMARY KEY, video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,              -- edit | remove | add | confirm
  at_time REAL NOT NULL,           -- the AI's original time (add: the user's time)
  fighter_key TEXT NOT NULL,       -- the AI's original fighter ('' for add)
  action TEXT NOT NULL,            -- the AI's original action ('' for add)
  detail TEXT,                     -- the AI's original detail
  new_time REAL, new_fighter_key TEXT, new_action TEXT, new_detail TEXT,
  new_end_time REAL, new_outcome TEXT, new_target_key TEXT,
  created_at TEXT DEFAULT (datetime('now')))
```

- `Services/FightCorrections.swift`: `nonisolated enum` + `FightCorrectionRecord`.
  `apply(_ corrections:, to events:) -> [FightEventRecord]`: a correction matches the
  event of the same fighter and action family nearest its original time within 0.6 s;
  `edit` rewrites it, `remove` drops it, `confirm` leaves it, `add` inserts unless an
  event of the same fighter and action family already sits within 0.6 s of it. Points
  always come from `FightScoring.actionPoints` for the final action. A correction that
  matches nothing after a re-score is kept (the AI may have got it right, or dropped it):
  `edit` then inserts its corrected form, `remove` does nothing.
  Editing an already corrected event updates that correction; it does not stack a second one.
- `Database+Fights.swift`: `fetchFightCorrections(videoID:)`, `saveFightCorrection` (one
  transaction: upsert the correction, rewrite the one event row in place keeping its id and
  `generation`, delete the `strike_highlights` row of the old time+fighter so the highlight
  is found again), `deleteFightCorrection` (undo: restores the AI's original values).
  `replaceFightEventRecordsReturningGeneration` applies the video's corrections to the
  incoming events inside its transaction, so every scoring path keeps them.
- Store: `AppStore+FightCorrections.swift` with `correctFightEvent`, `removeFightEvent`,
  `addFightEvent`, `confirmFightEvent`, `undoFightCorrection`; each reloads
  `fightEvents[video.id]` and bumps `strikeHighlightRevision`. Errors go through
  `ErrorLog.record`.
- UI, "Selected action" panel: Fighter (the roster + Unattributed), Action, and for strikes
  Technique, Limb, Landed on; for attempts Outcome and hold; Time with "Set to playhead"
  and ±1 frame; buttons "Correct" (confirm), "Not an action" (remove), "Undo correction".
  "+ Add action at playhead" under the list. A corrected row shows a pencil, a confirmed
  row a tick, a removed action stays in the list struck through under a "Removed" filter
  chip so it can be brought back. The header shows "N corrections".

Verify before coding (Team Sync): changing fighter, action or time changes the row's
natural key. Read `Database+BrandSync.swift` for how a changed or deleted `fight_events`
row reaches a peer. If a peer would keep the old row next to the new one, say so in
HANDOFF and stop before Phase 2's store work; do not invent a sync change.

Tests: `FightCorrectionsTests` (each kind, the 0.6 s match, a re-score that fixed the
mistake, a re-score that repeated it, edit-then-edit, undo, points recomputed), database
tests for the transaction, highlight row removal, and corrections surviving
`replaceFightEventRecords`.

## Phase 3: retry with the corrections

- "Retry…" in the popup header opens a small confirmation popover: "Score again using your
  N corrections" with scope **Corrected stretches** (default: the sampling windows that
  hold at least one `edit`, `remove` or `add`) or **Whole fight**. Starts a `.fightScore`
  job (`AppStore.retryFightScoring(video:scope:)`), guarded by `fightScoringInFlight`.
- `FightCorrections.promptNotes(for window:, corrections:, roster:) -> String?`: a
  "REVIEWED BY A PERSON" block listing only that window's corrections in plain sentences
  with timestamps ("At 708.2s the right punch to the head was thrown by <B>, not <A>." /
  "At 712.0s there is no strike: the blow fell short." / "At 715.4s <A> landed a left kick
  to the legs that was missed."), followed by "Treat these as facts. Score the rest of the
  window with the same care; these show the kind of mistake made here before."
  `fightScorePrompt` gains an optional `corrections:` argument placed after the fighters block.
- Partial retry: re-score only the chosen windows, replace the events inside those
  windows' time spans, keep the rest, then write through the same replace call (which
  re-applies corrections). Follow how `scoreFightActionClaimed` builds windows and the
  generation check; a partial pass records an analysis-pass note saying it was a retry of
  N windows. If a partial pass cannot be done cleanly with the existing window plumbing,
  ship **Whole fight** only and say so in HANDOFF.
- After the job: the popup shows a one-line result, "Retry changed 6 actions in 2
  stretches: 4 added, 1 removed, 1 re-attributed", computed by
  `FightCorrections.difference(before:after:)`.

Tests: prompt notes text, window selection, difference summary; an Analyzer test with an
injected AI response proving corrections survive a retry.

## Phase 4: lessons for later fights

- New local table `fight_scoring_lessons(id, text, source_count, created_at, enabled)`,
  per profile database.
- `AITask` case `fightLessons = "fight_lessons"` with its `AICatalog` entry (label
  "Fight scoring lessons", default provider and chain as `.distill`). Prompt builder
  `FightCorrections.lessonsPrompt(corrections:, roster descriptors:, existing lessons:)`:
  asks for at most 8 general rules, each one sentence, about how to score fight stills,
  with no fighter names, times or fight-specific facts; return the full replacement list
  as JSON `{"lessons": ["…"]}`; parsed with `AIResponseParser.jsonObject`.
- Runs as the last step of the retry job when the profile has at least 5 corrections not
  yet folded into lessons (track with a `folded` flag column on `fight_corrections`, or a
  watermark id in the lessons table: pick the simpler). Failure of this step never fails
  the retry; it is logged.
- `fightScorePrompt` gains `lessons: [String]`, rendered as "LESSONS FROM EARLIER
  REVIEWS" before "OTHER RULES", enabled lessons only, capped at 8.
- Visible control: a "Fight scoring" section on the AI Lessons page
  (`LearnedPreferencesView`) listing each lesson with a toggle and a remove button, and
  "Learned from N corrections". The popup's result line says "2 lessons updated" and
  links there.

Tests: prompt builder, parser (bad JSON leaves the old lessons), cap, disabled lessons
left out of the prompt, the watermark.

## Phase 5 (optional, after a live pass): one playback implementation

Move `AnalyzeView`'s loop, highlight and pause-on-impact state onto `FightActionPlayback`
and delete the duplicate. Separate change; skip if Phase 1–4 are not yet verified live.

## Not in this plan

- Syncing corrections or lessons to the team (needs a server migration with the release).
- Changing how points are weighted, or the Express Fight metrics grid.
- Editing round boundaries.

## Risks

- A correction that no longer matches after a re-score can produce a duplicate of an event
  the AI moved by more than 0.6 s. The "N corrections" list in the popup lets the user
  remove it; the difference summary makes it visible.
- Prompt growth: correction notes are per window and lessons are capped at 8.
- Two instances on one library: all correction writes are single transactions; no sweeping
  of rows based on in-memory state.
