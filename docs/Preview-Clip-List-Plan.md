# Preview clip list

Date: 2026-11-05. Status: implemented with this plan (Express only).

## Goal

The Express preview column gets two tabs, **List** and **Video**. List is the
default. It shows every kept clip in output order as a row: a small still of
the clip's first frame, the clip title and time, and the clip's text. Rows
start collapsed at two lines of text and expand on a chevron; **Expand All**
and **Collapse All** sit above the list. Rows can be dragged to reorder the
reel, and clicking a row makes it the Video tab's current clip.

Row text is decided by content, not by video type: the transcript words
inside the clip's range when there are any, else the analyzed scene's
narrative (the one-to-two sentence beat-by-beat description the Analyzer
writes for action footage), else nothing.

## Where the order lives

Each Express footage mode already plays its kept clips in a stored or
derived order. Reordering changes that source so the left footage list, the
preview and the render agree:

| Mode | Order before | Order now |
| --- | --- | --- |
| Transcript picks | `transcript_picks.position` | unchanged; `reorderMiniTranscriptPicks` |
| Fight picks | `fight_picks.position` | unchanged; `reorderMiniFightPicks` |
| Q&A exchanges | section (time) order; `qa_picks.position` existed but was never read for ordering | `MiniWizardQA.keptOrder` loaded from `qa_picks` positions; `reorderMiniQAKept` rewrites them; `MiniWizardQARules.plans` and the preview follow it |
| Highlights candidates | `wizard_selections.id` | in-memory candidate order; remembered in UserDefaults `mini.order.<batch>` next to `mini.kept.<batch>` |

`AppStore.reorderMiniPreviewClips(_ ids: [String])` maps preview clip ids
(`qa-<scene>`, `pick-<pick>`, `fight-<pick>`, `take-<selection>-<cut>`) back
to the mode's reorder action.

## Pieces

- `Services/Wizard/WizardPreviewRows.swift` (pure): `WizardPreviewRow` and
  `rows(clips:words:)`, which picks the text per clip; `reorderedIDs` for
  the drag maths. Tests in `WizardPreviewRowsTests`.
- `Views/Wizard/WizardPreviewList.swift`: the list, rows, expand state and
  drag-to-reorder with a drop marker (same pattern as `RangeReviewView`).
- `Views/Wizard/WizardPreviewColumn.swift`: `list: WizardPreviewListConfig?`
  adds the tab picker to the header; the tab is remembered per profile.
- The Full wizard and the Rough cut sheet pass no config and keep the
  video-only column.
