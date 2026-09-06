# Google Drive — implementation plan

September 5, 2026. Same format as the other plans: numbered build order,
effort (S = a day or two, M = about a week, L = two weeks or more),
dependencies, and the decision each item rests on.

## Scope

Connect a profile to Google Drive, browse and search it inside the app,
download video files into the project, upload outputs and sources back to
Drive, and off-load any local file that has a Drive copy to save disk
space. Nothing else: no shared projects, no sync of app data, no
collaboration. The video files are always worked on locally.

## Decisions (settled)

- **D1.** Drive is a file store only. The database, timelines, scenes, and
  settings never go to Drive.
- **D2.** The app shows the user's whole Drive tree, so it needs Google's
  read scope for Drive (`drive.readonly`) plus the write scope for files it
  uploads (`drive.file`), provisioned through an OAuth client in testing
  mode (see item 1).
- **D3.** A downloaded file keeps its Drive file id on the record. That id
  is what makes off-loading and "already in Drive" possible.
- **D4.** Off-loading deletes only the local media file. Scenes, analysis,
  transcripts, thumbnails, and timelines stay; anything that needs the media
  again re-downloads it first.
- **D5.** Uploads go to a folder the user picks, remembered per profile,
  with a "Clip Builder/<profile>/<project>" default created on first use.

## What already exists

- `videos.drive_file_id` / `drive_link` and `generated_videos.drive_file_id`
  / `drive_link` columns (from the earlier Python app).
- Keychain token storage and a token-based connect flow (Instagram).
- A download/progress pattern for Instagram media, and the Activity summary
  in the sidebar for long jobs.
- Thumbnail disk cache, so an off-loaded file keeps its pictures.

---

## Phase A — Connection

### 1. Google sign-in  (M)
Settings › Google Drive: Connect opens Google's OAuth flow in the system
browser session (`ASWebAuthenticationSession`), stores the refresh token in
the Keychain, refreshes access tokens silently, and shows the connected
account with Disconnect. One connection per profile. Errors (revoked token,
scope missing) surface as a "Reconnect" state, the way Instagram does.
- Decisions: D2. Depends on: nothing. Blocks: everything.
- **Decided:** the OAuth client runs in Google's testing mode (no
  verification review; up to 100 named test users). Refresh tokens then
  expire every 7 days, so the app must handle that gracefully: the
  connection row shows "Reconnect (expires <date>)", a Reconnect button
  reruns sign-in in one click, and a download or upload that hits an
  expired token pauses and prompts to reconnect instead of failing. The
  client id and secret live in the app's Info.plist; each user's Google
  account is added as a test user in the Google Cloud console.

### 2. Drive client  (S)
A small Drive v3 client: list folder children with paging, search by name,
file metadata (size, modified, mime, thumbnail link), resumable download,
resumable upload, create folder. Video-only filtering server-side. All
calls off the main actor; errors typed (auth, quota, not found, offline).
- Depends on: 1.

---

## Phase B — Browse and download

### 3. Drive browser  (M)
"Add from Google Drive…" in Sources (and in Add Files everywhere it appears)
opens a sheet: folder tree with breadcrumbs, My Drive / Shared with me /
Shared drives / Recent at the top, a search field, video files only by
default with a toggle, thumbnails, size and date, multi-select. A file
already in this profile is marked with the same cloud icon as item 6 and
selects as "already here". Download adds the files to the current project.
- Depends on: 2.

### 4. Download queue  (M)
Selected files download into the profile's Input folder with a per-file
progress row in the Activity summary, resume after interruption, and a
Stop. Each file is registered on arrival (same path as a dropped file),
with its Drive id and link stored. Re-adding a file already downloaded
reuses the local copy. Downloads continue across project switches.
- Decisions: D3. Depends on: 2, 3.

---

## Phase C — Off-load and upload

### 5. Off-load local copies  (M)
Any source or output whose record has a Drive id shows a cloud icon in
Sources, Outputs, the Builder's scene browser, and the Library card. The
icon's menu offers "Remove local copy" (single or multi-select); the file
is deleted and the record marked off-loaded, with the icon changing to the
outline form. Everything that needs the media (preview, analysis, render,
publish, thumbnail regeneration) checks first and, if off-loaded, queues a
re-download and waits; the Activity row shows "Fetching from Drive". A
Settings option "Off-load automatically after N days unused" is optional.
- Decisions: D3, D4. Depends on: 4.

### 6. Upload to Drive  (M)
"Upload to Google Drive" on outputs (Library card, Outputs multi-select,
the results sheet after a Wizard run) and on sources. A folder picker with
the remembered default; resumable upload with progress in the Activity
summary; on completion the record gets the Drive id and link, the cloud
icon appears, and "Open in Drive" is available. Optional per project:
"Upload every rendered output automatically".
- Decisions: D5. Depends on: 2.

---

## Phase D — Verification

### 7. Tests and manual pass  (S)
Unit: token refresh and reconnect states; download registration reuses an
existing local copy; off-load keeps scenes and re-download restores the
path; upload writes id and link. Integration against a test Drive folder
with a small fixture video: list, download, off-load, re-download, upload,
delete. Manual: browse a real Drive, download a 1 GB file with a pause and
resume, off-load it, render a timeline that uses it.
- Depends on: 1–6.

## Suggestions

- Show Drive quota (used / total) in Settings once connected; off-loading is
  about disk, uploading is about quota, and both are invisible otherwise.
- Keep the Drive browser read-only apart from creating an upload folder; no
  move, rename, or delete of Drive files from the app in this scope.
- Treat "Shared with me" files as downloadable but never off-loadable to a
  location the app can't re-fetch: if the sharer removes access, an
  off-loaded file is gone. The off-load menu should say so for shared files.
