# Express reel list

Date: 2026-11-05. Status: implemented with this plan (Express only).

## Goal

In Express, the right column's List tab is **the reel**: one ordered list of
everything the user has selected across the Footage sections (Q&A,
Transcript, Highlights, Fight metrics) for the chosen video. Selecting an
item in any section adds it to the end of the reel; the reel stays as the
user switches sections and survives relaunch. A row's context menu
**Delete**, or the Delete key on the selected row, removes it from the reel,
which unselects it in its section. **Generate**, **Preview** and **Edit**
make one reel from the whole list in list order. Items that overlap in time
are kept, as listed.

## Where the reel lives

Profile database, table `express_reel_items` (schema 47), one row per reel
item per project and source video:

| column | meaning |
| --- | --- |
| `kind` | `MiniWizardFlow.FootageKind` raw value |
| `item_id` | Q&A: scene id of the exchange; Transcript: `transcript_picks.id`; Fight: `fight_picks.id`; Highlights: `wizard_selections.id` of the candidate |
| `position` | reel order |
| `scene_id`, `start_time`, `end_time`, `title` | snapshot, so the list draws rows of a section whose data is not loaded |

Not in `SyncTable` yet; joining Team Sync needs the Supabase migration first
(see `transcript_picks.kept`).

Membership stays owned by each section's store, as before: `qa_picks` rows,
`transcript_picks.kept`, a `fight_picks` row, and for Highlights the per
batch `mini.kept.<batch>` memory (Delete on an unloaded Highlights item
edits that memory so a restore does not bring the item back).
The reel reconciles against the loaded sections: whenever `AppStore.miniRuns`
changes, each loaded section's kept items are compared with the reel's rows
of that kind; rows whose item is no longer kept are dropped, kept items with
no row are appended, snapshots are refreshed (`MiniReelRules.reconcile`).
This is what makes a tick in Q&A, an Add in Transcript, a Keep box in
Highlights or a Team Sync pull all land in the reel without each call site
knowing about it.

## Pieces

- `Services/Wizard/MiniReel.swift` (pure): `MiniReelItem`, `MiniReelRules`
  (`kept(run:)` drafts per section, `reconcile`, `reordered(clipIDs:)`,
  `removing`, `clipID`, `candidates(items:runs:)` for Generate).
  Tests: `MiniReelRulesTests`.
- `WizardPreviewClips.reel(items:runs:scenes:)`: preview clips in reel
  order; a loaded section supplies the live range, else the snapshot.
- `Data/Database+ExpressReel.swift`: `fetchExpressReelItems`,
  `replaceExpressReelItems` (full rewrite, the list is short).
  Tests: `ExpressReelStorageTests`.
- `App/AppStore+MiniReel.swift`: load on source change, reconcile on
  `miniRuns` `didSet`, `reorderMiniReel`, `removeMiniReelItem(clipID:)`
  (unselects in the section: Q&A untick, Transcript uncheck, Fight pick
  deleted, Highlights candidate unkept), `generateMiniReel` (loads every
  section the reel names, records each section's selections in turn, then
  renders one combined take from the candidates in reel order).
- `Views/Wizard/WizardPreviewList.swift`: `onDelete` in the config adds the
  row context menu and `onDeleteCommand`.
- `Views/MiniWizardView.swift`, `Views/MiniGeneratePanel.swift`: the preview
  shows the reel; Generate is enabled by the reel's count.

## Limits

- Highlights items keep only the first cut in their snapshot; once the
  Highlights section is loaded every cut shows. A reel that names a
  Highlights batch no longer remembered skips those items with a log line.
- Highlight history records the reel under the section open at Generate.
- A transcribed source with no analyzed scenes has reel rows but an empty
  List until its picks become selections (a preview clip needs a scene).
- Delete and reorder wait while a section is loading, so a load that
  already read its picks cannot put a deleted item back.
