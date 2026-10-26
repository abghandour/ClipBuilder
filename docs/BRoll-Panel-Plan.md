# Express B-roll panel

Date: October 25, 2026. Status: implemented; refined October 26, 2026 (Footage-panel highlight style, podcast audio under Play, card sized to the editors). Replaces
the automatic B-roll review in `docs/BRoll-Review-Plan.md` (built the same day,
uncommitted, never released); that plan is superseded.

## What the user asked for

The automatic, AI-matched B-roll review was rejected ("this is not a good AI").
B-roll in Express becomes fully manual: the user selects words in the kept
footage's transcript, picks a scene for them, and sizes it. The generator places
each B-roll scene so it starts on the first selected word.

## Decisions (the user's, October 25, 2026)

1. **Express always makes one reel.** Remove the Output picker
   ("One reel / Separate videos") from Settings → Package and every "N reels" /
   "Generate Videos" wording. Express always passes `oneReel: true`.
   `MiniWizardFlow.OutputMode` and the stored `outputMode` key stay so old
   presets decode; whatever they hold, Express renders one reel. The Package
   summary no longer lists "One reel".
2. **Remove the automatic B-roll** from Express and Full: mention matching
   placement, the Moments | B-roll tab in every review, the Replace popover,
   AI Suggest (`AITask.brollSuggest` and its catalog entry), the
   and the `MiniWizardSettings.broll` toggle in Settings. Highlights review
   autoplay stays off. Full Wizard B-roll goes back to how it was in
   1.123 (its own B-roll group and planner). Keep and reuse: `BRollCut`
   (source clock), `WizardPlanClip.brollCuts`, `BRollCutMapping` (render
   conversion), the render-key change, and `Database+MiniBRollReview`-style
   persistence if it fits. Delete files and tests that only served the removed
   parts. `HighlightCandidate.brollCuts` may stay as an unused Optional if
   removing it is risky for decoding; otherwise remove.
3. **New card "B-roll"** in the Express settings column, between 2 Footage and
   Settings (Settings becomes 4). Shown only when the source is a podcast or
   interview (`flow.isPodcastOrInterview`). Without kept footage it reads
   "Keep footage in 2 Footage first." Its header shows a tag **"N B-rolls"**
   ("1 B-roll") when there is at least one. The card has a **Remove all
   B-rolls** button (disabled when none; with a confirmation).
4. **Left column = combined transcript.** When the B-roll card is open, the
   left column shows the transcript of every kept piece of footage, in reel
   order, as one continuous text, broken into blocks only where the speaker
   changes (speaker name above each block, from the same speaker resolution
   the Q&A review uses). A thin divider between kept pieces is fine but no
   per-piece headers. Word selection is press-and-drag, the same gesture as
   Transcript picks. A selection cannot cross from one kept piece into the
   next (the reel cuts there): clamp it to the piece where it started.
5. **New selection → middle column, no popup.** After the user selects words,
   the middle column shows the selection ("“…words…” · 3.2 s") with two
   buttons: **Pick Scene** and **Clear Selection**. Nothing opens by itself.
6. **Pick Scene** opens a popover/sheet with a thumbnail grid of every active
   scene in the project (including the source's own), a search field filtering
   by scene name, tags, people and file name (no AI), and a marker on scenes
   already used as B-roll (still pickable). Picking a scene creates the B-roll:
   - starts at the first selected word's start, on the source clock;
   - length = the selection's length, capped at the scene's length;
   - `sceneOffset` = 0 (scene start); `origin` = `.user`; `reason` = the
     selected text (truncated).
7. **Each B-roll gets its own colour** (a fixed palette cycled by order). Its
   words are highlighted in that colour in the transcript.
8. **Clicking one or more coloured selections** (click, Cmd-click to add)
   shows them in the middle column, stacked, one block each:
   - a player of the B-roll scene from `sceneOffset`, muted, no autoplay, with
     Play/Pause;
   - a length control (a trim bar or stepper, whole words): changing the
     length moves only the end; the start stays on the first word. The
     transcript highlight grows or shrinks to the words the new length
     covers, snapped to a word end. It stops at the end of its kept piece, at
     the next B-roll, and at the scene's length;
   - a way to slide which part of the scene is used (`sceneOffset`), within
     the scene;
   - **Replace Scene** (the same picker; keeps timing, re-caps length) and
     **Remove** (deletes the B-roll and its highlight).
9. **Settings → Package gets an "Include B-roll" toggle**, shown only when the
   B-roll card is shown. It turns on automatically whenever the user adds,
   resizes, replaces or removes a B-roll; the user can turn it off before
   generating. Off = render without B-roll; the B-rolls are kept. The
   Generate panel's Package section lists "B-roll (N)" when on and N > 0.
   Store it as an Optional on `MiniWizardSettings` (e.g. `includeBRoll: Bool?`),
   reusing the existing `broll` key is fine if it reads cleanly.
10. **Render.** B-roll covers the whole frame (full screen, not one half of a
    split layout), starting exactly at the first selected word, for its length.
    The podcast audio continues; the B-roll's own sound is muted. Captions,
    name tags, watermark and overlays stay on top. No other B-roll is added
    automatically (no reaction tiles, no planner fill) in Express.

## Storage

B-rolls belong to the Express run and survive relaunch and selection rebuilds
the way kept footage does. Store each as a `BRollCut` on the source clock on
the `WizardPlanClip` of the kept piece it lies in (the phase-1 path), or in a
per-batch store if that is simpler; either way, a re-run of 2 Footage that
keeps the same piece keeps its B-rolls, and a B-roll whose words are no longer
kept is dropped. New Codable stored properties are Optional; no enum raw value
changes. `MiniWizardFlow.Card` gains a `broll` case (new raw value only).

## Rules that still apply

- Nothing autoplays. No AI calls anywhere in this panel.
- Every action has a visible button; context menus only repeat them.
- Toolbar and row text: `lineLimit(1)` + `fixedSize` or `ViewThatFits`.
- Long media work (thumbnails, render) never blocks the main thread or a sheet.

## Tests

- Express always produces one reel, whatever `outputMode` an old preset holds.
- Combined transcript: reel order, speaker blocks, no crossing between pieces.
- Selection → B-roll: start on first word, length capped at scene length.
- Resize: end snaps to a word end, stops at piece end, next B-roll, scene length.
- Include-B-roll toggle: turns on after an edit; off renders none.
- Render mapping: a B-roll starts at its word's reel time and covers full frame;
  old settings JSON decodes.
