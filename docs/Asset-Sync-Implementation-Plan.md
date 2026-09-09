# Asset sync, learned preferences, and trained models — implementation plan

September 9, 2026 (learned-preferences and trained-models phases added the same day). Same
format as the other plans: numbered build order,
effort (S = a day or two, M = about a week, L = two weeks or more),
dependencies, and the decision each item rests on.

## Scope

Keep the app's resource library — music, fonts, images, bumper videos,
overlay templates, and screen-crop layouts — in step with one folder in the
user's Google Drive. The user picks the folder (the "home"); a Refresh
button creates whatever resource folders are missing on either side, uploads
local files Drive lacks, downloads Drive files the Mac lacks, and reports
what moved. The feature is optional: a profile with no home behaves exactly
as today.

Second part: share what the app has learned about the brand's video
preferences between users through the same home folder, and show that
learning in one place in the app. Clip Builder does not train a model; its
"training" is the distilled text and numbers it injects into prompts (house
style, taste rubrics, wizard lessons, editing defaults, benchmark
summaries). Sharing the training therefore means publishing that context as
a document other copies of the app read at prompt time. The document is
also exactly what the "What Clip Builder has learned" view shows, so the
user sees and controls what leaves the Mac.

Third part: train small per-profile models for this brand's kind of video.
Published Instagram reels are the only data with real audience outcomes,
so they are the primary training set; internal reviews and grades are the
secondary signal. The models rank clips and score draft reels; they never
edit or generate video, and they steer nothing until a holdout shows they
beat what the app does today.

Nothing else: no sync of projects, timelines, the database, or video
sources (those keep the existing per-file Drive features).

## Decisions (settled)

- **D1. Optional.** No Drive home means no sync code runs, no new UI beyond
  the "Choose folder…" row, and no Drive traffic. Turning it off is
  "Forget folder", which leaves every file where it is on both sides.
- **D2. Home is remembered per profile; the library is shared.** The Drive
  connection, its tokens, and `drive_settings` already live with each
  profile's database, so the home folder id is stored there too
  (`drive_settings.assetHome`). The asset library on disk is one tree for
  all profiles (`~/Documents/ClipBuilder/assets`). Consequence: two profiles
  pointing at different homes both sync the same local library, each as a
  union with its own Drive folder. That is allowed and documented in the
  Settings row; it is not prevented.
- **D3. Add only.** Refresh is a union. It never deletes, trashes, or moves
  a file on either side. A file deleted on one side comes back on the next
  Refresh unless it was deleted on both.
- **D4. Newer wins on conflict.** Same relative path on both sides: equal
  MD5 means nothing to do; otherwise the copy with the later modification
  time overwrites the other, and the log names the file and the direction.
  An exact tie in time with different content is skipped and reported.
- **D5. Manual only.** Sync runs only from the Refresh button. No launch
  hook, no watcher, no timer.
- **D6. Drive mirrors the local layout.** `<home>/<kind>/<subfolders…>`
  with kind folders named `music`, `fonts`, `images`, `bumpers`,
  `overlays`, `screen_crops`. Subfolders are synced recursively. Files are
  matched by relative path and exact name. Only each kind's allowed
  extensions are considered (`AssetKind.allowedExtensions`; `.json` for
  overlays and screen crops); everything else in the Drive folder is
  ignored, never deleted. `assets/effects/previews` is excluded: those are
  rendered transition previews the app regenerates.
- **D7. Reuse the existing Drive stack.** Same OAuth connection, same
  `GoogleDriveClient` (list, findOrCreateFolder, resumable download and
  upload with checkpoints and MD5 verification), same `GoogleDriveTransfers`
  queue with its reconnect wait, offline retry, and per-file progress rows.
  Asset files never become Drive-backed media records: no `drive_file_id`
  columns, no off-load, no `DriveMediaResolver` leases. The asset library
  stays a plain folder tree.
