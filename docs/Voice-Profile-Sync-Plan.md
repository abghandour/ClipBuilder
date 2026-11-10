# Voice Profile Sync Plan

2026-11-09 · Status: implemented 2026-11-09, unreleased. The server migration 20261110120000_voice_profiles.sql must be applied at release time, together with the client that understands sync schema 13.

Goal: two teammates who map speakers on the same footage get the same names.
Until now the mapped result synced (turns, hand attributions, tiles, roster)
but the memory behind it did not: each Mac remembered voices only from the
videos it had mapped itself, so a re-map on another Mac could name a speaker
differently or leave them unnamed.

## What a voice profile is

`voice_profiles` holds one row per person per video: the voice fingerprint
that file taught (192 numbers from the bundled ECAPA-TDNN speaker model), how
many windows it averages, and how many of those came from the user's own
attributions. A speaker map of a new video seeds its enrollment from every
other video's rows (`fetchVoiceProfiles(excludingVideoID:)`,
`VoiceProfiles.combined`).

The model ships inside the app, so two Macs on the same version compute
compatible fingerprints. `combined` already skips a vector of another
dimension, which covers a future model change.

## Design

`voice_profiles` joins `SyncTable.footage` as an ordinary synced table. It
reverses the "never synced" line in Team-Sync-Plan.md.

- Natural key `(person_key, video_id)`, which is also the local primary key.
  `video_id` travels as the video's sync id; `person_key` is the portable
  `people.key`, like `speaker_turns.person_key`.
- A profile for footage a Mac does not have still arrives (the `videos` row
  syncs without its file) and still counts toward naming.
- Conflicts are row-level last write wins, like every other table. Two Macs
  mapping the same video offline converge on one row per person, because a
  queued row takes a deterministic identity from its natural key.
- Deleting a person, merging people, or re-mapping a video changes or removes
  rows through the existing triggers, so the team follows.

Two things needed more than a table entry:

1. **Stable row identity on re-map.** `replaceVoiceProfiles` used to delete a
   video's rows and insert new ones, which would send a tombstone and a new
   row per person on every re-map. It now updates the rows of people who are
   still heard and deletes only the rest.
2. **A moved voice is a new row.** A voice profile's sync identity stands
   for its (person, video): a queued row takes a deterministic identity from
   that key. People merges and per-video reassignments used to rename the row
   in place, which would carry the old person's identity onto the new key and
   leave two identities for one voice across the team (a first Codex review
   showed this could delete a teammate's surviving profile or make a join
   abort on the primary key). `moveVoiceProfiles` now inserts the voice under
   the new person and deletes the old row, so every Mac derives the same
   identity. `applySyncRows` additionally ignores a pulled row that would
   rename an existing identity onto a key another local row holds, instead of
   aborting the pull; no client produces such a row.

3. **A deletion names the shared identity.** A voice learned since the last
   push still carries a random identity. Deleting it then (re-map, reassign,
   merge, person removal) would send a tombstone no teammate can match, and a
   copy a teammate learned for the same person and video would come back.
   `deleteVoiceProfiles` gives such rows, and their video if it has not
   been pushed either, their shared identity first.
4. **Upgrade without reopening the join pass.** Earlier tables were seeded
   with `seedFootageSync`, which reopens the join pass; that pass lets the
   server win over unsent edits in every table. Schema 50 queues the existing
   voice rows of an attached profile directly instead.

(3 and 4 came from the second Codex review.)

## Phases

1. Client: `SyncTable` entry, local schema 50 (queues the table's existing
   rows for an already-bound profile), sync schema 13, the changes above.
   Done.
2. Tests: `SyncVoiceProfileTests` (projection, two-Mac round trip with
   replacement and removal, concurrent learning, reassignment against a voice learned elsewhere,
   an in-place rename during and after the join pass, upgrade from 49). Done.
3. Server: `supabase/migrations/20261110120000_voice_profiles.sql`. Written,
   not applied. Apply at bless time with the release that ships this client;
   the schema gate is exact, so applying it early locks out every installed
   client, and shipping the client without it stops sync for those who update.

## Consequences to know about

- Voice fingerprints are biometric data. They now leave the Mac and are
  stored in the team's Supabase project, readable by team members only (row
  level security, same policies as the other footage tables).
- A wrong profile (a voice learned under the wrong name) now reaches every
  Mac instead of staying on one. The cure is unchanged: correct the
  attribution and re-map that video, and the corrected row replaces it for
  the team.
- The first upload is a union. Before this release a correction on one Mac
  (reassigning or removing a person's voice in a video) never reached the
  other Macs' voice memory, and no deletion record exists for it. A voice one
  Mac corrected away but another still holds is uploaded by that other Mac
  and returns to everyone; where two Macs hold the same person and video, the
  last upload wins. This includes a Mac that upgrades in the middle of an
  unfinished join (third Codex review). Corrections made after the update
  propagate normally.
- Sharing the memory does not rewrite maps that already exist. Videos mapped
  before the sync keep their turns until someone re-maps them.
- First sync after the update uploads every existing profile (about 4 KB
  each).

## People page

A person's page has a "Voice fingerprint" row: "Learned from N videos" or
"None yet", with a menu to forget one video's contribution or the whole
voice. Cards in the list carry a waveform badge when the person has one.
Forgetting deletes rows through `deleteVoiceProfiles`, so the team follows.
A forgotten voice is learned again the next time a video with that person is
mapped; there is no per-person opt-out.

## Not done

- A re-map still replaces `speaker_turns` row by row, so two teammates
  re-mapping the same video at the same moment can still interleave.
