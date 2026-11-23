# Caption Emphasis Words Plan

Date: 2026-11-23. Status: accepted by the user 2026-11-23 ("second emphasis style per word, pick it in the transcript editor"); built 2026-11-23 except the live check (see "As built").

## Why

The "PG Preferred" caption preset copies a reference reel in which a few words are enlarged and one ("belt?") is set in an italic serif. Clip Builder picks emphasis words by itself (`CaptionEmphasis.indices`: numbers, names, the strongest noun), so it enlarges words the reference leaves alone (actress, dancer, athletes, UFC) and has only one emphasis look. The user wants to choose the words and to have a second look.

## What the user gets

1. **A choice per word in the transcript editor** (`TranscriptSheet`): Automatic (today's behaviour, the default), Off, Emphasis, Emphasis 2. A visible control for the selected word, not only a context menu; a marked word is recognisable in the transcript text (and how it is marked is told apart for Emphasis and Emphasis 2). Works on several selected words at once where the editor already selects several.
2. **A second emphasis style** in every caption style: "Emphasis 2", with the same controls the Emphasis group has (mode, colour, its own font picker, and the per-state `CaptionWordDecor` controls: size, weight, italic, letter spacing, stroke, shadow, background). A style that does not set it draws Emphasis 2 words as Emphasis.
3. **"PG Preferred"** sets Emphasis 2 to the italic serif look measured from the reference's "belt?" page.

## Rules

- `TranscriptWord.emphasis: String?`: nil = automatic, `"none"`, `"primary"`, `"alternate"`. Optional, nil encodes no key; it lives inside the words JSON already stored and synced, so no new column and no server migration (verify against the SyncTable column lists and `original_words`).
- Which words a caption page emphasises (pure, in `CaptionEmphasis`, tests beside it): a word marked `primary` or `alternate` is emphasised in that look; a word marked `none` never is; when a page holds at least one marked word (any of the three), its unmarked words are not emphasised (the user has taken that page over); a page with no marked word uses the automatic choice exactly as today. A style with emphasis off shows none of it.
- The marks survive what a word survives today: text corrections that keep the word (`TranscriptWordAlignment`), re-timing, proofreading, Mark Right, revert rules as for `confidence` (a word the edit replaces loses its mark). Re-transcription starts clean.
- Captions in another language (translated rows) have their own words: marks are made on the row being shown; nothing is carried across languages in this version.
- Rendering: the page's emphasis becomes "index plus look" from the plan (`CaptionOverlayPlan` raster) to `CaptionRenderer`; `CaptionStyle.WordState` gains the second look; caches (caption PNG keys, preview keys, segment keys) include it. A transcript with no marks and a style with no Emphasis 2 produce byte-identical rasters, keys and JSON to today.
- The one-line emphasis page fit added for "PG Preferred" treats both looks as emphasis.

## Not in this version

Marking words from the reel preview or the Express lists; AI-suggested marks; carrying marks to translations; more than two looks.

## Phases

1. Model, selection rule, alignment survival, renderer and caches, tests.
2. Style model and editor group "Emphasis 2", "PG Preferred" values, tests and frame comparison with the reference's "belt?" page.
3. Transcript editor control and markers; live check.

## As built (2026-11-23)

Codex wrote phases 1 to 3 and ran out of usage before building; Claude finished it.

- Model and rule: `TranscriptWord.emphasis`, `CaptionEmphasis.selection` (primary/alternate indices, page take-over rule), marks carried through `TranscriptWordRules`/`TranscriptWordAlignment`, paging and the overlay plan. Stored through `Database.markTranscriptEmphasis` inside the transcript sheet's Save; a line the edit no longer fits is skipped.
- Style: `emphasis2`, `emphasis2Color`, `emphasis2Font`, `emphasis2Decor`; `WordState.emphasis2`; "Emphasis 2" group in the style editor with a fourth swatch.
- Transcript editor: an Emphasis control on each line opens `TranscriptEmphasisStrip` (word buttons, "Set emphasis" menu: Automatic, Off, Emphasis, Emphasis 2); marked words carry ¹, ² or ⊘ and are styled in the line's text.
- Renderer: on a page that is not fitted to one line, a marked word takes its own width and rises out of its row; other words keep their places. Applies only to styles with a line fit or a second look, so every other style renders as before. The renderer's per-word style reads moved into `ResolvedStates` (the Debug stack overflowed otherwise).
- "PG Preferred": Emphasis 2 is Bodoni 72 italic, white, 2.0 x, tracking -3 (closest stock face to the reference's "belt?").

Deviations and gaps: Part B of the brief (reference line breaks after a comma) was not built: Codex found the reference's breaks contradict a single width or balance rule. The reference sets that page's rows further apart than ours.

Added after the first pass: `CaptionWordDecor.takesHighlightColor` (false keeps an emphasis word in its own colour while spoken; "While spoken" toggle in the editor), set for PG Preferred's Emphasis 2. The transcript editor was driven live on scratch data (mark, Apply, marks in the DB).

Unverified: a reel rendered in the app from marked words and the style editor's Emphasis 2 group were not driven; Team Sync carriage of the mark inside the synced `words` JSON was read in code, not exercised; Codex's byte-identity check of the other presets was not repeated after the renderer changes (the caption suites, which pin legacy pixels, pass: 281 tests with the transcript suites).