- **D8. Scope limits are reported, not worked around.** The app holds
  `drive.readonly` plus `drive.file`. It can read and download anything in
  the home, and create files and folders there, but it can only overwrite a
  Drive file it created itself. When "newer wins" would overwrite a Drive
  file the user put there by hand, the update returns 403; Refresh logs
  "cannot replace (not created by Clip Builder)" and leaves both copies.
  Widening to the full `drive` scope is a separate decision (re-consent for
  every user; fine in Google's testing mode) and is left as a suggestion.
- **D9. Learning is shared as distilled context, not as the database.**
  The per-profile SQLite tables that record feedback (`grades`,
  `generation_reviews`, `clip_reviews`, `wizard_preferences`,
  `edit_proposals`) reference local video and scene ids and mean nothing
  on another Mac. What travels is the layer prompts already consume:
  `houseStyle`, `tasteRubric` and `tasteCategories` with their exemplar
  frames, `wizard_lessons`, `learnedHookStyle`, `learnedLayoutPreference`,
  `defaultPacing`, `tagSchema`, `hashtags`, and a numbers-only benchmark
  summary. Raw feedback is distilled into lessons before publishing (the
  existing lesson distillation), never exported as rows.
- **D10. One file per contributor, union at read.** The home holds
  `learned/<contributor>.json` (plus that contributor's exemplar frames).
  A Mac only ever writes its own file, so publishing never conflicts and
  D3 holds. When building a prompt the app merges: list-valued fields
  (lessons, taste categories, tags, hashtags) are the union, keyed by a
  stable id, newest text wins per id; single-valued fields (house style,
  hook style, layout preference, pacing) come from the local profile when
  set, otherwise from the most recently updated contributor. Every merged
  line carries its origin so the view and the AI details can say where it
  came from.
- **D11. Privacy by construction.** Never published: social cookies, any
  `ig_*` row (comments, commenter handles, follower numbers, captions),
  account usernames, absolute paths, provider API settings, on-device
  agreement (machine-specific). Off by default and per-section opt-in:
  the people registry (real names and face boxes) and fight research.
  The contributor name is the profile name plus a device nickname the user
  types once; no email or Apple/Google account identifier.
- **D12. One view, one document.** "What Clip Builder has learned" renders
  the same document that would be published, section by section, with the
  local and each contributor's contents side by side. Editing there (pin,
  dismiss, rewrite a lesson, drop a category) edits the local source of
  truth; the sharing toggles live in the same view. Nothing is shared that
  is not visible there.
- **D13. Models rank and score; they do not edit.** The trained artifacts
  are tabular models (boosted trees or logistic regression through Create
  ML, saved as Core ML per profile) over a fixed feature vector. No
  fine-tuning of language or video models: the data is a few hundred rows
  per brand, the compute is a Mac, and the distilled context of D9 already
  carries what a text fine-tune would learn.
- **D14. One trait extractor for published and draft reels.** The same
  `ReelTraits` vector is computed from a file whether it is an imported
  Instagram reel, a generated reel, or a candidate plan rendered at proxy
  quality. That bridge is what lets anything learned from published reels
  score a draft. It reuses the existing detectors (ffmpeg black, freeze,
  scene cuts; Vision faces, labels, text; frame quality; transcript
  features) rather than adding new analysis.
- **D15. Labels are lift, and the source is the account's own reels.**
  The outcome target is a reel's saves, shares, comments, and watch
  fraction relative to the account median for its posting month, so
  follower growth and platform changes do not masquerade as editing
  quality. Other accounts' reels have no insights and are used only as
  style references and comparison features, never as labels. Downloaded
  third-party reels never enter the Drive home (D11).
- **D16. Measure, then enable, and the measurement never flips the
  switch.** Each model is an on-device item like the deterministic-first
  ones: default off, a holdout evaluation the user runs, a report saved to
  the cache, and a switch the user turns on. The evaluation writes its
  report and its agreement number; it does not write the override.

## What already exists

- `AssetKind` (music, fonts, images, bumpers) with `rootURL`,
  `allowedExtensions`, and `AssetStore`: synchronous folder walk,
  `allFiles(of:)` relative listing, `importFiles` staging under
  `.import-<uuid>` with an atomic move, `createFolder`, `invalidateCatalog`,
  `registerFonts`. Overlay templates are JSON files under `assets/overlays`
  (`OverlayTemplateStore`, with a listing cache and `invalidateCache`);
  screen-crop layouts are JSON under `assets/screen_crops`
  (`ScreenCropStore`).
- `GoogleDriveClient`: `list(folder:search:videosOnly:…foldersOnly:)` with
  paging, `metadata`, `createFolder`, `findOrCreateFolder`, resumable
  `download(id:to:…)` verifying MD5, resumable `upload(file:folder:
  checkpoint:)`. `DriveFile` carries `md5Checksum`, `modifiedTime`, `size`.
- `GoogleDriveTransfers`: observable job list (`DriveTransfer` with
  operation, status, progress, message), upload concurrency of two,
  reconnect continuation, offline retry, cancel versus stop, queue persisted
  in `drive_settings`.
- `GoogleDriveBrowserSheet` with an upload mode that lets the user navigate
  to and confirm a destination folder (`uploadFolder(profile:project:)`
  remembers it in `drive_settings.uploadFolder`).
- `Database.driveSetting` / `setDriveSetting` per profile.
- Learned data already in the profile JSON (`BrandProfile`): `houseStyle`,
  `tasteRubric`, `tasteCategories` (`TasteCategory` with key, label,
  rubric, exemplar frame paths, studied count), `learnedHookStyle`,
  `learnedLayoutPreference`, `tagSchema`, `hashtags`, with
  `tasteRubricProvenance` / `houseStyleProvenance`.
- Learned data in the database: `wizard_lessons` (text, pinned, evidence),
  distilled from `generation_reviews`, `clip_reviews`,
  `wizard_preferences`, `wizard_feedback`, `grades`; `taste_studies`;
  `people`. `AccountBenchmarks` is computed on demand from the `ig_*`
  tables and summarized for prompts by `plannerBlock()`, `captionBlock()`,
  `criticBlock()`, `lessonsBlock()`.
- Prompt assembly that consumes all of it: `WizardEngine.planPrompt`
  (`benchmarksBlock`, `houseStyleBlock`, `tasteRubricBlock`,
  `trainingBlock(TrainingSignals)`), `WizardEngine.captionPrompt`,
  `Analyzer.tasteRubricPrompt`, `ReelCritic`.
- Instagram data: `ig_report_media`, `ig_media_insight_snapshots`,
  `ig_account_insights`, `ig_reel_analysis_import`, `imported_externals`,
  and `generated_video_traits`; `AccountBenchmarks` computes medians,
  sweet spots, and trait lift from them; `ReelCritic` scores drafts with
  the LLM using `criticBlock()`. Reels are already analyzed for the house
  style, weighted by performance.
- Signals a trait extractor can reuse: `VideoDetectors` (cached per
  video), `VisionImageTagger.Signals`, `FrameQuality.metrics`,
  `TranscriptFeatureAnalyzer`, `LongRecordingClassifier` inputs, scene
  tags, caption text and hashtags.
- Feedback labels: `grades`, `scenes.favorite` / `curated`,
  `generation_reviews`, `clip_reviews`, `wizard_preferences`,
  `edit_proposals.decision`.
- On-device policy and agreement reporting (`OnDevicePolicy`,
  `OnDeviceAgreement`, Settings › AI on-device rows) as the enable pattern.
- `ResourceBundle` (`ResourceCategory.profiles`, `.preferences`) exports
  profile JSON and a UserDefaults slice as a zipped bundle with a manifest
  and import policy, but nothing from the database and with no redaction.
- Tests: `FakeDriveTransport` behind the `DriveTransport` protocol, so the
  client, auth, and transfers run against scripted responses;
  `TempDirectory`, `DataFolderOverride`.

---

## Phase A — Inventory and plan (pure logic)

### 1. Sync kinds  (S)
`AssetSyncKind`: the four `AssetKind` cases plus `overlays` and
`screenCrops`, each with a Drive folder name, a local root, and an
extension filter. Local roots are injected (`AssetSyncRoots`, default
built from `AssetKind.rootURL`, `OverlayTemplateStore.directory`,
`ScreenCropStore` directory) so tests never touch the shared catalog.
- Decisions: D6. Depends on: nothing. Blocks: 2, 3.

### 2. Inventories  (S)
Two pure producers of the same shape, `[relativePath: AssetSyncEntry]`
(size, modified date, MD5 when known, Drive id when known, isFolder):
- Local: walk each kind's root synchronously (the `FileManager`
  enumerator rule from `AssetStore.folders`), skipping hidden files and
  `.import-*` staging, keeping only allowed extensions. MD5 is computed
  lazily and cached in a journal keyed by path, size, and mtime so a
  Refresh over a large music library does not re-hash unchanged files.
