# Sources: background upload to Google Drive, and a Created column

September 6, 2026. Two small requirements on top of the Google Drive work
(docs/Google-Drive-Implementation-Plan.md).

## R1. Upload selected sources to Google Drive in the background

The user selects one or more videos in Sources that are not yet in Google
Drive and uploads them. The upload must never block the app: the UI stays
responsive, other jobs (analysis, rendering, playback) keep running, and the
user can switch projects or profiles. Progress is visible the whole time.

Acceptance:
- Sources toolbar: an explicit "Upload to Google Drive…" action, enabled when
  the selection contains at least one video without a Drive id. Videos that
  already have a Drive copy are skipped, and the confirmation says how many
  will be uploaded and how many are skipped.
- The folder picker is the existing one (remembered per profile, default
  "Clip Builder/<profile>/<project>").
- Uploads run as background transfer jobs (existing GoogleDriveTransfers):
  one row per file in the sidebar Activity summary with file name, percent,
  bytes, and Stop; plus an aggregate "Uploading N files" line while more than
  one is active. When a row completes the Sources row shows the cloud icon
  without a manual refresh.
- Each Sources row that is uploading shows an inline progress indicator in
  the File column (small circular or linear, percent in the tooltip).
- Non-blocking guarantees: file reads, checksum and chunk PUTs happen off
  the main actor; progress updates are throttled (at most ~4 per second per
  job) so observation does not re-render the grid on every chunk; at most
  two uploads run concurrently, the rest queue; a queued job says "Waiting".
- Failures (offline, quota, expired token) leave the row with Resume /
  Reconnect as today; the other uploads continue.
- Unit tests: selection filter skips Drive-backed videos; concurrency limit
  of two with the rest queued; progress throttling; completion writes id and
  link (existing test may be extended).

## R2. "Created" column in the Sources grid

Add a sortable "Created" column to the Sources table showing the video
file's creation date (filesystem creation date; fall back to the media's
creation metadata if present, then to discovered_at). Store it on the video
record (`created_at` TEXT, ISO 8601) at registration and backfill existing
rows lazily on first load or via a one-time migration step. Format as a
short date with time in the tooltip. Default sort unchanged.

Unit test: registration stores the creation date; backfill fills missing
values.
