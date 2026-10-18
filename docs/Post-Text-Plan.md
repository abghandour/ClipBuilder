# Post text on demand

Date: 2026-10-18. Status: implemented.

## What changed and why

The Instagram post text (the `captions` AI task) used to be requested the
moment Generate was pressed, in parallel with the render, and awaited in the
reel's deferred finish. That spent a model round trip on every candidate,
most of which are thrown away, and offered no rewrite.

Now the render produces no post text. The text is written on demand, after
the video exists, from three places:

- the "Your video is ready" sheet: each card has Write Post Text, then the
  text with Copy and Rewrite plus an optional steer ("shorter", "mention the
  knockout");
- the Publish Reel sheet: Write or Rewrite fills the caption field;
- the Library card's context menu: Write / Rewrite Post Text.

The model choice (the gear) sits next to those buttons, not in Settings.

## How

- `WizardEngine.writePostText(video:note:options:profile:database:emit:)`
  rebuilds the prompt from the saved take's plan when the video has one
  (rationale, headline, music), else from the record's rationale; tags come
  from the plan's scenes; fight research, benchmarks and local hashtags as
  before. A note and the previous text are appended for a rewrite. The
  result goes through `Database.updateGeneratedCaption`, which also records
  the output role and refreshes the reel traits' caption fields.
- `AppStore.writePostText(for:note:)` runs it as an `AppJobKind.postText`
  job keyed by the video id, then refreshes the lists.
- Removed: `WizardEngine.startCaptionRequests`, `CaptionRequest`, the
  `captionRequest` / `prestartedCaption` parameters, the caption step in
  `finishReel`, and the batch's "Writing captions" status. The finish is now
  reel traits, run report and the optional critique. Express's batch timing
  loses the "caption wait" stage; docs/Performance-Express-Results.md is
  history and keeps describing the old overlap.

## Verification

`ExpressDeferredFinishTests` now checks that a render makes no caption call
and that `writePostText` fills the record and the traits afterwards.