- Drive: starting at the home, `list` each kind folder recursively with
  `videosOnly: false` and paging; folders first, then files. Google Docs
  mime types and disallowed extensions are dropped. Two Drive files with
  the same name in one folder: keep the most recently modified, report the
  duplicate.
- Depends on: 1. Blocks: 3.

### 3. Planner  (M)
`AssetSyncPlanner.plan(local:remote:) -> AssetSyncPlan`: a list of actions
in execution order plus a report skeleton.
- `createLocalFolder`, `createDriveFolder` for folders present on one side
  only (parents before children).
- `upload` for files only local; `download` for files only in Drive.
- Both sides: equal MD5 (or equal size when Drive has no checksum) → `skip`
  (recorded as "in sync"); local newer → `replaceInDrive`; Drive newer →
  `replaceLocal`; equal time, different content → `conflict`.
- Never emits a delete. Deterministic ordering (kind, then path) so the
  report and tests are stable.
- Decisions: D3, D4, D6. Depends on: 2. Blocks: 5.

### 4. Sync journal  (S)
Per profile in `drive_settings` as one JSON value (`assetSyncJournal`):
home folder id, kind folder ids, last Refresh date and summary, and the MD5
cache from item 2. Small enough for a single row; no new table. A missing
or unparsable journal means "hash everything again", nothing worse.
- Decisions: D2. Depends on: 1. Blocks: 5, 6.

