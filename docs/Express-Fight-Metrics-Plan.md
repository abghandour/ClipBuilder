# AI Wizard Express: Fight metrics, mute source audio, music

Date: 2026-10-18. Status: implemented (all four phases), awaiting a live pass.

## What the user asked for

- A fourth Express footage kind, **Fight metrics**, for fight and training
  videos, laid out like Transcript (three columns). Left: a chronological
  grid of every scored fight action (time, fighter, action). Middle: the
  player with the trimmer always visible. Right: the picks added to the
  video. Picking several actions that form one unbroken stretch of time
  turns them into one pick, so a transition sits between combinations,
  not inside them. Actions of different kinds merge too.
- Each action spans half a second before and after its scored time (an
  attempt from half a second before the shot to half a second after it
  resolves); the user trims from there.
- When a video has no scored actions the option still shows, with a
  message pointing at the fight scoring pass on the Analyze page.
- Picks persist per video, like transcript picks.
- Settings for fight and training videos only: **Mute source audio** and
  **Music** (on: a combobox of the profile's music library, "Random"
  first). Express never reads the full Wizard's audio settings.

## Decisions

- Picks are stored in `fight_picks`, a sibling of `transcript_picks`, with
  the scored event ids the pick came from. Moving to Settings turns picks
  into one selection per pick, in list order, tagged `fight-pick`.
- The grid lists the actions exactly as the Builder's Fight Action
  inspector counts them (strike clusters deduplicated, attempt chains
  merged), so the two surfaces agree.
- Merging happens when the user presses Add: the selected actions are
  sorted by time and runs whose padded spans touch or overlap become one
  pick. An Add with several separate runs adds several picks. Existing
  picks are not merged retroactively; the user can trim them.
- Mute source audio works without music (a silent reel). Music on without
  mute keeps the source under the track. The track is chosen from the
  whole music library; "Random" lets the render pick by duration as the
  full Wizard does, without the Wizard's folder restriction.

## Phases

1. Rules and data: `MiniWizardFightRules` (actions, merging, titles,
   plans), `FightPick`, `Database+FightPicks`, tests.
2. Flow and store: `FootageKind.fightMetrics`, `MiniWizardRun.fight`,
   `AppStore+MiniFight` (load, add, trim, reorder, delete, record
   selections), Express view hooks (auto-load, Settings handoff).
3. Review surface: `MiniFightPickView` over `RangeReviewView` with a
   leading action grid in place of the transcript words.
4. Audio settings: `MiniWizardSettings.muteSourceAudio / music /
   musicTrack`, Settings card rows, step 2 mapping, memory, preset
   bridge, tests.

## What shipped and where it deviates

- Phase 1: `MiniWizardFightRules` (actions, span, units, title, plan),
  `FightPick`/`MiniWizardFight`, `fight_picks` table, `Database+FightPicks`,
  `MiniWizardFightTests` (rules plus a storage round trip).
- Phase 2: `FootageKind.fightMetrics`, `MiniWizardFlow.isFightOrTraining /
  showsAudioOptions`, `MiniWizardRun.fight`, `AppStore+MiniFight`,
  `AppStore.fightPickSaveTask`, Express view dispatch and captions.
- Phase 3: `MiniFightPickView` with a `Table` action grid passed to
  `RangeReviewView` as its new `leadingPanel`; `emptyDraftHint` replaces the
  transcript-specific hint. The grid marks actions already in a pick with
  a check. Play All is on for the picks list.
- Phase 4: `MiniWizardSettings.muteSourceAudio / music / musicTrack`, rows
  in `MiniSettingsCard` (track list read off the main thread), memory keys,
  `WizardPresetBridge` fields (`useMusic`, `muteSource`, `musicTrack`),
  summary parts, tests.
- Deviation (user change after the live pass, 2026-10-18): automatic
  merging by unbroken time was replaced by an explicit choice. With two or
  more actions selected the draft offers **Add N picks** (one pick per
  action, no merging) and **Add N picks as one** (one pick from the
  earliest selected action to the latest, as previewed and trimmed).
  `MiniWizardFightRules.units` remains for callers that want the
  unbroken-time grouping; the view uses `span(of:)`.
- Not done: the Getting Started guide does not mention Fight metrics yet.

