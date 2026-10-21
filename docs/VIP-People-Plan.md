# VIP people: who the video is about

Date: October 20, 2026. Status: planned, not implemented.

## Goal

After people detection, each person on a video's roster carries a VIP flag:
the people the footage is about. In a fight that is the two fighters; in a
podcast or interview it is the guest, not the host. The AI sets it during
analysis and the user can override it per video. VIPs are preferred when
highlights are chosen, and a new Camera focus, "VIP focus", keeps a VIP on
screen: when a non-VIP talks the picture shows the VIP (their own feed in a
tiled recording, otherwise other footage of that VIP) while the talker's
audio continues.

Decisions (user, October 20, 2026): per-video flag; AI decides, user
overrides; VIP's own feed first, then other VIP scenes; a new Camera focus
choice rather than changing the existing ones.

## Where we stand

- People pass: `Analyzer.detectPeopleOnly` (`Services/Analyzer.swift:985`)
  builds `peopleOnlyPrompt` (`:911`) with the brand domain, duration, known
  people and markers, but not the video type or who talks how much. It parses
  `{"people":[{key, description, suggested_name, corrected_name, ranges,
  portrait}]}` and writes `replaceVideoPeople` (`Data/Database+Videos.swift:183`),
  which deletes and reinserts the video's rows. `PodcastAnalysisService:65`
  runs it after speaker separation, so turns exist for podcasts.
- Roster: `video_people(video_id, person_id, portrait_at, portrait_json,
  ranges_json, detected_at)`; `VideoPersonRecord` (`Data/Models.swift:416`).
  `video_people` is a Team Sync table (`SyncTable.footage`,
  `Services/TeamSync/SyncTable.swift:145`); a new column needs a Supabase
  migration and an `understoodSchemaVersion` bump (exact match gate).
  Schema version is 35 (`Data/Database.swift:831`); column migrations follow
  `Database+ScriptState.swift:336`.
- Speaker turns carry `personKey` and `tile` (`Data/PodcastModels.swift:71`);
  `CropRecipePlanner.tile(for:tiles:)` maps a turn to a feed.
- Highlights: `PodcastHighlightFinder.find` (`Services/PodcastHighlightFinder.swift:309`)
  sorts exchanges by `score`, each with `speakerKeys`; `WizardEngine.findPodcastHighlights`
  (`:461`) rebuilds exchanges from scene tags and loads the roster.
  Non-podcast selection filters scenes by `person:` tags (`WizardEngine:1910`).
- Camera focus: `CropRecipe.Kind` (`Data/CropRecipe.swift:69`) with
  `CropRecipeSubject` including `person(key)`; `CropRecipePlanner.plan`
  (`:307`) resolves slots per tile; `.person` needs a tile with that
  `personKey`. `WizardCameraFocusPicker` lists `Kind.allCases`;
  `CameraFocusChooser` offers kinds to the model; `WizardPodcastTimeline.cutDocuments`
  and `PodcastRecipeTimeline.build` apply the plan; `WizardPreviewFraming`
  previews any kind through the same planner.
- B-roll: `WizardPodcastBRoll.adding` (`Services/WizardPodcastBRoll.swift:48`,
  needs `useBRoll` and instructions) and `PodcastHighlightBRollPlanner`
  (`Sources.allows`, `Cut{.reaction(tile:) | .scene(id)}`, limits: none in the
  first 2 s, 3 s per cut, 40 % of the clip, 2 s spacing). Scenes carry
  `person:<key>` tags. `PodcastHighlightTimeline.add(cuts:)` places cutaways.

## Rules

- `vip` is per video on `video_people`, with `vip_source` ("ai" | "user").
  Re-running detection never overwrites a user value.
- New columns are Optional in records; existing JSON, DB rows and sync
  documents keep working. Schema version 36; `DatabaseTests` schema gate 36.
- Team Sync: add the two columns to `SyncTable.footage`'s `video_people`
  entry, add `supabase/migrations/20261021090000_vip_people.sql`
  (`ALTER TABLE public.video_people ADD COLUMN IF NOT EXISTS vip boolean,
  ADD COLUMN IF NOT EXISTS vip_source text; UPDATE public.schema_version SET
  version = 7`), and bump `SyncEngine.understoodSchemaVersion` to 7. The
  release that ships this must apply the migration first (`supabase db push`
  on project nekytkrbudqttttazhgo), or every client's sync stops at the gate.
- No model call is labelled AI unless one happens: the VIP judgement rides
  the existing people call; the rules fallback is named as such in the log.
- Pure logic (VIP rules, highlight boost, recipe planning, B-roll windows)
  lives in `nonisolated` enums under Services with tests next to them.

## Model

- `VideoPersonRecord` gains `vip: Bool?` and `vipSource: String?`
  (`isVIP` = `vip == true`). `Database.fetchVideoPeople` reads them;
  `replaceVideoPeople(videoID:entries:provenance:)` takes `vip: Bool?` per
  entry and keeps `vip`/`vip_source` of rows whose `vip_source == "user"`
  (read before the delete, re-applied after the insert).
- `Database.setVideoPersonVIP(videoID:personID:vip:source:)`.
- Merge, reassign and snapshot functions in `Database+People.swift` copy the
  new columns (they use `SELECT *`; verify the explicit column lists at
  `:142/151/165` and `:349/405`).

## AI judgement