---

## Phase B — Execution

### 5. Executor  (M)
`AssetSyncExecutor` runs a plan against the client and the local roots:
- Folder creation: `findOrCreateFolder` for the kind folders under the
  home, then subfolders parent-first; local folders via
  `AssetStore.createFolder` so the catalog is invalidated.
- Downloads: to `<kindRoot>/.import-<uuid>/…`, then atomic move into
  place (the `importFiles` staging pattern). After the move, set the local
  modification date to Drive's `modifiedTime` so the next Refresh sees the
  two copies as equal in time, not "local newer".
- Uploads: `client.upload(file:folder:checkpoint:)` with the checkpoint
  under the existing transfer-files location; on success record the Drive
  id and MD5 in the journal. `replaceInDrive` uses an update on the known
  id; a 403 becomes the D8 report line, not a failure.
- Runs through `GoogleDriveTransfers` as new operations
  (`assetDownload`, `assetUpload`) so each file gets the existing progress
  row, reconnect pause, offline retry, and Stop. One Refresh is one group:
  Stop cancels the remaining actions and discards partial staging, never a
  file already in place.
- Post-run hooks: `AssetStore.invalidateCatalog` per touched kind,
  `AssetStore.registerFonts()` when fonts arrived,
  `OverlayTemplateStore.invalidateCache()`, the screen-crop store's
  equivalent. Nothing in `DriveMediaResolver` changes: no asset path is a
  Drive-backed record, so local-file failure behavior is untouched.
- Decisions: D3, D4, D7, D8. Depends on: 3, 4. Blocks: 6, 7.

### 6. Home folder lifecycle  (S)
Choosing a home stores its id and name; Refresh first calls `metadata` on
it. Not found or trashed → the Settings row switches to "Folder no longer
available — choose again" and Refresh is disabled until it is. A home
inside a shared drive works through the existing `supportsAllDrives`
handling. "Forget folder" clears the home and journal only.
- Decisions: D1, D2. Depends on: 4. Blocks: 7.

---

## Phase C — Settings and Refresh

