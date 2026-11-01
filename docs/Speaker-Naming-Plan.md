# Speaker Naming Plan

Date: October 31, 2026. Status: draft, assigned to Codex.

## Problem

`Aljo - Ariel Helwani Interview.MP4` (video 2 in the Peace Grappler profile) is a
single-camera interview. The audio pass separated two voice clusters, but every
one of the 19 speaker turns carries `person_key = aljo`, including the turns on
cluster 1 and the turns the picture resolved to the right side. The transcript
sheet therefore shows "Aljo" on Ariel's questions.

Cause, in `PodcastSpeakerTimelineResolver.resolve`
(`ClipBuilder/Services/PodcastAnalysisService.swift`, around line 710):

1. `personBySide` maps a frame side to a person by portrait box. In a single
   camera both portraits sit near the centre, and the interviewer is on screen
   for 12 of 225 seconds, so the side map says little.
2. The per-turn fallback `layout == .singleCamera && roster.count == 1 ?
   roster.first?.key : nil` names *every* turn after the one roster person, with
   no regard for the turn's audio cluster. When the turns were named, the roster
   had one person; Ariel was added by the People pass on October 23 and nothing
   re-named the turns afterwards.

Stored evidence per turn: `cluster`, `confidence`, `picture_side`,
`picture_confidence`, `resolved_side`, `person_key`, `tile`. Roster evidence per
video: `video_people` rows with `portrait_json` (box), `ranges_json` (visible
spans), `vip`.

## Rules

- **R1. One person, one cluster.** A roster person is assigned to at most one
  audio cluster, except when the audio has exactly one cluster. A cluster that
  gets no person stays unnamed; the transcript shows "Speaker N" for it.
- **R2. Dominant cluster first.** In a single camera, the cluster with the most
  speech time goes to the person visible longest (`ranges_json` coverage; the
  only roster person when there is one). Further clusters are assigned one to
  one to the remaining roster people by overlap between the cluster's turns and
  each person's visible ranges, only when that overlap is positive. Ties and
  zero overlap leave the cluster unnamed.
- **R3. Split layouts keep the side map** but obey R1: when two clusters resolve
  to the same side, only the cluster with more weight on that side takes the
  side's person.
- **R4. Names follow the roster.** When the People pass changes a video's roster
  and that video has speaker turns on its active transcription, the speaker map
  is run again (`AppStore.mapSpeakersAgain`, no model call) as part of the
  People step, unless the transcript rows carry hand attributions, which the
  re-map already feeds back as corrections.
- **R5. Suspicious maps are flagged, not re-transcribed.** The transcript text
  and word timings are kept. The flag is a missing analysis step, "Name
  speakers", that re-runs the speaker map. Re-transcribing would cost a full
  speech pass and drop transcript edits.

## Phase 1: resolver (M)

Files: `ClipBuilder/Services/PodcastAnalysisService.swift`
(`PodcastSpeakerTimelineResolver`), `ClipBuilder/Data/Models.swift`
(`VideoPersonRecord`), `ClipBuilder/Data/Database+Videos.swift`
(`fetchVideoPeople`), tests in `ClipBuilderTests/Services/PodcastAnalysisTests.swift`.

- Add `ranges: [ClosedRange<Double>]` to `VideoPersonRecord`, decoded from
  `video_people.ranges_json` (`[{"start":0,"end":225.06}]`; empty when absent).
  `VideoPersonRecord` is not Codable and `video_people` already syncs
  `ranges_json`, so no schema or Supabase change.
- New pure function in a `nonisolated enum SpeakerClusterNaming` (new file
  `ClipBuilder/Services/SpeakerClusterNaming.swift`):
  `assign(turns: [SpeakerTurn], roster: [VideoPersonRecord], layout: PodcastLayout,
  clusterSides: [Int: PodcastSpeakerSide], personBySide: [PodcastSpeakerSide: String])
  -> [Int: String]` (cluster → person key) implementing R1 to R3.
- `PodcastSpeakerTimelineResolver.resolve` keeps its side resolution per turn and
  then sets `turn.personKey` from the cluster map. Remove the per-turn
  `roster.count == 1` fallback; R2 covers it (one cluster, one person → named;
  two clusters, one person → dominant cluster named, the other unnamed).
- Tests, using the stored turns of video 2 as fixture data (two clusters,
  roster Aljo 0–225 s and Ariel 213–225 s, single camera):
  - two clusters + one roster person → dominant cluster named, other `nil`;
  - two clusters + two people where the second person's visible range overlaps
    the second cluster → one-to-one;
  - two clusters + two people with zero overlap for the second → second `nil`;
  - split layout, both clusters on the left → only the heavier one takes the
    left person;
  - one cluster + one person → named (unchanged behaviour).
  Existing resolver tests in `PodcastAnalysisTests` must keep passing.

