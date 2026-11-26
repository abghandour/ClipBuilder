# Lip sync for the dub (Sync)

Date: November 14, 2026, revised November 26, 2026 (twice). Status: per-clip
takes ("Takes" below) are implemented and uncommitted, not yet run against
the live service; they replace the whole-reel pass of the "First cut", which
Generate no longer calls. Requested by the user on November 14, 2026 ("write
a plan for integrating sync.so lip sync into the dub"), on November 26, 2026
("add the lipsync as a toggle as part of the Audio panel when generating a
video") and later that day ("do option 2, but make sure that lipsync is done
at the raw video before camera and any overlays are added. this way we can
make modifications and reuse the same lipsync video. add some way to
visualize how much of the video is already lipsynched. in the preview panel
when cache is available use the lipsync video for preview instead of the
raw.").

## Takes (November 26, 2026): lip sync per clip of the raw recording

A take is a lip-synced copy of one stretch of a source video: full frame, the
source's own speed, the source's own sound under it. It is a drop-in for the
source over its range, so camera, crops, captions, overlays, music and the
dub mix all happen afterwards exactly as before, and a take survives every
edit that keeps its range and its dubbed lines.

- Rules and storage: `Services/SyncLabs/LipSyncTakes.swift`. Takes live in
  `<cache>/lip-sync/<key>.mp4` with a `<key>.json` sidecar (source path,
  range, model, date, cues). The key hashes the source's content
  fingerprint, the range, the model and each dubbed line's audio file,
  offset and stretch; it is also the Sync Labs idempotency key.
- Planning: `LipSyncTakes.requests(document:)` joins the pieces of one kept
  clip that continue each other in the source (a pause splits a clip) into
  one stretch, and places each dubbed line where it is heard.
- Making: `LipSyncService.takes(for:model:scratch:)` reuses what is on disk,
  sends only the missing stretches (silent raw picture plus the lines on
  silence), checks length and frame size, muxes the source sound back in.
  A stretch that fails is logged and that clip renders from its source.
- Generate: `WizardEngine.renderPrepared` makes the takes before the cuts
  are extracted and sets `LipSyncTakes.current` around the extraction.
- Renderer: `ResolvedClip.pictureTake` (Codable, so it is in the segment
  cache key) and `pictureRead`. Only the two pixel reads change: the
  placement's FFmpeg input and the framing prepass's picture source.
  Tracking, content boxes, strikes and transcripts keep the source's path
  and clock. Holds and clips with strike highlights keep the source.
- Seeing it: `LipSyncCoverageLine` under each row and `LipSyncSummaryLine`
  above the list ("Lip sync: 3 of 5 clips ready · 42 s of 60 s", with a
  bar) in both the Reel panel and the Footage list; the preview column
  plays the take, with a "Lip-synced" badge, when one covers the clip.

- Sharing (user request, November 26, 2026: "share lipsync takes between
  team members like dub takes"): `Services/SyncLabs/LipSyncTakeDrive.swift`.
  Takes go to "Lip sync takes" in the team's Drive folder as `<key>.mp4`
  plus `<key>.json` (sidecar last, with no path or file name in it).
  The folder is the index: no database row, no Supabase column, no schema
  bump. Before paying, Generate downloads any missing key the folder has.
  Keys match between teammates because they hash the recording's content
  and each line's identity (dub take id, text, voice, span, rate), not the
  local cut file's name.

Known limits: a teammate's takes show in the coverage lines only after a
Generate has downloaded them; a teammate's longer take is not reused for a
trimmed clip (exact key only); coverage is by range only, so a take made for an older wording of the
dub shows as synced though Generate would redo it; a changed fitted rate of
a line changes its audio file and so the take; nothing prunes old takes.

## First cut (November 26, 2026): a toggle in the Audio panel

The user asked for lip sync as a switch beside Dub where a reel is
generated, so the first cut is the short route this plan argued against:
the finished reel is sent once. It is the only route a generate-time toggle
needs, and it proves the service and the quality before the per-clip work.

- **Controls.** Express (Audio tab) and the full wizard (Sound & music): a
  "Lip sync" toggle under Dub, shown only while Dub is on, off by default.
  Its caption states the model and the rate; the summary line lists it.
  Without a key the toggle is disabled and the row opens Settings.
  Settings > AI > Lip Sync holds the key, Check and the model.
- **Pass.** `WizardEngine.renderPrepared`, after speech polish and before
  the quality gate, when `options.lipSync == true` and the document has an
  enabled dub: check the account's length limit, extract the reel's audio
  to WAV, upload both as assets (`reel.mp4`, `reel.wav`: no title, profile
  or person name leaves the Mac), generate with `sync_mode: cut_off` and
  `active_speaker_detection.auto_detect`, poll every 5 s, download, mux the
  synced picture with the reel's own audio (stream copy), require the same
  length within half a second, replace the file.
- **Failure.** A lip-sync failure never fails the reel: the unsynced reel
  is kept and the reel log says why. Stopping the job stops the wait.
- **What it gives up against the design below.** Captions and overlays are
  in the picture Sync sees; the whole reel is billed and re-encoded,
  silent clips included; every regenerate pays again; and here the render
  does spend, because the toggle asks it to. "The render never spends"
  still holds for the Builder, which has no lip sync yet.
- **Names.** `Services/SyncLabs/` (`LipSync` pure rules, `SyncLabsClient`,
  `SyncLabsKeychain` with item `com.clipbuilder.synclabs`, `LipSyncService`),
  `AISettings.lipSync: LipSyncSettings?`, `WizardOptions.lipSync`,
  `WizardOptionsStep2.lipSync`, `MiniWizardSettings.lipSync`,
  `Views/LipSyncToggleRows.swift`.
- **Still owed.** Phase 0 (the hand check of quality) was skipped and is
  the first thing to do with a key: one dubbed two-person reel end to end.
  Then phases 2 to 5 below replace the whole-reel pass with takes.

## Goal

An optional step after the dub: the speakers' mouths are redrawn to match
the dubbed speech. The dub itself does not change. The voice still comes
from the engine the user picked (Mac, Siri or ElevenLabs), the lines are
still reviewed in the dub review sheet, and the mix is still ours. Sync
(sync.so) only receives a piece of picture and the dubbed audio for it, and
returns the same picture with new mouths.

Off by default. It costs money per second of video and uploads footage of
people's faces to a third party, so nothing is sent without the user
starting it and seeing the price first.

## Why Sync and not ElevenLabs

Checked on November 14, 2026:

- ElevenLabs Dubbing has no lip sync ("ElevenLabs does not offer lip
  syncing as part of Dubbing") and Dubbing Studio is in maintenance mode.
- ElevenLabs sells lip sync on an existing video only in its web app, using
  other companies' models (Sync, Veed). Its API (`POST /v1/flows/video`)
  exposes none of them; the one lip sync model there animates a still image.
- Sync is the maker of two of those models and has a public API.

## What the Sync API gives us

From the Sync docs (API reference and developer guides). Items marked
"unverified" were not confirmed and are settled in phase 0.

- Base `https://api.sync.so`, header `x-api-key`.
- Upload a local file in three calls: `POST /v2/assets/upload` (`fileName`,
  `contentType`, `size`) returns `uploadUrl` and `url`; `PUT` the bytes to
  `uploadUrl` with the same `Content-Type` and no API key;
  `POST /v2/assets` (`url`, `type` of `VIDEO` or `AUDIO`) returns the asset
  `id`. Up to 5 GiB per file, subject to the plan.
- Start: `POST /v2/generate` with `model`, `input`
  (`{ "type": "video", "assetId": … }`, `{ "type": "audio", "assetId": … }`)
  and `options`. An `Idempotency-Key` header makes a retry return the same
  generation instead of a second, billed one.
- Poll: get the generation until `status` is `COMPLETED`, `FAILED` or
  `REJECTED` (also `PENDING`, `PROCESSING`); the result is at `outputUrl`.
- Options we care about: `sync_mode` (`cut_off`, `silence`, `bounce`,
  `loop`, `remap`), `active_speaker_detection` (redraw only the person
  speaking), `occlusion_detection_enabled` (hands or microphones in front
  of the mouth; slower), `temperature`.
- Models and list price per second of output at 25 fps: `lipsync-2`
  $0.04 to $0.05, `lipsync-2-pro` $0.067 to $0.083, `sync-3` $0.107 to
  $0.133. Billing is per output frame, so 50 or 60 fps footage costs
  proportionally more.
- Limits: clip length by plan (1 minute on the cheapest, 30 minutes on the
  top one); concurrent generations by plan (1 free, 3 Hobbyist, 10
  Creator); a 429 carries `Retry-After`.
- There is a cost estimate endpoint and endpoints to delete assets and
  generations (exact paths unverified).
- `lipsync-2` and `lipsync-2-pro` work on a 512 by 512 face region and
  split long videos into 30 to 40 second chunks; a clip with many cuts or
  no detectable face can time out.

## Where we stand

- `TimelineDocument.dub: DubSettings?` and `dubLines: [DubLine]?` hold the
  applied dub. A `DubLine` knows its clip (`clipUID`), its place on the
  timeline (`start`, `duration`, `stretch`) and its audio file (`audio`, a
  leaf name in the dubs cache).
- `MultitrackRenderer.render` builds each segment from its source file
  (crop, stacking, per-clip captions burned in), joins the segments, then
  mixes the dub: `DubMixer.buildTrack` makes one speech track,
  `DubMixer.overlay` puts it over the assembled video with the picture
  stream copied. Music and text overlays follow.
- `ResolvedClip` carries `sourcePath` and `sourceStart` per clip. That is
  the seam: a clip can be pointed at another file without the rest of the
  renderer knowing.
- ElevenLabs is the pattern for an outside paid service: a small
  `Sendable` client with an injectable transport (`ElevenLabsClient`), a
  Mac-local key in the shared keychain (`ElevenLabsKeychain`), a Settings
  section with Check Key, a paid-row store that serializes requests and
  survives Stop (`DubTakeStore`), a credits line in the review sheet.
- Long work runs through `AppJobs`; the dub is already a job kind (`.dub`).

## Design

### Lip sync each dubbed clip from its source, not the finished reel

For every timeline clip that has dubbed lines, we cut that clip's range out
of the source file, send it with the dubbed speech for that range, and keep
the returned file as a "lip sync take". At render, the clip is read from
its take instead of the source. Crop, stacking, captions, transitions,
music and overlays are applied by our renderer afterwards, as today.

Why not send the assembled reel once, which would be less code:

- Captions are burned into segments before assembly. A model that redraws
  the lower face must not see them.
- The whole reel would be re-encoded by Sync, including clips nobody
  speaks in. Per clip, untouched footage stays untouched and is not billed.
- Any edit (reorder, a new caption, another music track) would make the
  whole paid result stale. A take depends only on its clip's range and its
  lines, so it survives every edit that does not touch them, and the same
  clip in another reel reuses it.

### What is sent for one clip

- Picture: the source range the clip uses, with the clip's speed applied,
  so its length equals the clip's length on the timeline. Full source
  frame, no crop, no audio. Encoded once by ffmpeg at source resolution
  (capped at the model's limit).
- Audio: the clip's dubbed lines laid on silence at their offsets inside
  the clip, by the same filter the mixer uses (`DubMixer.trackFilter`), as
  WAV. Speech only: no original sound, no music.
- Options: `sync_mode: "cut_off"` (both are the same length by
  construction), `active_speaker_detection` on, the model from Settings.
- From the result we keep the picture stream only. Sync's audio is
  discarded; the render mixes the dub exactly as it does now.

### A take and its key

A take is one MP4 in a local cache folder (`<cache>/lip-sync/<key>.mp4`).
The key is a hash of everything that changes the result: the source
video's content hash, the source range and speed, each line's audio leaf
name, offset and stretch, the model and the options. No database table and
no schema change: the file's existence is the state.

The key is also the `Idempotency-Key`, so a retry after a dropped
connection never pays twice.

### The render never spends

The renderer only looks for takes. For each dubbed clip: take present, use
it; take missing or stale, render the original picture and say so in the
render log ("Lip sync missing for 1 of 4 clips"). Money is spent only by
the Lip Sync job, which the user starts.

### Controls

- Settings > AI, a "Sync" section next to ElevenLabs: API key
  (`SecureField`, Mac-local keychain item `com.clipbuilder.sync`), Check
  Key, model picker (`lipsync-2` default, `lipsync-2-pro`, `sync-3`).
- Dub review sheet, after Apply: a "Lip Sync…" button with a status line
  beside it ("Not run", "3 of 4 clips ready", "Up to date"). It opens a
  confirmation that names what leaves the Mac and the price ("4 clips,
  38 s of video, about $1.90 with lipsync-2"), then starts the job and
  closes. The same button and status sit on the Builder's dub control, so
  the feature is reachable where the dub is.
- The job (`AppJobs` kind `.lipSync`) shows in the status bar with Stop
  and a per-clip progress line. Finished takes are kept when it is stopped.
- First use shows a one-time note: the footage and dubbed audio are
  uploaded to Sync, and are deleted from Sync when the take is downloaded.

### Stored state

- `DubSettings.lipSync: Bool?` (nil is off): whether this document wants
  lip sync at render. Optional, as every new stored property on a Codable
  record must be.
- `AppSettings.ai.sync: SyncSettings?` (`model`, later options): app-wide,
  local.
- Nothing is synced by Team Sync in this plan. A teammate without the takes
  renders the plain picture and sees the "missing" line.

## Phases

0. Hand check, no code. Run one of our dubbed clips through Sync's web app
   with `lipsync-2` and `lipsync-2-pro`: a close podcast shot, a wide
   two-person shot, a fight interview with a microphone in frame. Decide
   whether the result is publishable and which model is the default.
   Confirm in the account: price per second on the plan, clip length
   limit, the estimate and delete endpoints, how long Sync keeps uploads.
   Stop here if the quality is not good enough.
1. Client and key. `Services/Sync/SyncClient.swift` (upload, generate, get,
   delete, account), `SyncKeychain`, `SyncError` with user messages (wrong
   key, plan limit, 429 with `Retry-After`, `REJECTED`), the Settings
   section. Tests with a stubbed transport, as `ElevenLabsClientTests`.
2. Planning rules. `Services/Dubbing/LipSyncPlanning.swift`, a
   `nonisolated enum`: which clips need a take, each one's source range,
   speed and line offsets, the key, the seconds and estimated price, which
   takes are present or stale. Tests next to it.
3. The job. Cut picture and audio with ffmpeg off the main actor, upload,
   generate, poll every 10 s, download, keep the picture stream, delete
   the remote files. At most as many clips at once as the plan allows.
   `AppJobs` kind, status-bar row, Stop.
4. Renderer. Resolve each dubbed clip to its take when present
   (`sourcePath` to the take, `sourceStart` to 0, speed to 1); log what is
   missing. A render test with a fake take proves the substitution and
   that timing and audio are unchanged (`compareDecoded`).
5. Controls. The button, status line, confirmation with price, the
   one-time note, the Builder entry point.
6. Live check with a real key: one English to Portuguese Express dub end
   to end, then an edit that must not invalidate the takes (reorder,
   caption change) and one that must (a re-worded line).

Each phase ends with a Debug `build-for-testing`. Phases 1 to 3 touch no
existing behaviour; phase 4 is the only change to the render path.

## Open questions

- Quality on our footage: wide shots where the face is small, profile
  views in fight footage, microphones over mouths. Phase 0 answers it.
- A visible seam between a lip-synced clip and an untouched neighbour
  (colour or sharpness shift from Sync's encode). If it shows, the take is
  graded to the source or the whole dubbed range is sent in one piece.
- Source formats: 4K, 10-bit and HDR sources may need converting before
  upload and matching after. Unverified what Sync returns for them.
- Frame rate: 50 and 60 fps sources cost double. Decide whether to send at
  the reel's output frame rate instead.
- Clips longer than the plan's limit (1 minute on the cheapest plan): split
  at a pause between lines, or refuse with a message that names the limit.
- Whether takes should travel with Team Sync and Drive like dub takes do.
  Left out until the feature has proved itself.

## Decisions

- Sync's own API, not ElevenLabs: ElevenLabs does not offer this through
  its API.
- Our voice pipeline stays. Sync's built-in text-to-speech and its
  end-to-end dubbing are not used: they would bypass the line review, the
  timing fit and the audio cache.
- Per clip from the source, before crop and captions.
- The render never calls Sync; only the job the user starts does.
- Takes are files keyed by a hash of their inputs; no schema change.

## Not in this plan

- Lip sync for anything but a dubbed clip (for example a re-worded line in
  the original language).
- Sharing takes between teammates.
- Batch runs across many reels.
- A second lip sync provider.
