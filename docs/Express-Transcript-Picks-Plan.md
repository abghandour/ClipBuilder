# AI Wizard Express: Transcript picks

Date: October 16, 2026. Status: implemented in this change set (uncommitted).

## Goal

A third footage kind in AI Wizard Express, **Transcript**, beside Q&A and
Highlights. The user reads the transcript, marks a passage, and presses Add.
Each added passage becomes a pick with an AI-written title. Picks can be
reordered and deleted. Clicking a pick highlights its words in the transcript so
the start and end can be moved word by word, exactly as Q&A exchanges are
trimmed today. Moving to Video Generation Settings saves the picks as
selections in list order, so Settings renders them as separate videos or as one
reel like Q&A.

## Decisions (from the user, October 16)

| Question | Decision |
| --- | --- |
| Marking a span | Press a word and drag; words are selected until the mouse is released, then the anchors adjust the ends. Clicking the selection clears it. Add stores the span and clears the selection. A "New pick" row holds the span being composed. |
| Item label | The first words of the passage, up to two lines. No AI call (changed October 16 after a first AI-title version). |
| Playback | Nothing autoplays. Play All under the list plays the picks in order. |
| Reordering | Drag in the list, or the up/down buttons on each row. |
| Output | Same as Q&A: each pick becomes a saved selection with one take; Settings chooses separate videos or one reel in list order. |
| Persistence | Per video in the profile database (`transcript_picks`), so reopening the source restores the list. |

Assumed, say if wrong:

- Transcript is offered for every video that has an original transcript, not
  only podcasts. Highlights-only videos without a transcript do not show the
  picker.
- A pick's scene is created only when the picks are saved as selections. It is
  attached to the video's active analysis run and tagged `transcript-pick`, so
  it resolves like an exchange scene and appears in Scenes like exchanges do.

## Layout

Transcript mode mirrors the Q&A review: transcript words on the left, the
player and filmstrip in the middle, the picks list on the right. The shared
`RangeReviewView` gains `transcriptLeading`, `listTitle`, `onMove` and
`onDelete`; the Q&A and Highlights reviews are unchanged.

## Phases

1. Data: `transcript_picks` table, `Database+TranscriptPicks.swift`
   (fetch, add, range, title, reorder, delete, `replaceMiniTranscriptSelections`).
2. Rules: `TranscriptPick`, `MiniWizardTranscript`, `MiniWizardTranscriptRules`
   (plans, word titles, draft range). Tests beside each.
3. Flow and store: `FootageKind.transcript`, `MiniWizardFlow.hasTranscript`,
   `MiniWizardRun.transcript`, `AppStore+MiniTranscript.swift` (load, add,
   trim, move, delete, record selections).
4. Views: `RangeReviewView` options (`transcriptLeading`, `listTitle`, `onMove`,
   `onDelete`, `spanSelection`, `playAll`), `TranscriptQAWordPanel` span drag,
   `RangeReviewItem.TrimPolicy.pick` (empty range allowed), `MiniTranscriptPickView`,
   `MiniFootageCard` branch, Express card copy, Settings card kind checks.
