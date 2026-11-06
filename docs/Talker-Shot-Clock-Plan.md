# Talker full screen: a shot clock

Date: November 6, 2026. Status: implemented.

## Goal

Speaker focus with the Talker full screen shot (chosen, or Auto with no VIP)
keeps one person full screen, cutting to whoever talks. Two timings replace
the VIP focus rows Asker and Hold for that shot:

- **Max continuous shot** (seconds, default 8, range 3–30): when the same
  person has held the picture this long, the picture cuts to the most recent
  other speaker (round-robin over the others when nobody else has spoken).
- **Min continuous shot** (seconds, default 2, range 1–10, never above Max):
  every shot stays at least this long. After a forced cutaway the picture
  returns to whoever is talking once Min has passed, or stays if the person
  shown is the one talking. A talker change moves the picture no earlier
  than Min after the last change.

Every change of the person shown restarts the clock.

The Shot row sits right below Framing, before Pull back.

## Pieces

- `Services/Framing/TalkerShotPlanning.swift` (pure): defaults, ranges,
  `events(segments:range:order:maxShot:minShot:)`.
- `Framing.talkerMaxShot` / `talkerMinShot` (`talker_max_shot`,
  `talker_min_shot`, nil = default); `CropRecipe.talkerMaxShot` /
  `talkerMinShot`, set by `FramingPlanner` only when Speaker focus resolves
  to the Talker full screen shot, so Center stage and VIP B-Roll, which also
  plan as `.talker`, keep their plain cut-to-talker rhythm.
- `CropRecipePlanner.plan`: the talker cell of a `.talker` recipe with both
  timings uses the shot clock instead of `talkerEvents`.
- `FramingRows`: Shot moved under Framing; `talkerShotRows` shown for Talker
  full screen and for Auto without a VIP.
- Tests: `TalkerShotPlanningTests`, Framing coding and planner mapping.

## Follow-up (same day)

The VIP focus shot left the Shot menu: Auto never resolves to it, a stored
choice reads as Auto, and its Asker / Hold / Sentences / Moves rows are
gone. The `interview` recipe kind and planner path remain for saved
recipes and Builder scripts.

## Limits

- "Finish the sentence" does not apply to the shot clock.
- A single feed has nobody to cut to; the clock is a no-op there.