`peopleOnlyPrompt` gains a "VIDEO" block: the video type (`VideoRecord.type`
label, or "unknown"), and for podcast-pass videos a "SPEAKING" block listing
each known person key with talk share (from `speakerTurns`, summed per
`personKey`) and who asks questions. It asks for `"vip": true|false` and
`"vip_reason"` per person with the rule text: fight or recap: the fighters
competing; podcast or interview: the guests, never the host (the host asks
the questions and talks most); training: the athlete being trained; other:
the people the footage is about, at most three.

`VIPRules` (`Services/VIPRules.swift`, nonisolated): `static func fallback(
videoType:, people: [(key, descriptor, category)], talkShare: [String: Double])
-> Set<String>` used when a person's answer has no `vip`: fight/recap:
category `.fighter` or descriptor containing "fighter" / "champion"; podcast/
interview with ≥ 2 speakers: everyone except the largest talk share; training:
none unless category `.fighter`; otherwise empty. Logged as
"VIP (rules): a, b".

Parse into the roster entries; `replaceVideoPeople` writes `vip_source =
"ai"` (or "rules") for rows that are not user-set.

## UI

- `PersonDetailPopover` "In this video": Toggle "VIP in this video"
  (`setVideoPersonVIP(... source: "user")`), with a caption showing the AI
  reason when present ("AI: the guest of the episode").
- `AnalyzeView` roster avatars (`VideoPersonAvatar`) show a star badge for
  VIPs; `DispatchPlanSheet.personChip` shows the star.
- `PeopleView` detail panel: "VIP in N videos" caption (count from
  `video_people`), no editing there (the flag is per video).
- Help text on the toggle: "The people this video is about. Highlights and
  VIP focus prefer them."

## Highlights

`PodcastHighlightFinder.find` takes `vipKeys: Set<String>` (from the roster)
and applies `HighlightVIPBoost.adjusted(score:speakerKeys:vipKeys:talkShare:)`
before sorting: +1.5 when any VIP speaks in the exchange, +0.5 more when VIPs
hold at least half of its speech, capped at 10. The prompt's exchange list
marks VIP speakers "(VIP)". `WizardEngine.findPodcastHighlights` and the Mini
caller pass the keys. Non-podcast scene ranking (`loadPlanningInputs` around
`:1910`): scenes tagged with a VIP sort ahead of equal-score scenes and the
prompt gets a line "VIP people: <names>".

## Camera focus: VIP focus

- `CropRecipe.Kind.vip = "vip"`, name "VIP focus", summary "Keep the VIP on
  screen: the VIP full screen, and their reaction while others talk."
  `layoutName` → full screen. `CropRecipeSubject.vip` ("vip" token):
  `defaultSlots(.vip)` → `[.vip]`.
- Planner, `.vip` slot: VIP tiles are tiles whose `personKey` is a VIP, or
  whose cell contains a VIP's roster portrait centre (the `WizardPreviewFraming`
  rule). Per `segments` stretch: talker tile is VIP → that tile (tracking);
  talker is not VIP → the most recently talking VIP tile, else the first VIP
  tile, as a still with tracking inside the feed; the cell's `talking` spans
  are the VIP's own turns. No VIP tile → behave as `.talker` and add
  `notes: ["No VIP on this recording; following the talker."]`.
- `CameraFocusChooser.allowedLayouts` includes `vip` only when the roster has
  a VIP; its prompt names the VIPs.
- Pickers list it through `Kind.allCases`; `WizardCameraFocus.summary` covers
  it. The preview column follows through `WizardPreviewFraming` unchanged.

## B-roll while a non-VIP talks

When `options.highlightFraming == .vip` (or the AI chose it) and the
recording has no VIP feed to cut to (single feed, or the VIP is the talker's
own feed), `WizardPodcastBRoll.adding` runs even without `brollInstructions`,
with `VIPBRollWindows.windows(turns:vipKeys:range:)` (nonisolated): the spans
where no VIP is talking, minimum 2 s. `PodcastHighlightBRollPlanner.Sources`
gains `preferredPeople: Set<String>`; in those windows the deterministic
planner and the placement prompt prefer, in order: `.reaction(tile:)` of a
VIP, `.scene` of the same video tagged `person:<vip>`, `.scene` from other
recordings tagged `person:<vip>`. Existing limits stay (3 s per cut, 40 %,
2 s spacing, nothing in the first 2 s), except a VIP window may hold
consecutive VIP cuts back to back up to the window length. Audio is
untouched.

## Phases

1. Schema, record, DB functions, sync table columns, Supabase migration
   file, `understoodSchemaVersion`; `DatabaseTests` (round trip, user value
   survives `replaceVideoPeople`), `SyncMigrationTests`.
2. Prompt, parse, `VIPRules` + tests (fight, podcast with host share,
   training, missing answers).
3. UI: popover toggle, avatar and chip badges, People caption.
4. Highlights: `HighlightVIPBoost` + tests; finder and engine wiring; scene
   ranking line.
5. Camera focus: kind, subject, planner + `CropRecipePlannerTests` (VIP
   talking, host talking, two VIPs, none); chooser; summaries. Check the
   preview resolves it (`WizardPreviewCompositeTests`: vip kind on a
   two-tile recording shows the VIP tile while the host talks).
6. B-roll: windows + sources preference + tests; engine trigger.
7. Verification: Debug build; live on a podcast with a host and a guest:
   detect people, guest shows the star, toggle it off and on and re-run
   detection (user value kept); Express with VIP focus previews the guest
   while the host talks; a render shows the guest feed over host speech;
   highlights lead with guest exchanges. Release: apply the Supabase
   migration before `scripts/release.sh`.
