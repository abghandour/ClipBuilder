# Express Voice Over Plan

Date: 2026-11-20 (revised the same day: recording moved from the Source
Video player to the Rough cut sheet, per the user)
Status: implemented 2026-11-20 (uncommitted), with the recommended choices
for the four decisions. Verified by tests and a compile; not yet driven in
the running app. See "As built" at the end for what differs from the plan.
UI mockup: https://claude.ai/artifact/PiQZLXNnK36iHn9TwbFyC8

## Goal

In AI Wizard Express the user records their voice over the **finished reel**
as it plays in the Rough cut sheet (Render Preview), not over the separate
kept clips. Recording runs for as long as a button is held. Each hold is one
recording. Recordings are mixed into the reel when it is generated, and each
one can be deleted on its own.

## What the user sees

### Rough cut sheet: new Voice Over tab

`RoughCutReviewSheet` controls column, third tab after Picture and Overlays
(Express only, like Overlays).

1. **Hold to Record** button (`mic.fill`) with an input level meter. Press
   and hold, or hold the R key.
   - Recording starts at the reel's playhead. If the reel is paused, pressing
     starts it playing.
   - While held: the button turns red and counts up, the picture shows a red
     `REC 0:04` badge, and the reel's own sound is muted so the speakers do
     not leak into the microphone.
   - Release: the recording is saved and stays in the list. The reel keeps
     playing, so the next press records the next one.
   - A hold shorter than 0.3 s is discarded.
   - The button needs a rendered cut. On a cut that is not rendered yet, or
     whose settings changed, it is disabled and says "Press play to render
     the reel first".
2. **Voice lane** under the player's scrubber: one red bar per recording
   across the whole reel, with the playhead on it.
3. **Recordings list**, in reel order: play button, reel time ("0:14"),
   waveform, length, and a **Delete** button (trash icon, always visible).
   Clicking a row moves the playhead there. Delete is immediate, no
   confirmation; Command-Z brings it back while the sheet is open.
4. **Two settings rows:** "Video sound under voice" (0 to 100 %, default
   25 %) and "Include in the reel" (default on). These follow Apply and
   Discard like every other setting in the sheet.
5. Playing the reel in the sheet plays the recordings with it (a second
   audio player kept in step with the video), with the video sound lowered
   under them. No new render is needed to hear a recording, and making or
   deleting one does not make the cut stale.

Recordings are **saved as they are made**. Discard and Escape do not remove
them; the sheet's footer says so while the Voice Over tab is open.

### Express page: Voice Over panel

A card in the settings column, after Overlays. It **only lists** the
recordings: play, reel time, waveform, length, Delete. No record button.
Empty state: "No recordings yet. Press Render Preview and open the Voice
Over tab to record over the reel." The Summary tab gets one line: "Voice:
3 recordings, 0:15".

The first press of Hold to Record asks for microphone access. If it was
denied, the button reads "Microphone off" and opens System Settings >
Privacy > Microphone.

## How a recording is placed

The user records against reel time, and that is what the list shows. Reel
time alone would break as soon as the reel changes: the rough cut leaves
bumpers out, and a new transition, a Pause on contact hold, a trim or a
reorder all shift everything after them.

So each take stores **both**:

- the reel time it was recorded at, and
- the picture under it at that moment: `(video id, source seconds)`, read
  from the cut's `previewClips` (the clip whose output span contains the
  playhead, mapped back to source time).

Placement at render time (pure rule, `VoiceTakePlacement`):

- The take starts where its picture is in the reel being rendered: the first
  kept clip containing its source anchor, at that clip's output start plus
  the clip's output time for the anchor. An intro bumper or a changed
  transition therefore moves the voice with the picture.
- From there the voice plays straight through, across clip joins.
- If no kept clip contains the anchor (the clip was removed or trimmed past
  it), the take is **not in the reel**: its row is dimmed and says so, and it
  is skipped. Nothing is deleted automatically.
- A take that runs past the end of the reel is cut there with a short fade.
- A take recorded over a bumper or other non-footage picture has no source
  anchor; it keeps its reel time as recorded. (The rough cut has no bumpers
  today, so this only matters if that changes.)

The list always shows the take's time in the current reel, recomputed with
the same rule, so the page panel and the sheet agree.

## Storage

- Audio: one AAC file per take (mono, 48 kHz) under the app data folder,
  `data/voice/<profile>/<uuid>.m4a`.
- Records: new local table `voice_takes` (id, project_id, video_id,
  source_time, reel_time, duration, file, created_at). Queries in
  `Data/Database+VoiceTakes.swift`. Takes belong to the Express project and
  source video, like the reel's kept footage; New (start over) clears them
  after its existing confirmation.
- Not part of Team Sync in this version.
- Deleting a take removes the row and moves the file to a session trash
  folder, emptied when the app quits.

## Rendering

Voice is one whole-reel audio pass at the end of `WizardEngine.assemble`,
after the clips are joined and before music, shaped like the dub mix:

1. `VoiceOverMixer.buildTrack`: silence for the reel's length with each
   placed take delayed to its start (silence generated inside the filter
   graph).
2. `VoiceOverMixer.overlay`: the reel's own sound is lowered under each take
   with a 0.15 s ramp (reusing `DubPlanning.duckExpression`), the voice track
   is mixed on top, video is stream-copied.

Consequences:

- Generate and Edit-less renders carry the voice. A re-render from Play in
  the sheet does not need to bake it in, because the sheet plays the takes
  live; baking it into the rough cut file as well is optional and left out.
