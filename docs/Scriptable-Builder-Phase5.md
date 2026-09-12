# Scriptable Builder phase 5

Uncommitted implementation on top of `aefff33`. The final planned phase expands
Builder's closed JSON command surface, MCP schema and anchored local grammar.
No UI-parity claim, new editing UI, rendering implementation, schema migration,
xcodebuild, app launch, commit or push.

## Supported edits

- Music volume (integer 1...5), timeline range and movement through `updateSound`.
  Range edits refuse durations below 0.5 seconds, negative starts and ends after
  one day. These are timeline ranges; SoundItem has no source offset.
- Text content and top/center/bottom placement through `updateText`. Position
  clears x/y fractional overrides so text created by `addText` actually moves.
  Text is bounded to 16 KiB. Text, image and composition-block ranges use their
  own update methods. Text/image transitions use `TextOverlayItem.transitionChoices`.
- Clip speed in 0.5...2 through `updateClip`, retaining source start and using
  the inspector's nearest-0.1-second duration adjustment. Rounding may change
  consumed source span by up to half a screen tick; source overflow is refused.
  Speed changes also retain the model's B-roll fade clamping. Normal speed is
  represented by nil, matching the inspector.
- B-roll fades, each at most half the clip duration; clip captions with the
  model's B-roll/bumper restrictions; transitions from `cut` plus the canonical
  RenderEngine action and standard lists. `cut` uses the inspector's nil mapping.
- Center Stage enabling requires a wide main clip in Full Screen. Area windows
  require a crop-area assignment and captured source dimensions, fit inside the
  unit frame, retain the existing/default window's proportions and have width
  at least 0.1, following the inspector's resizing rules. Cover-all B-roll and
  bumpers cannot receive area windows.
- Track captions, mute, Full Screen default position and default crop fraction.
  `set_track_crop` requires `fraction`; explicit null clears the default crop.
- Render settings are a strict nested patch of `preset`, `custom_width`,
  `custom_height`, `quality`, and `custom_crf`. Omitted fields retain their
  current values, including inactive custom values. Dimensions must be even
  integers 240...7680; custom CRF is 10...35. Null and unknown fields are refused.
- Pacing is a strict `{cadence, curve}` object using all existing CutCadence and
  PaceCurve cases. It changes document pacing through `setPacing`; it does not
  generate a new edit plan.

## Explicit model limits

`set_sound_fades` is not part of the surface because SoundItem has no fade fields.
`set_track_volume` is not part of the surface because TrackSettings has no volume field.
`set_clip_screen_crop` is not part of the surface because the underlying model has no editable per-clip screen-crop fields; legacy screenCrop state is migrated to the cropping row, so use `set_crop_layout`.

Overlay blocks likewise have no block-level transitions; setting transitions on
one refuses instead of rewriting its composition's internal items. Track label
is persisted and fully diffed but has no editor in the inspected Builder UI.
Supported operations describe their eligibility limits in MCP schemas. The three
absent operations take the unknown-operation decode path before budget admission.

## Validation, diff and atomicity

