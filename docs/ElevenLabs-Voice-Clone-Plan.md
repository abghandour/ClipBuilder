# ElevenLabs voice clone per speaker

Date: November 6, 2026. Status: phases 1-4 implemented and building (Claude review fixes applied);
phase 5 live check pending.
Approved November 6, 2026 with the five defaults below. Requested by the
user on November 6, 2026: "how to choose the speaker's own voice for
ElevenLabs?" Follow-up to `docs/ElevenLabs-Dub-Plan.md`, which left cloning
out of scope.

## Goal

One click clones a speaker's voice from footage the app already analyzed,
and the dub then uses it for that person. A Portuguese interview dubbed into
English sounds like the guest, not a stock voice.

Today the user can do this by hand: cut a clean sample, upload it at
elevenlabs.io (Instant Voice Clone), Manage… › Refresh voices, then pick
"Name (cloned)" in the dub review sheet. This plan removes the first two
steps and the hunting for clean audio.

## Where we stand

- Voices are remembered per speaker key: `ProfileEditingDefaults.dubVoices`
  (`[personKey: voiceIdentifier]`), written when a dub review is applied
  with remember on (`AppStore+Dubbing.swift`). An ElevenLabs voice
  identifier is `"elevenlabs:<voice_id>"`. A clone needs no new storage to be
  used: assigning its identifier to the person's key is enough.
- `ElevenLabsVoices.voices(from:language:)` already lists account clones as
  "Name (cloned)" (category `cloned` / `professional`).
- The review sheet's voice menu (`DubReviewSheet.voicesSection`) filters by
  the speaker's gender. A clone without a gender label would be hidden from a
  speaker whose gender is known, so the clone must carry `labels.gender`.
- The app knows who talks when: `speaker_turns` (`fetchSpeakerTurns`) carry
  `personKey`, `confidence` and `cluster`; `fetchVideoPeople` gives each
  video's roster. Turns overlapping another person's turn are the ones to
  avoid.
- `ElevenLabsClient.send` handles auth, retries on 429, error mapping, and
  now logs every failure to the Errors channel.
- Long network and media work runs as an `AppJobs` job (status-bar row with
  Stop), never inside a modal sheet.

## ElevenLabs API used

- [`POST /v1/voices/add`](https://elevenlabs.io/docs/api-reference/voices/ivc/create) (multipart): `name`, one or more `files`,
  `remove_background_noise`, `description`, `labels` (JSON). Returns
  `voice_id`. Key permission: Voices › Write.
- `DELETE /v1/voices/{voice_id}` for Remove clone.
- Instant cloning needs a paid plan (Starter or higher), and each plan has a
  custom-voice slot limit. Both come back as API errors; the app shows
  ElevenLabs' own message (`keyRejected` / `badRequest` keep it).
- ElevenLabs recommends one to two minutes of clean speech; more does not
  help an instant clone much.

## Decisions (approved by the user, November 6, 2026)

1. Entry point: a "Clone voice…" button beside each speaker's voice menu in
   the dub review sheet, plus the same button on the person in People. Both
   are visible controls, never context-menu only.
2. Consent: every clone asks "I have permission from <Name> to clone their
   voice" with a checkbox that must be ticked. ElevenLabs' terms require it.
   Nothing is uploaded without it.
3. Sample: up to 120 s of the person's own turns, across all their analyzed
   videos, background-noise removal on.
4. After cloning, the clone becomes that person's remembered voice
   (`dubVoices[key]`) for this profile, and the open review switches to it.
5. Remove clone deletes it from the ElevenLabs account too (frees the slot),
   after a confirmation.

## Phases

### 1. Client calls

`ElevenLabsClient.addVoice(name:files:labels:removeBackgroundNoise:)` and
`deleteVoice(id:)`, multipart encoding in a small nonisolated helper. Error
mapping unchanged, so plan limits and permission errors read as ElevenLabs
words them. Tests with `ElevenLabsTransportStub`: multipart body (name,
files, labels JSON with gender), delete path escaping, a 4xx plan-limit body
reaching the user message.

### 2. Picking the sample (pure)

`VoiceCloneSampler` (nonisolated enum, `Services/ElevenLabs/`): from the
person's turns, every other person's turns and the transcript rows, choose
ranges that are
- the person's own turns, at least 3 s long, confidence at or above 0.6,
- clear of any other speaker's turn by 0.3 s on both sides,
- trimmed to transcript row edges so words are not cut,
- spread across videos, longest clean turns first, until 120 s.
It returns the ranges plus a reason when there is too little (under 30 s
clean): "Only 18 s of Alice alone; analyze more of her footage or pick a
voice." Tests: overlap exclusion, the 120 s cap, the too-little message,
spread across two videos.

### 3. Extract and clone as a job

`AppStore+VoiceClone.swift`: `startVoiceClone(personKey:)` starts an
`AppJobs` job titled "Clone Alice's voice". Steps, each a status line:
1. Pick the sample (phase 2).
2. ffmpeg cuts each range to mono 44.1 kHz audio in a scratch folder and
   joins them into at most a few files.
3. Upload with `addVoice`, name "<Name> (Clip Builder)", labels
   `gender` (from the person's descriptor, as the dub already infers) and
   `source: clip-builder`.
4. Refresh `ElevenLabsVoiceCache`, set `dubVoices[key]` to the clone,
   record the clone in a new optional
   `ProfileEditingDefaults.clonedVoices: [String: String]?` (person key →
   voice id) so the app can offer Re-clone and Remove, and post
   `ElevenLabsVoices.settingsChanged`.
5. Delete the scratch audio.
Stop cancels between steps and deletes a half-made clone if the upload had
already returned. Failures go through `presentError` and the Errors channel.

### 4. Controls

- Dub review sheet, per speaker: "Clone voice…" when ElevenLabs is the
  engine and the person has no clone; "Cloned" plus a menu with Re-clone and
  Remove clone when they do. The consent sheet is small and returns at once;
  the clone itself runs as the job, and the review's voice menu picks the
  clone up when the job finishes.
- People: the same button and state on the person's detail.
- Audio settings caption keeps counting clones in "N ElevenLabs voices".

### 5. Live check

Phases 1–4 are implemented. Claude must compile, address build errors, and
verify the new client/sampler tests and live flow. No xcodebuild or tests
were run during implementation. New source files use the project's
filesystem-synchronized groups.

Implementation details to verify: sampling reserves complete transcript
rows for other videos, extraction joins mono 44.1 kHz WAV samples into one
upload, and an in-flight upload finishes before cancellation cleanup can
delete its returned ID. Re-clone keeps the previous voice until the new
one is saved, then deletes the previous voice; a deletion failure retains
the new mapping and reports the old ID. Profile mappings are saved locally.

Clone Alice from "ALICE pereira interview.mov" on a scratch copy of the
Peace Grappler profile, dub the two Express transcript picks into English,
and listen. Check the Errors channel is empty, the clone shows in the account,
and Remove clone frees it.

## Not in this plan

- Professional voice cloning (long samples, verification by ElevenLabs).
- Choosing the sample by hand. Possible later: a "Sample" list of the
  chosen turns with play and remove before upload.
- Mac or Siri voices; they cannot clone.
- Team Sync of clones. A clone lives in one ElevenLabs account; another
  teammate's key cannot use it.