- No segment cache change: nothing per clip depends on the takes.
- With Dub on, both are mixed. Music sits under everything as today. Speech
  polish runs after and treats the recorded voice as speech.
- The timeline document has no audio track, so a reel opened in the Builder
  (Edit) does not carry the voice. Follow-up, out of scope.

## Recording

- `AVAudioRecorder` with metering, prepared when the Voice Over tab appears
  so a press starts within a few tens of milliseconds. The take's reel time
  is the player's time when recording actually started.
- New `VoiceRecorder` (actor) under `Services/Voice/`; the view only calls
  start and stop. The sheet is modal, but a recording is short and held by
  the user, so it is not an AppJobs job.
- Permissions: `NSMicrophoneUsageDescription` in
  `Configuration/GoogleDrive-Info.plist` (the user's local plist needs the
  same key, added by hand since agents do not edit that file), and
  `com.apple.security.device.audio-input` in
  `ClipBuilder/Clip Builder.entitlements` for the hardened release build.
  Without the entitlement a notarized build records silence, so the release
  build is checked with a real recording before shipping.

## Phases

1. **Record, list, delete in the sheet.** `VoiceRecorder`, table, placement
   rule, the Voice Over tab (button, meter, lane, list, live playback of
   takes with the reel), microphone permission. No render change. Tests:
   placement rule (reorder, trim, transition, pause, removed clip), reel
   time to source anchor mapping, table round trip, short-hold discard.
2. **In the final reel.** `VoiceOverMixer`, the assemble step, the two
   settings (Optional fields on `MiniWizardSettings`, remembered per
   profile). Tests: filter strings, an integration render that checks the
   voice is audible at the expected time and the original is lowered.
3. **Express page panel.** The list-only Voice Over card, the Summary line,
   "not in the reel" state, Command-Z after delete, R key hold.

Codex implements each phase from this plan; Claude builds, tests and drives
it live.

## Not in this version

- Editing a recording (trim, move, volume per take). Delete and record again.
- Voice in the full AI Wizard or the Builder.
- Team Sync of recordings.
- Bluetooth microphone delay correction.

## Decisions needed

1. **Video sound while recording.** Recommended: muted while the button is
   held. Alternative: a "Hear video while recording" switch for headphones.
2. **Two recordings over the same stretch.** Recommended: both kept, both
   play, rows marked as overlapping. Alternative: the new one cuts the older.
3. **Discard and recordings.** Recommended: recordings are saved as made and
   survive Discard. Alternative: Discard removes the ones made in this
   sitting, like every other change in the sheet.
4. **When the reel changes after recording.** Recommended: a recording
   follows its picture (described above). Alternative: it stays at its reel
   time no matter what moves under it.

## As built (2026-11-20)

Added at the user's request: **the voice is part of the captions.**

- Each recording is transcribed on device as soon as it is made (Apple
  SpeechTranscriber, the profile's spoken language). The text and word
  clocks are stored on the take.
- Its row shows the caption text in a field. The user corrects it there;
  words the correction keeps keep their clocks.
- With captions on, Generate shows the recording's text as captions while
  it plays, in the reel's caption style, and hides the footage's own
  caption for that stretch.
- With English captions or a dub language, the recording is translated with
  the same translation task as transcript rows. The translated text has its
  own field in the row; a correction there is never translated over, and a
  change to the original text drops the translations the user did not write.

Where it lives:

- `Data/Database+VoiceTakes.swift`: `voice_takes` table (local, not synced),
  `VoiceTake`. Audio in `<library>/voice-takes/`.
- `Services/Voice/`: `VoiceOverPlacement` (placement, captions per cut),
  `VoiceOverMixer`, `VoiceOverTranscriber`, `VoiceRecorder`.
- `App/VoiceOverLibrary.swift`: the list both screens share
  (`store.voiceOver`), live playback in the sheet, the two preferences.
- `Views/Voice/VoiceOverViews.swift`: the sheet tab, the lane, the rows, the
  Express page panel.
- `WizardEngine`: `voiceOverPlan` (placement on the document's cut slots),
  caption lines handed to `renderPlannedClip`, the mix after the join.
  `WizardOptions.voiceOverBedLevel` carries the run's choice; Express sets it
  for Generate only.

Differences from the plan above:

- Rows show the caption text, not a waveform.
- "Video sound under voice" and "Include in the reel" are per-profile
  preferences that apply at once. They are not part of Apply and Discard.
- The preview carries the recordings in its own sound: after a recording,
  a delete, or a change of level, the sheet mixes them into a copy of the
  rough cut with the same mixer Generate uses and swaps it into the player
  (`RoughCutReviewSheet.bakeVoiceOver`). It plays on every tab. The first
  version played them alongside the reel instead; the user heard nothing
  and asked for the mix (2026-11-20). The voice lane shows on the Voice
  Over tab only.
- Voice captions are drawn by Generate only. The rough cut picture does not
  show them; the text is read and corrected in the list.
- Only the last delete can be undone (Undo Delete button, Command-Z).
- New (start over) leaves the recordings in place; choosing the same video
  again in the same project shows them again.
- No Summary line yet.
- The microphone text is set in `Configuration/GoogleDrive.xcconfig` as well
  as the plist, so builds that use the local plist carry it too.

Known gaps after the Codex review (`build-debug/voice-over-review-2026-11-20.md`):

- Voice audio files are not removed when their video or project is deleted.

Fixed after the review, same day: captions are placed on the joined reel's
clock (the overlaps are predicted with `WizardPreviewClips.joinOverlaps`
before the cuts render), and a recording made partway into a pause on
contact keeps its place in the pause (`voice_takes.hold_offset`).