> Refusal semantics below are superseded by the recoverable-edit rule (462e7d4); see [revision 2](Builder-Scripting-Plan.md#d3-execution-model).

Every new op has an explicit codec case, exact top-level field whitelist, schema
variant and value validation shared by JSON and direct Swift callers. Numeric
validation precedes serialization so NaN/infinity get `out_of_bounds` refusals.
The session preserves typed validation codes for these inputs; unknown session
UUIDs/bindings get `unknown_id`. Eligibility failures use `invalid_value`.
Unchanged setters skip mutation, including normalization that could otherwise
change unrelated fields. Inputs never accept source paths or metadata.

Execution remains synchronous on the transient model, under the captured layout
scope and existing resource budgets. A refused list rolls back; a failed session
has no applicable candidate. Valid runs freeze and use the existing phase 1b
snapshot Apply/Undo path without additional live undo registrations.

TimelineDiff already reflected all clip, sound, overlay, render and pacing
fields. Track settings previously appeared as a whole array; they now use
zero-based track keys and individual field paths. Tests mutate every expanded
stored field independently, including inactive and legacy fields, and check
exact diff paths. Wizard summaries add target/field/value lines for edits and
settings; the full field-level detail remains available.

## Local grammar and tests

Added exact phrases: `set this clip speed to 1.5x`, `captions off for this clip`,
`set music volume to 2` (exactly one sound), `set track 1 captions to bottom`,
and `mute/unmute track 1`. Visible track aliases and selection checks remain.
Both supported-request lists include the new shapes. Track-volume phrases stay
unrecognised because no such model setting exists. Extra clauses and negation
are never discarded.

Six new suites cover per-op round trips, unknown/missing fields, malformed values,
refusal codes, bindings, unchanged outcomes, overlay lanes, fractional placement,
source rounding and overflow, framing eligibility, field diffs, readable Wizard
lines, parser boundaries, schema fields, and mixed lists of 1/5/20 commands.
The Apply tests assert no live change/undo after failure, no undo during preview,
exact candidate values after Apply, and one Undo exhausting the run's registrations
followed by exact Redo. No new test awaits or uses DataFolderOverride.

## Verification and remaining work

- Focused Swift 6 typechecks passed for the changed/new command, validation,
  runner, session, parser, diff and MCP files against the previously built app
  module. Flags included default MainActor isolation,
  NonisolatedNonsendingByDefault, and the macOS 26 target.
- The six new test suites and updated parser suite passed focused typechecking
  in temporary copies with Testing attributes/macros replaced by ordinary
  functions. This verifies test bodies, not macro expansion or execution.
- Swift frontend syntax parsing passed for all changed/new Swift files with and
  without DEBUG. `git diff --check` passed.
- The installed Xcode beta compiler reports Swift 6.4; checks use Swift 6 language
  mode. The exact requested Swift 6.2 compiler was not available for these checks.
- No full app build, test-host linking, Swift Testing execution, Wizard UI,
  renderer output or real MCP/agent run was verified. Existing optional-to-Any
  warnings in ScriptRunner's addText/addImage result projection remain.

User: run the six BuilderExpansion suites, BuilderRequestParserTests,
BuilderScriptSessionTests, BuilderScriptApplyTests, MCPServerTests and the full
suite. Check preview → Apply → Undo for music, overlays, speed and settings, and
visually check area framing and caption/transition rendering. The other session's
protected files/hunks were not edited. PMB lesson-followthrough acknowledgement
was blocked by the session's never-approve policy.

## Changed files

- ClipBuilder/Services/Script/BuilderCommand.swift
- ClipBuilder/Services/Script/BuilderCommandValidation.swift (new)
- ClipBuilder/Services/Script/BuilderPacing.swift (new)
- ClipBuilder/Services/Script/BuilderRenderSettingsPatch.swift (new)
- ClipBuilder/Services/Script/BuilderRequestParser.swift
- ClipBuilder/Services/Script/BuilderScriptSession.swift
- ClipBuilder/Services/Script/BuilderWizardDiff.swift
- ClipBuilder/Services/Script/MCP/BuilderTools.swift
- ClipBuilder/Services/Script/ScriptRunner.swift
- ClipBuilder/Services/Script/ScriptRunner+Expansion.swift (new)
- ClipBuilder/Services/Script/TimelineDiff.swift
- ClipBuilderTests/Services/Script/BuilderExpansionApplyTests.swift (new)
- ClipBuilderTests/Services/Script/BuilderExpansionDiffTests.swift (new)
- ClipBuilderTests/Services/Script/BuilderExpansionFramingTests.swift (new)
- ClipBuilderTests/Services/Script/BuilderExpansionParserTests.swift (new)
- ClipBuilderTests/Services/Script/BuilderExpansionSchemaTests.swift (new)
- ClipBuilderTests/Services/Script/BuilderExpansionTests.swift (new)
- ClipBuilderTests/Services/Script/BuilderRequestParserTests.swift
- docs/Scriptable-Builder-Plan.md
- docs/Scriptable-Builder-Phase5.md (new; this report)
- HANDOFF.md (already ignored locally)
