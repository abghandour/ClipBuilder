# Critic Brief Plan

Date: September 27, 2026. Status: draft for review. Implementation: Codex; build,
tests and review: Claude (per the September 23 working rule).

## Problem

The reel critic (`ClipBuilder/Services/ReelCritic.swift`) grades a rendered reel
against a *description* of good, never against good reels. Its reference material
today is:

- `BrandProfile.tasteRubric` and `houseStyle` as prose (house style is itself
  distilled from analyzed Instagram templates, not from the owner's own picks);
- `AccountBenchmarks.criticBlock()`: top/bottom-quartile numbers for the account;
- one-line scores from the on-device outcome and taste-similarity models
  (`ReelModelScoring.criticLines`), which only exist once 40 labeled reels are in.

The owner's actual taste lives elsewhere and never reaches the judge:

| Signal | Where it lives | Reaches the critic? |
| --- | --- | --- |
| Generated reels the user starred | `generated_videos.favorite` (`setGeneratedVideoFavorite`) | No |
| Generated reels that performed | `GeneratedVideoRecord.audiencePercentile` | Only as aggregate benchmarks |
| Reference reels from studied accounts | `reel_traits.reference = 1` (`computeReelTraits`, `!account.isOwn`) | No |
| Pairwise picks (A beat B) | `preferences` table (`addPreference`) | No |

Result: the critic is consistent with generic short-form craft, not with this
account. The user's ask, "judge whether a video is good based on a sample of other
good videos", is exactly the missing input.

## Goal

Give the critic a **brief**: a cached, per-profile bundle of (a) rules distilled
from the owner's exemplar reels and (b) a few exemplar contact sheets, so every
critique compares the rendered reel with concrete examples. Then **measure** the
critic against the owner's own labels before and after, and keep the brief only if
agreement improves.

Non-goals: a persistent conversational "critic agent", tool use by the critic, or
changing the planner. The critic stays a narrow, stateless judge; that is what
makes its scores comparable across runs and evaluable.

## Design

### D1. Exemplar pool

`CriticExemplars.select(database:profile:excluding:limit:)` (new,
`ClipBuilder/Services/CriticBrief/`) returns up to `limit` (default 6) exemplars
ranked by strength of evidence:

1. Generated reels with `favorite == true` **and** `audiencePercentile >= 75`.
2. Generated reels with `favorite == true`.
3. Generated reels with `audiencePercentile >= 75` (published, performed, not starred).
4. Reference reels: `reel_traits` rows with `reference = 1` that have a local file
   (`importedReelPath` or `IGMediaRecord.localVideoURL`).

Within a tier, newest first. Exclusions, applied always:

- the reel under review and every reel sharing its `batchID` (sibling versions of
  the same run are near-duplicates and would leak the answer);
- files that no longer exist on disk (skip, log once).

The pool is a pure function over fetched rows so it is unit-testable without a
database. Fewer than 2 exemplars means **no brief**: the critic runs as today and
the log says why ("Critic brief: 1 exemplar, need 2. Star a generated reel or
import reference reels.").

### D2. The brief

```swift
nonisolated struct CriticBrief: Codable, Sendable, Hashable {
    static let version = 1
    var key: String                 // D3
    var builtAt: Date
    var rules: String               // distilled text, five fixed sections
    var exemplars: [Exemplar]
    var provider: String?, model: String?

    struct Exemplar: Codable, Sendable, Hashable {
        var id: String              // "generated:123" | "reference:<mediaID>"
        var label: String           // "REFERENCE A" … "REFERENCE F"
        var why: String             // "starred + top 10% of account" | "starred" | "top quartile" | "studied account"
        var duration: Double
        var traits: ReelTraits?     // cached, may be nil for generated reels not yet traited
        var sheetPath: String       // contact sheet JPEG, relative to the brief folder
    }
}
```

**Contact sheet.** One JPEG per exemplar: four frames (0.3 s, 1.8 s, midpoint,
end - 0.4 s) tiled horizontally at 384 px tall, ~1400x384, quality 0.6. Built with
`ThumbnailService.jpegFrames(url:at:)` and Core Graphics, off the main thread.
Four frames per exemplar keeps six exemplars under the payload of one critique's
own twelve frames. Frames of exemplars are never sent individually.

**Rules text.** One `task: "distill"` call (already routed to Fable, 180 s
timeout) over: the exemplars' `ReelTraits` as a table, each exemplar's `why`, the
contact sheets as images, `tasteRubric`, and the current house style. Output is
plain text with the same five headers house-style distillation uses (HOOK,
DURATION & PACING, STRUCTURE, TEXT & OVERLAYS, MUSIC & AUDIO), each 2-4
checkable bullets phrased as *what the owner's good reels do*, plus a sixth
section `DO NOT REWARD:` for traits the reference set shows the owner does not
value. The prompt states that the rules will be used to grade other reels and must
be checkable from sampled frames.

Files live under `SettingsStore.cacheDirectory/critic-brief/<profile key>/`:
`brief.json` plus `sheet-<n>.jpg`. Same layout rule as `LookSamples`.

### D3. Cache key and staleness

```
key = sha256( CriticBrief.version
            | ReelTraits.version
            | sorted exemplar ids
            | per exemplar: file size + mtime via FileManager.attributesOfItem
            | sha256(tasteRubric) | sha256(houseStyle) )
```

`FileManager.attributesOfItem`, not `URL.resourceValues`, per the LookSamples
lesson (resourceValues caches per URL value and served stale looks on
September 12). The key is computed from the *would-be* pool at critique time and
compared with `brief.key`:

- equal: use the cached brief;
- different, brief exists: use the cached brief, log "Critic brief is stale
  (favorites changed); refresh from Wizard > Critic Brief", and do **not** rebuild
  inside the Wizard run. A run that rebuilds its own judge mid-batch produces
  scores that are not comparable across its versions;
- different, no brief: build once, inline, before the first critique of the run,
  with its own log lines. The Wizard is already a long store-owned job, so this
  does not violate the async rule; it adds one distill call and a few frame reads.

### D4. Building as a job

New `AppJobKind.criticBrief` ("Critic Brief", channel `wizard`), apply-on-finish
(no review sheet), started from a **Refresh Critic Brief** button in the Wizard
inspector next to the critique-loop toggle, and from Settings > AI where house
style is distilled. Rules from the Async AI Actions plan apply: start dismisses
nothing (it is a button, not a sheet), progress = exemplars sheeted / total, then
"Distilling…", finish posts `presentNotice("Critic brief refreshed: 6 exemplars")`.
`subjectID` = profile key so a second press while running is a no-op.

The button shows the brief's state under it as one line: "Built Sep 27 from 6
reels" / "Stale: favorites changed" / "No brief: star 2 generated reels first".
Per the Builder visibility lesson, this is a visible control, not a context menu.

### D5. Critique prompt changes

`ReelCritic.critique` gains `brief: CriticBrief?`. When present:

- Frames are ordered: exemplar contact sheets first, labeled
  `REFERENCE A (starred + top 10%) — 4 frames: 0.3s, 1.8s, mid, end`, then the
  reel under review with its existing timestamp labels and a header frame label
  `REEL UNDER REVIEW`.
- A new prompt section after "The owner's taste":

  ```
  ## Reference reels (the owner's own good ones — COMPARE, do not reward copying)
  The REFERENCE images are reels this owner rates highly. Judge the reel under
  review by the standard they set: hook choice, cut rhythm, framing, text use,
  ending. A reel that does the same things is not automatically good; a reel that
  breaks their pattern needs a reason.
  <rules text>
  A: 24.0s, 38 cuts/min, starred + top 10%     (one line per exemplar, traits when known)
  ```
- The JSON answer gains `"reference_gap": ["<what the reel under review lacks vs. the references, specific>"]`
  which rides into `notes` for the re-plan the same way `forecast_reasons` does.
- `ReelCritique` gains `briefKey: String?` so every stored critique says which
  brief (if any) judged it. That is what makes before/after measurement possible.

The "DO NOT REWARD" section is passed verbatim; the instruction "be strict, a
mediocre reel should not score above 70" stays.

### D6. Measuring agreement

New `AppJobKind.evaluateCritic` ("Evaluate Critic", channel `wizard`), started
from Settings > AI > On-device models next to Evaluate Model. It re-critiques a
fixed holdout of past generated reels twice, without and with the brief, and
writes `critic-agreement-<date>.md` into the existing `on-device-agreement` folder.

Holdout: every generated reel with a local file that has at least one label,
capped at 24, newest first, **excluding** reels that are in the exemplar pool
(they cannot be both teacher and test). Labels, in order of trust:

1. Pairwise: `fetchPreferences` rows where both reels are in the holdout. Metric:
   share of pairs where the critic scores the chosen reel higher.
2. Audience: `audiencePercentile`. Metric: Spearman rank correlation with score,
   and separately with `forecast`.
3. Favorite: binary. Metric: mean score of starred minus mean score of unstarred.

The report shows each metric for both conditions, the exemplar ids used, the
critic's provider/model, and per-reel scores. Cost is stated up front in the
button's confirmation line: "48 critique calls, about 12 frames each".

**Keep rule.** The brief ships on by default only if pairwise agreement improves
by 10 points or, with fewer than 8 pairs, Spearman against `audiencePercentile`
improves by 0.15. Otherwise the brief stays available but the critique-loop
default is "without brief", and the report says so. This is the same gate shape
`ReelModelEligibility` uses for the fitted models.

## Phases

1. **Pool + brief + cache** (D1-D3), no prompt change yet. `CriticExemplars`,
   `CriticBrief`, `CriticBriefStore` (key, load, save, sheets). Tests below.
2. **Job + UI** (D4). Refresh button, state line, notice.
3. **Prompt** (D5). Brief into `ReelCritic`, `briefKey` on `ReelCritique`,
   `reference_gap` into notes.
4. **Evaluation** (D6). Job, report, keep rule wired to the critique-loop default.

Phases 1-3 are one PR; 4 can follow. Nothing in 1-3 changes behavior when no
brief exists.

## Tests (`ClipBuilderTests/Services/CriticBrief/`)

Pure, no encoder, no AI. Run inside `scripts/release.sh` as usual.

- `CriticExemplarsTests`: tier ordering; newest-first within tier; `batchID`
  siblings excluded; reel under review excluded; missing files skipped; below-2
  returns empty with the reason string.
- `CriticBriefKeyTests`: key stable across two computations; changes on favorite
  toggle, on file rewrite (size or mtime), on rubric edit; unchanged on unrelated
  DB writes.
- `ContactSheetTests`: four frames tile to the expected size; missing frame slots
  are filled with a gray tile, not dropped (labels must stay aligned).
- `ReelCriticPromptTests`: with a brief, the prompt contains the reference section,
  one line per exemplar, and the "compare, do not reward copying" instruction;
  without a brief, byte-identical to today's prompt (snapshot).
- `ReelCritiqueParsingTests`: `reference_gap` lands in `notes`; `briefKey` is
  stored; missing keys parse as before.
- `CriticAgreementTests`: pairwise metric, Spearman, and the keep rule on fixed
  score tables.

## Resolved questions

- **Why not send exemplar frames raw?** Twelve frames per exemplar times six
  exemplars is seven times the payload of the critique itself. Contact sheets
  give the judge the hook, middle and ending of each reference at one-quarter the
  bytes of a single sampled frame set.
- **Why not rebuild the brief inside a Wizard run when it is stale?** Version 1
  and version 3 of the same run would be graded by different judges, so
  "regenerate" decisions would not be comparable. Stale is logged, not fixed.
- **Why a separate task from house-style distillation?** House style aggregates
  studied accounts' templates by performance; the brief distills the owner's own
  picks and says what *not* to reward. Both use `task: "distill"`; the prompts and
  outputs differ.
- **Why not a persistent critic agent with memory?** Providers run one process per
  call, so a "conversation" is the whole history re-sent each time. The brief is
  the durable context; it is rebuilt from data, not from chat.

## Out of scope

- Using the brief in the planner prompt (planner and critic must stay separate so
  the critic does not grade its own instructions).
- Exemplars from scenes (source footage favorites are a different signal, already
  covered by AI Favorites and the clip ranker).
- Automatic refresh on favorite toggle. Manual, plus the stale line, is enough
  until the evaluation says the brief earns its cost.
