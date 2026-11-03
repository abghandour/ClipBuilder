# Local footage only

Date: November 3, 2026. Status: shipped in 1.148; re-added copies link since 1.149.

## Why

Scenes, batches and sources of footage that is not on this Mac showed up
everywhere: "Not on this Mac" cards in Scenes, greyed sources in the
wizards, Drive-only files in pickers. The user wants them gone from every
screen but Sources, where a Drive copy can be downloaded.

## What it does

- **Local** means the file is on this Mac. `isPresent` keeps its old meaning
  (local, or on Drive and fetched on demand by media actions) because renders
  and previews still rely on it. `FootageAvailability.isLocal(path:)` is a
  second snapshot filled by the same `refresh` call; `VideoRecord.isLocal`,
  `isDriveOnly`, `isReachable`, `SceneRecord.isLocal` and
  `AnalysisRun.isLocal` read it.
- **Everywhere but Sources** lists only local footage. The store filters once:
  `applyLibrarySnapshot` puts only local scenes into `scenes` and
  `historyScenes`; `localVideos` and `localAnalysisRuns` serve the lists that
  read videos or batches (Scenes batch sidebar and counts, Full wizard source
  grids and source picker sheet, Express source grid, Builder clip browser,
  B-roll and avatar pickers, fight story, effect sample and source choices,
  wizard footage review). `referencedScenes` and the Builder's scene lookups
  stay complete so open timelines can still report a missing source.
- **Sources** lists local and Drive-only files, with "Not on this Mac" in
  the File column for the latter. The preview pane never fetches a Drive
  copy on selection; it shows the message with a Download button
  (`MissingFootageDownloadButton`, the existing cancellable Drive fetch
  queue, so several files download in the background at once, and the
  selection's Drive menu offers "Download N Local Copies"). A file that is
  neither here nor on Drive is left out of the table. The scene count column
  comes from `allSceneCountsByVideo`, counted before the local filter.

- **Re-adding a copy links it** (`SourceRelink`, since 1.149). A row that
  Team Sync brought over has no path on this Mac, so 1.148 hid it even from
  Sources, and adding the file again registered a second, blank row (or
  said "Already in Sources" when the copy already sat in the Input folder).
  The folder scan now points such a row at a file with the same base name
  and a duration within one second, keeping the row's hash because it is
  the team-wide identity (sync key, highlight history, Drive check). A
  blank duplicate the copy registered earlier is folded into that row with
  its project memberships. A copy that was already analyzed on its own is
  left alone, so two rows can remain in that case.

## Not done

- Project card and timeline row thumbnails come from SQL paths and still
  show a placeholder when the first files are not local.
- Person detail popover (opened from Sources) lists the person's videos
  including Drive-only ones.