### 7. Settings › Google Drive › Asset library  (M)
New section under the connection rows, visible only when the profile is
connected:
- Not set: one line of explanation ("Keep music, fonts, images, bumpers,
  overlays and screen crops in a Drive folder") and "Choose folder…", which
  opens `GoogleDriveBrowserSheet` in a folder-pick mode (generalize the
  upload mode's destination confirmation; new folder creation stays
  available there).
- Set: the folder's breadcrumb path with "Change…" and "Forget folder",
  the Refresh button, and a status line: "Last refresh <date>: 12 uploaded,
  3 downloaded, 41 in sync, 1 conflict" or "Refreshing… 7 of 16" with Stop.
  Errors and skipped conflicts expand into the existing transfer rows and
  the pipeline log, so the user can see which file and why.
- A note that the library is shared across profiles (D2).
- Decisions: D1, D2, D5. Depends on: 5, 6. Blocks: 8.

### 8. Refresh from the library views  (S)
The Music, Fonts, Images, and Bumpers sidebar views get a toolbar Refresh
button (cloud icon) when the active profile has a home; it runs the same
Refresh and shows the same status. Disabled while one is running. Absent
when no home is set (D1).
- Depends on: 7.

---

## Phase D — Learned preferences

### 9. Learned document  (M)
`LearnedPreferences`: a versioned, Codable document built from the local
profile and database, and the single source for both publishing and the
view. Sections, each with `enabled` (share toggle) and `updatedAt`:
- `style`: house style, hook style, layout preference, pacing, caption
  languages, with provenance.
- `taste`: rubric plus categories; exemplar frames are copied into the
  bundle as `learned/<contributor>/frames/<hash>.jpg` and referenced by
  relative name, never by absolute path.
- `lessons`: `wizard_lessons` rows as `{id, text, pinned, evidence,
  updatedAt}` where `id` is a stable hash of the original text.
- `vocabulary`: tag schema and pinned hashtags.
- `benchmarks` (opt-in, on by default for the same brand): numbers only —
  duration sweet spot, cuts per minute of top reels, saves/shares/comments
  per thousand, best posting slots, top hashtags with lift, top and bottom
  traits. No captions, comments, handles, or follower counts.
- `people` (opt-in, off): names and descriptors only, no face boxes or
  avatar references.
- `research` (opt-in, off): fight research summaries and saved query plans.
A `LearnedRedaction` pass runs on every build and is what tests assert
against: it strips paths, URLs to private sources, cookies, and any field
not on the allow list, so a future profile field cannot leak by default.
- Decisions: D9, D11. Depends on: nothing. Blocks: 10, 11, 12.

### 10. Publish and merge  (M)
Refresh gains a "learned" step after assets: distill pending feedback into
lessons (the existing distillation, skipped when nothing changed since the
last run), build the document, write `learned/<contributor>.json` and its
frames through the same executor (upload replaces the app's own file,
which it created, so D8 never bites), then download every other
contributor's file and frames into
`~/Documents/ClipBuilder/learned/<contributor>/`. `LearnedMerge` produces
the prompt-time view of local plus contributors per D10 and caches it in
memory per profile, invalidated by Refresh and by edits in the view.
`WizardEngine` blocks (`houseStyleBlock`, `tasteRubricBlock`,
`trainingBlock`, `benchmarksBlock`) read the merged document instead of
the profile and database directly; each injected line keeps its origin
label so `AIRunCapture` and the AI details sheet can attribute it.
Contributors can be muted individually (kept on disk, left out of the
merge). Token budget: the merged block is capped the way `prioritizedTags`
caps tags, pinned and local items first.
- Decisions: D3, D10. Depends on: 5, 9. Blocks: 11, 12.

### 11. "What Clip Builder has learned"  (M)
One screen, reachable from the sidebar under the AI section and from
Settings › AI, showing the document from item 9 section by section:
- Each section lists the local content and, beside it, each contributor's
  content with its name and date. Lessons can be pinned, dismissed
  (hidden from the merge without deleting the row), or rewritten; taste
  categories can be dropped; a benchmark summary can be refreshed from the
  latest Instagram import.
- A share toggle per section and a mute toggle per contributor, both
  saved in the profile JSON so they travel with it.
- A "Preview what will be shared" button renders the redacted document as
  it will be written, and "Publish now" runs only the learned step of
  Refresh.
- An evidence line per section: how many reviews, reels, or studies it
  was distilled from, and when, so the user can judge how much to trust
  it. This is the same provenance the AI details sheet shows.
- Without a Drive home the view still works as the local learning page;
  only the share toggles and contributor columns are absent (D1).
- Decisions: D12. Depends on: 9, 10. Blocks: 13.

### 12. Import without Drive  (S)
`ResourceBundle` gets a `.learned` category that packs the same document
and frames, so a team without a shared Drive can hand the file over, and
the import path is the same merge as item 10. This also replaces the
unredacted profile export as the recommended way to share a brand's taste.
- Decisions: D9, D11. Depends on: 9, 10.

---

## Phase E — Trained models

### 13. Reel traits  (M)
`ReelTraits`: one Codable feature vector and one extractor,
`ReelTraitExtractor.traits(for: URL, caption: String?, transcript:)`,
producing: duration; cut count, cuts per minute, and cut-interval
variance; black and frozen fractions; face presence in the first one and
three seconds; on-screen text area in the first three seconds and overall;
speech fraction and words per minute; filler and dead-air fractions;
music presence and loudness; aspect and crop class; scene-type mix from
Vision labels; sharpness and luminance medians; caption length, hashtag
count, question or hook words, language. Every field is a number or a
small enum, no text that could identify anyone. Traits are stored in a new
`reel_traits(video_kind, video_id, version, traits_json, computed_at)`
table keyed by source kind (imported reel, generated reel, candidate) and
recomputed when `version` changes. Generated reels get traits at render
time; imported reels during Instagram import (item 14).
- Decisions: D14. Depends on: nothing (reuses existing detectors). Blocks:
  14, 15, 16.

### 14. Instagram reels as a training source  (M)
The Instagram import gains a "compute traits" step for every reel with a
local file (`imported_externals` and report media): traits from item 13
plus the outcome row from `ig_media_insight_snapshots` and the posting
month's account median from `ig_account_insights`, joined into a
`reel_outcomes` view: traits, raw outcomes, lift per metric, posting slot,
topic tags. Reels without a local file are fetched through the existing
Instagram service when the user opts in, with the download count shown.
Other accounts' reels (references, curated exemplars) get traits but no
outcome row and are flagged `reference = 1`. The benchmark computation in
`AccountBenchmarks` moves onto this table so the numbers-only summary
shared in item 9 and the model in item 15 read the same rows.
- Decisions: D15. Depends on: 13. Blocks: 15, 16.

### 15. Outcome model  (M)
`ReelOutcomeModel`: a Create ML boosted-tree regressor per profile from
`reel_outcomes` (own reels only) predicting lift for saves, shares,
comments, and watch fraction, trained on the Mac in seconds and saved as
`<profile>/models/reel-outcome-v<n>.mlmodelc` in the data folder. Below
forty labeled reels the trainer refuses and says how many more it needs.
Training reports feature importance, which the learned view (item 11)
shows as "what moves results for this account" and the planner can quote.
The model scores: candidate plans rendered at proxy quality (traits from
the proxy), generated reels before publishing (a predicted-lift line in
the critic), and A/B pairs in `wizard_preferences` as a sanity check
against the user's own choices.
- Decisions: D13, D15. Depends on: 14. Blocks: 17.

### 16. Clip ranker and taste similarity  (M)
Two smaller models on the same footing:
- `ClipRanker`: logistic regression over per-scene features (the subset of
  `ReelTraits` a scene can have, plus tags, position, and person presence)
  with labels from grades, favorites, curated marks, clip reviews, and
  accepted or rejected cuts. Orders candidate scenes before the planner
  prompt and caps the inventory sent to the model to the top ranked.
- `TasteSimilarity`: no training. Vision feature prints of the taste
  exemplar frames and of the top-lift reels' key frames; a candidate frame
  scores by nearest-neighbor distance. Surfaces as a "looks like ours"
  number in scene search, cover picking, and the critic.
- Decisions: D13. Depends on: 13, 14. Blocks: 17.

### 17. Holdout gate and enable switches  (S)
Three new on-device items, `outcome-model`, `clip-ranker`,
`taste-similarity`, in Settings › AI with the same rows as the existing
ones. "Evaluate" holds out the newest twenty percent of labeled reels or
scenes, trains on the rest, and reports rank correlation against the true
lift (outcome model), agreement with the user's keep decisions (ranker),
and precision of the top ten against curated scenes (taste). The report is
saved beside the on-device agreement reports and shown in the learned
view. The switch stays where the user left it. Enabled models also
publish: the `.mlmodelc`, its version, and its evaluation report go into
`learned/<contributor>/models/` in the Drive home through item 10, so a
teammate can adopt a model before their own library has labels; adopted
models are marked with their origin and evaluated locally before use.
- Decisions: D16, D10. Depends on: 15, 16. Blocks: 18.

---

## Phase F — Verification

### 18. Tests  (M)
- Planner: property-style cases over synthetic inventories — only-local,
  only-Drive, equal MD5, newer local, newer Drive, tie, disallowed
  extension ignored, nested folders parent-first, Drive duplicate names,
  hidden and staging paths skipped, no delete ever emitted.
- Executor with `FakeDriveTransport` and `TempDirectory` roots (injected
  through `AssetSyncRoots`, never `AssetKind.rootURL`, per the catalog
  rule in TESTING-PLAN): folder creation both ways, download lands after
  staging with Drive's mtime, upload records the id, 403 on replace becomes
  a report line, Stop mid-plan leaves no `.import-*` residue, fonts trigger
  registration.
- Journal round trip and "unparsable journal rehashes".
- Settings: home lost → row state and Refresh disabled.
- Learned document: golden-file test that a profile with every sensitive
  field set (cookies, handles, absolute exemplar paths, `ig_*` rows,
  people with face boxes) produces a document containing none of them;
  the allow list is the test's oracle, so a new field fails the test until
  it is classified.
- Merge: union of lessons by id with newest text winning, local
  single-valued fields beating contributors, muted contributor excluded,
  cap keeps pinned and local first, origin labels present on every line;
  `planPrompt` output with a contributor equals the same prompt with the
  contributor's lines appended and nothing else changed.
- Publish: the app's own file is replaced, another contributor's file is
  never written, frames land under the contributor folder.
- Manual pass on the real library against a scratch Drive folder: first
  Refresh uploads everything, a second is all "in sync", a file dropped
  into Drive by hand downloads, an edited local overlay replaces the Drive
  copy, and Forget folder leaves both sides intact.
- Reel traits: golden traits for the fixture video and its padded and
  captioned variants; determinism across two runs; version bump forces
  recomputation; every field numeric or enum (a reflection test).
- Outcome rows: lift computed against the right posting month; reels
  without insights never get labels; reference reels flagged and excluded
  from training; refusing below forty rows.
- Models: training on a synthetic table with a planted signal recovers it
  (importance and holdout correlation above a floor); the evaluate action
  writes a report and leaves the override untouched; an adopted model is
  re-evaluated before scoring anything.
- Manual pass for learning: two profiles on two Macs (or two data folders
  on one) with the same home; a lesson pinned on one appears attributed on
  the other after both Refresh; a muted contributor disappears from the
  next Wizard plan's prompt in the AI details sheet.
- Manual pass for models: import the account's reels, compute traits,
  train, read the importance list against intuition, evaluate, enable the
  outcome model, and confirm the critic's predicted-lift line moves when a
  draft's first three seconds change.
- Depends on: 5, 6, 7, 10, 11, 15, 16, 17.

---

## Suggestions

- Full `drive` scope so "newer wins" can also replace files the user added
  to the folder by hand (D8). Needs every connected account to re-consent.
- A dry-run "Preview changes" that shows the plan before executing it. The
  planner already produces exactly that list.
- Include `assets/effects/previews` once preview rendering is deterministic
  enough that syncing beats regenerating.
- If profiles ever get their own asset roots, D2's caveat disappears and
  the home stays exactly where it is stored today.
- Sharing raw feedback rows with the media they refer to is possible once
  video sources also live in the shared home; until then D9 stands.
- A "team lessons" review flow: a contributor's lesson can be promoted to
  local (copied, so it survives muting) or replied to with a counter-lesson;
  the merge already carries origins, so this is view work only.
- Weighting contributors by their benchmark performance when two lessons
  contradict, instead of newest-wins.
- Pooling `reel_outcomes` rows across contributors as feature vectors (no
  media, no captions) so a new brand in the same domain starts with a
  model trained on more than its own history.
- Letting the planner ask the outcome model directly ("which of these
  three plans scores highest") once proxy rendering is fast enough to make
  that loop interactive.