## Phase 2: flag and step (M)

Files: `ClipBuilder/Services/SpeakerClusterNaming.swift` (verdict),
`ClipBuilder/Data/Database+Videos.swift` (summary query), `ClipBuilder/App/AppStore.swift`
(state) and the refresh that fills `transcriptCounts`, `ClipBuilder/Services/AnalysisSteps.swift`,
`ClipBuilder/App/AppStore+Analysis.swift`, `ClipBuilder/Views/AnalyzeView.swift`,
tests in `ClipBuilderTests/Services/AnalysisStepsTests.swift` and a new
`SpeakerClusterNamingTests.swift`.

- `SpeakerClusterNaming.Verdict` from a per-video summary
  `(clusters: Int, namedKeys: Set<String>, rosterKeys: Set<String>, layout: PodcastLayout?)`:
  suspicious when `clusters >= 2` and `namedKeys.count == 1`, or when a named key
  is no longer in the roster, or when `clusters >= 2`, `rosterKeys.count >= 2`
  and `namedKeys.count < min(clusters, rosterKeys.count)`. Reason strings for
  the log and tooltip.
- `Database.speakerNamingSummaries() -> [Int64: Summary]` over the active
  transcription of every video with turns (one grouped query over
  `speaker_turns`, `video_people`, `people`, `videos`).
- `AppStore.speakerNamingSummaries: [Int64: SpeakerClusterNaming.Summary]`,
  refreshed where `transcriptCounts` is refreshed and after `mapSpeakersAgain`.
- `AnalysisSteps.Step.speakerNames` ("Name speakers"), `needsBatch == false`,
  expected for podcast and interview types, missing when the verdict is
  suspicious. `AnalysisSteps.missing` gains a `speakerNaming: Verdict?`
  parameter; both call sites in `AnalyzeView` (per-file memo and the all-files
  memo behind the table footer) pass it, so the per-file "Analyze (N steps)"
  button and the "N files · Analyze N steps" footer both count it.
- `runMissingAnalysisSteps` (single-video and batch overloads) runs
  `mapSpeakersAgain` for `.speakerNames` through a `jobs.start(.mapSpeakers …)` (existing kind)
  row so it is visible and stoppable, and the batch driver's in-place phase
  waits on it: add a `speakerMappingVideoIDs: Set<Int64>` to the store, include
  it in `continueAnalysisStepBatch`'s `inPlaceBusy`, and call
  `continueAnalysisStepBatch()` from the job cleanup.
- Sources Status column: a small `person.crop.circle.badge.questionmark` badge
  with the reason as tooltip when the verdict is suspicious (next to the
  existing badges; `lineLimit(1)` text only).

## Phase 3: re-name after the People pass (S)

Files: `ClipBuilder/App/AppStore+Analysis.swift` (`runPeopleDetection`),
`ClipBuilder/Services/Analyzer.swift` only if the batch People step needs the
same hook (it calls `replaceVideoPeople` at line 1188).

- After the People pass saves a roster for a video that has speaker turns on its
  active transcription, compare `namedKeys` with the new roster and the verdict;
  when the roster changed or the verdict is suspicious, run `mapSpeakersAgain`
  for that video (await it inside the People step so the step finishes with
  names consistent with the roster). Log one line per video. Skip when the
  video is not present on this Mac.
- Test: a pure `SpeakerClusterNaming.needsRemap(namedKeys:rosterBefore:rosterAfter:verdict:)`
  with cases: roster grew by one person → true; unchanged roster and not
  suspicious → false; unchanged roster but suspicious → true.

## Out of scope

- Grid layouts (`resolveGrid`) keep their tile logic; R1 is not applied there in
  this round.
- Re-transcription. Nothing in this plan removes or regenerates transcript rows.
- Team Sync: `speaker_turns` already sync; a re-map is pushed on the next Sync Now.

## Verification

- Debug `build-for-testing`.
- Suites: PodcastAnalysisTests, SpeakerClusterNamingTests, AnalysisStepsTests,
  AnalysisStepBatchTests.
- Live: on the Peace Grappler profile, the Aljo interview row shows the badge
  and "Analyze (1 step)"; running it names cluster 0 Aljo and leaves cluster 1
  as "Speaker 2" or Ariel; the transcript sheet shows two speakers.
