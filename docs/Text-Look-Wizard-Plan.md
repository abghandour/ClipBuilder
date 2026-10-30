# Text Look Wizard: create looks from an image or a video

Date: October 30, 2026. Status: implemented (Claude), Codex-reviewed. Font matching revised the same day after the first live run picked the only library font for everything.

## What the user asked for

The Text Looks studio (Overlays tab) had a "Create from Image…" toolbar button
that extracted an overlay template from one still frame. It becomes
"Create from File…": the file can be an image or a video. After the file is
dropped the sheet asks what to import (overlay template, caption style, name
tag style). For a video, the AI watches the animations and the wizard sets the
matching effects so the result reproduces the clip as closely as the app's
settings allow.

## Design

- `TextLookExtraction` (Services, `nonisolated enum`, tests next to it) owns
  the prompt, the frame-sampling schedule for videos, and the response parser.
  The parser returns Sendable values only: `[OverlayElement]`, a `CaptionStyle?`
  and a `TagStyle?`, plus a short summary for the notice.
- Video sampling: a dense burst over the first 1.5 s (entrance), evenly spaced
  frames over the body, and a dense burst over the last 1.2 s (exit); at most
  16 frames. Gemini receives the file natively; every other provider gets the
  sampled stills through `fallbackFrames`.
- Overlay elements carry `start`, `end`, `enter`, `exit` and a crop time `at`.
  For a video, a bounded element keeps its timing; an element with no `end`
  stays `unbounded`. Image marks are cropped from a full-resolution frame at
  `at` (or from the image itself).
- Caption and name tag styles map onto the existing `CaptionStyle` and
  `TagStyle` vocabularies (animation pop / slide-up / fade, reveal word, highlight
  color / box / scale, weight, stroke, shadow, background, radius, position, words
  per page, name and role lines).
- Fonts (`FontMatch`, Services, pure given a catalog): the model names the
  real typeface and describes it (category, style words, weight 100–900,
  italic, tracking in em); the library list in the prompt is only for fonts
  that truly are that typeface. The matcher takes the font itself when the
  library or the Mac has it, else a known stand-in from a table of popular
  social-video faces (Proxima Nova → Montserrat → Avenir Next, Oswald → Bebas
  Neue → Anton → Impact, …), else the best installed face of the described
  class, and finally the sans / serif / mono keyword. Every stand-in is
  explained in the job log with the font to add to the library for an exact
  match. Weight maps to regular / bold / black, tracking in em × caption size
  becomes the renderer's letter spacing, italics carry through, and overlay
  texts get their matched family too. The lit and emphasised words can wear
  their own face (`highlight_look` / `emphasis_look`: typeface, italic, size
  scale) through the style's per-state font and decor, so a serif italic
  dropped into a sans line is reproduced rather than reported.
- `AppStore.importTextLooks` runs as an `AppJobs` job of kind `.overlayTemplate`
  (status-bar row, Stop, finish notice). New named styles are appended to the
  active profile with the name "Wizard – <file>"; `createdTextLookSelection`
  tells the studio which tab and style to show. The job's result
  (`TextLookImport`) opens the root review sheet `TextLookNamesSheet`, where
  each created item's name is editable (first field focused with its text
  selected) before the user returns to the studio; Keep Names leaves the
  "Wizard – <file>" defaults. "Create from File…" sits on the Text Looks
  toolbar for every tab; New Template is in the Overlays list's button row.
- The sheet (`TextLookWizardSheet`) accepts images and movies, shows a poster
  frame for a video, then the import targets. Nothing long runs inside it.

## Out of scope

Per-word timing of the reference captions, line spacing, and effects the renderer does not have (e.g. typewriter, bounce) are reported
in the job log, not invented.
