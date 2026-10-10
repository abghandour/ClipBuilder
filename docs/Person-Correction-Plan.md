# Person Correction Plan

Date: October 9, 2026. Status: implemented October 9, 2026 (Codex), uncommitted. Verified: Debug build clean; DatabasePeopleTests 6/6, AppStoreTests 40/40, SyncEngineTests 36/36. Popover menu and name sheet not yet exercised by hand.
Implementation: Codex; build, tests and review: Claude (per the September 23 working rule).

## Problem

The people pass matched the interviewer in "Jack Della Maddalena
Interview.mp4" to the existing person Jack Della Maddalena, who really
appears only in "Jack Della Maddalena 1.mov". The wrong match carries
through everything that references the person for that video: the roster
portrait on the Sources card, every `person:` scene tag on that video's 77
scenes, the speaker turns and hand-set transcript speaker lines, person
markers, the voice profile learned from that video, topic-range speaker
keys, and the Q&A asker and answerer labels derived from them.

The only correction today is per scene, in a People-screen context menu
("Not X, move scene to…"), which also leaves the roster, speaker turns and
voice profile untouched. There is no way to say "in this video, this
person is actually someone else" and have it apply everywhere.

## Decision

Add one video-scoped operation, **reassign a person within a video**, with
three targets: another existing person, a new person, or nobody. It moves
every reference for that one video and leaves the person's other videos
untouched. It is reachable from the person popover on the Sources card
(the screenshot's surface), as a visible button, and from the same popover
when opened elsewhere with a video context.

## Data operation

`Database+People.swift`:

```swift
/// Everything that ties `from` to `videoID` now ties `to` instead
/// (nil = nobody). Other videos are untouched.
func reassignPerson(videoID: Int64, from: PersonRecord, to: PersonRecord?) throws
```

One transaction, in this order:

1. `scene_tags`: for every scene of the video, replace `from.tag` with
   `to.tag` (`UPDATE OR IGNORE` then delete leftovers, as `mergePeople`
   does), or delete when `to` is nil.
2. `speaker_turns` where `video_id = ?` and `person_key = from.key` →
   `to?.key` (NULL when nobody).
3. `transcripts` where `video_id = ?` and `speaker_key = from.key` →
   `to?.key` (NULL when nobody; the line falls back to its automatic
   label).
4. `topic_ranges.speaker_keys_json` for the video: decode, replace
   `from.key` with `to.key` (drop when nobody), encode, write back only
   when changed.
5. `voice_profiles` where `person_key = from.key AND video_id = ?`: move to
   `to.key` when `to` has no profile for the video, else delete. Delete
   when nobody. A voice learned from the wrong person must not stay on
   `from`.
6. `person_markers` where `video_id = ?` and `person_id = from.id` →
   `to?.id`.
7. `video_people`: move the row `(video_id, from.id)` to `(video_id,
   to.id)` keeping `portrait_at`, `portrait_json`, `ranges_json`, unless
   `to` already has a roster row for the video, in which case merge the
   ranges (union, sorted) into `to`'s row and delete `from`'s. Delete the
   row when nobody.
8. `person_tag_fields`: untouched (they belong to the person, not the
   video).

Then, outside the transaction: if `from` now has no `video_people` row
and no `scene_tags` anywhere, leave the record (the user may still want
them); the People screen already shows orphaned people. Do not delete.

Every table above syncs through the existing outbox triggers (`people`,
`speaker_turns`, `video_people`, `person_markers`; transcripts and
topic ranges under Phase 2). No trigger or schema change: the writes are
ordinary updates. `voice_profiles` is local only by design.

Store, `AppStore+People.swift`:

```swift
func reassignPerson(in video: VideoRecord, from: PersonRecord,
                    to target: PersonRecord?, newPersonName: String? = nil)
```

Creates the new person when `newPersonName` is given (reuse
`createPerson`), calls the database, invalidates the video's cached
portrait crops and speaker maps (whatever `mergePeople` and
`reassignScene` invalidate today; grep `previousSpeakerMaps`,
`LearnedCache`, portrait caches), logs one analysis-log line "Moved
<from> to <to> in <file>: N scenes, M speaker turns", then
`refreshAllNow()`.

## UI

**Person popover** (`Views/PersonDetailPopover.swift`), only when `video`
is non-nil. Under "In this video", a row with one visible menu button:

- Label: "Not <name> in this video" (`lineLimit(1)`, `fixedSize`,
  `controlSize(.small)`), `help`: "Move everything this video knows about
  <name> (portrait, scene tags, speaker turns, transcript lines, markers)
  to another person. Other videos keep <name>."
- Menu items: every other visible person by display name, sorted; a
  divider; "New Person…"; "Nobody (remove from this video)" with
  `role: .destructive`.
- "New Person…" cannot open a sheet inside a split-view child (file
  header comment), so it hands back through a new callback
  `onReassignNewPerson: ((PersonRecord, VideoRecord) -> Void)?`; the
  presenting screen (Sources detail pane, `AnalyzeView.swift` ~L700-1030
  where the popover is presented) owns a small name sheet, same pattern
  as the People screen's `reassignScene` name sheet. When the callback is
  nil, hide the item.
- After an existing-person or nobody choice, the popover dismisses and
  the card's roster refreshes through `refreshAllNow`.

**People screen**: no new surface. The per-scene "Not X — move scene to"
menu stays.

**Confirmation**: none for existing-person and new-person targets (the
action is reversible by reassigning back). "Nobody" shows the standard
confirmation dialog, since tags are deleted.

## Tests

- `DatabasePeopleTests` (new, under `ClipBuilderTests/Data`, using the
  fixture builders in `Support/Fixtures.swift`): one video with scenes
  tagged `from`, speaker turns, a hand-set transcript speaker, a topic
  range listing `from`, a voice profile, a marker and a roster row; a
  second video also tagged `from`. After `reassignPerson(videoID:…, to:
  other)`: every reference on video 1 names `other`, video 2 still names
  `from`, the roster row kept its portrait fields. Variants: `to` nil
  removes rather than moves; `to` already on the roster merges ranges;
  `to` already has a voice profile for the video keeps its own.
- `AppStoreTests`: the store path with `newPersonName` creates the person
  and reassigns; the log line is appended.
- Sync: `SyncEngineTests` already round-trips `video_people` and
  `speaker_turns`; add an assertion that a reassign queues outbox rows for
  the changed tables (count > 0) and no row for other videos.

## Out of scope

- Re-identifying the person automatically from the portrait.
- Making the People screen's per-scene reassign a visible control (it is
  context-menu only today, which breaks the visible-control rule; separate
  fix).
- Deleting an orphaned person record.
