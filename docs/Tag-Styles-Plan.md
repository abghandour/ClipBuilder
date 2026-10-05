# Tag Styles Plan

Date: 2026-10-05. Status: implemented in 1.94. The description line comes only from the per-person tag field (People has no role text; `descriptor` is the visual description), which replaces the "role saved in People" wording below.

## Goal

A "Tags" pane in the sidebar, next to Captions, where a profile keeps named
name-tag styles. A tag is always two lines, the person's name and a
description (profession, MMA record, ...), each styled on its own, with
optional underlines and freely placed images. The AI Wizard Mini and the full
Wizard pick a tag style where they pick an overlay template today.

Decisions the user made on 2026-10-05:

- Description text: the role saved in People; the AI writes it only when a
  person has none, guided by the line's field name.
- Images: free placement around the two lines.
- Each line has its own full set of text settings.
- Both Mini and the full Wizard switch to tag styles. Saved runs that named an
  overlay template fall back to the profile's default tag style.

## What exists

- `Views/CaptionStylesView.swift`, `CaptionStyleEditor.swift`,
  `CaptionStylePicker.swift`, `CaptionStylePreview.swift`,
  `Data/NamedCaptionStyle.swift`: the pattern to mirror. Styles live on
  `BrandProfile` (`captions` default plus `captionStyles`), selected in runs by
  UUID string (`captionStyleID`).
- `Services/Wizard/NameTagPlanner.swift` (placement), `WizardNameTags.swift`
  (options to overlays), `TextOverlayRenderer.nameTagLayout` / `drawNameTag`
  (design `"nameTag"`, second line at 0.72 of the first, one shared style).
- `Views/NameTagControls.swift`: shared by `MiniSettingsCard` and
  `WizardView`. "Tag shows" (name / name and role), "Tag style" (overlay
  template names, first text item used as the style), "Tag position".
- `WizardOptions.nameTags`, `nameTagContent`, `nameTagStyle`,
  `nameTagPosition`; mirrored in `WizardOptionsSteps`, `WizardOptionsDecoding`,
  `MiniWizardSettings`, `MiniWizardMemory`, `AIRunSettings`,
  `AISettingsPreferences`.
- `WizardEngine` identifies tags in documents by `design == "nameTag"`.

## Phase 1: model, layout, rendering

`Data/TagStyle.swift`, all `nonisolated`, `Codable`, `Sendable`, `Hashable`,
every property decoded with `decodeIfPresent` and a default (see
`CaptionStyle`), snake_case keys:

- `TagLineStyle`: `field` (the line's field name), `font` (nil = default
  sans, else system or asset family, as `CaptionStyleEditor.fontFamily`),
  `scale` (size relative to the tag's base size; 1.0 for the name, 0.72 for the
  description), `color`, `bold`, `italic`, `uppercase`, `underline`,
  `underlineColor` (nil = text colour), `underlineThickness` (fraction of the
  line's font size, default 0.06).
- `TagImage`: `id`, `path` (Images library), `x`, `y` (centre, as fractions of
  the text block's width and height, may fall outside 0...1), `width`
  (fraction of the text block's width; height follows the image's aspect),
  `opacity`, `behindText`.
- `TagStyle`: `name: TagLineStyle` (field fixed to "Name"),
  `description: TagLineStyle` (field default "Role", user-editable),
  `alignment` (leading default / center / trailing), `bgOn` (default true),
  `bgColor`, `bgOpacity`, `cornerRadius`, `images: [TagImage]`.
- `NamedTagStyle { id, name, style }`.
- `BrandProfile.tagStyle: TagStyle?` (profile default; nil = built-in default
  that matches today's look) and `tagStyles: [NamedTagStyle]?`, with
  `tagStyle(id:)` like `captionStyle(id:)`.

`Services/Wizard/TagLayout.swift`: a pure `nonisolated enum` that, given line
sizes, padding, and image aspect ratios, returns the text block rect, each
line's origin and underline rect, each image's rect, and the union bounds.
Tests next to it.

Rendering: `TextOverlayItem` gains `tagStyle: TagStyle?` (key `tag_style`,
encoded only when set). `nameTagLayout` and `drawNameTag` use it when present:
per-line font, colour, case, underline; images behind then text then images in
front; the item's rect is the union bounds, so `NameTagPlanner` places and
fits the whole tag including images. A nil `tagStyle` renders exactly as
today, so saved timelines do not change. Images load off the main actor; a
missing image file is skipped and logged, never a render failure.

`NameTagPlanner`: `template: TextOverlayItem?` becomes `style: TagStyle`.
Lines are always name plus description; the description line is dropped only
when there is no text for it. `Settings.content` goes away.

## Phase 2: the Tags pane

- `SidebarSection.tags` after `.captions` (title "Tags", symbol `tag`),
  destination wired in `ProjectWorkspaceDetail` with
  `.id(store.activeProfile.profileName)`.
- `Views/TagStylesView.swift`: same shell as `CaptionStylesView` (header with
  New Style / Duplicate / Delete, list with "Profile default" first, editor on
  the right, delete confirmation, saves through `store.saveActiveProfile()`).
- `Views/TagStyleEditor.swift`: sections "Tag style" (name, alignment,
  background, corner radius), "Name line", "Description line" (field name
  text field with a menu of suggestions: Role, Profession, MMA record, Team,
  Nationality; caption explaining that the role saved in People is used and
  the AI fills this field for people without one), "Images" (add from the
  Images library, list with opacity, in front / behind, remove), "Preview".
- `Views/TagStylePreview.swift`: draws through the real renderer on a dark
  backdrop with sample text ("Alex Morgan" and a sample for the field).
  Images are dragged and resized directly on the preview (see
  `OverlayPreviewCanvas`, `ResizeHandle` in `OverlayTemplatesView.swift`);
  the list row selects the image. Rendering for the preview runs off the main
  actor and is debounced.
- Control text is `lineLimit(1)` plus `fixedSize`.

## Phase 3: Wizard and Mini

- `WizardOptions.nameTagStyleID: String?` (nil = profile default), carried
  through steps, decoding, `MiniWizardSettings`, `MiniWizardMemory`,
  `AIRunSettings`, `AISettingsPreferences`. `nameTagStyle` and
  `nameTagContent` stay decodable and are ignored.
- `NameTagControls`: "Tag style" lists "Profile default" plus the active
  profile's tag styles (follow `CaptionStylePicker`); "Tag shows" is removed;
  "Tag position" stays. An id that no longer exists reads as Profile default.
- `WizardNameTags` resolves the style from the profile and passes it to the
  planner; call sites in `WizardEngine`, `PodcastRecipeTimeline`,
  `WizardPodcastTimeline` pass the profile.

## Phase 4: AI description when People has no role

- `AITask.tagText = "tag_text"` with an `AICatalog` entry ("Name tag text",
  same default and chain as `.captions`).
- `Services/Wizard/TagTextWriter.swift`, pure: builds one batched prompt for
  the people in the reel whose `descriptor` is empty (field name, each
  person's name, category, and a short transcript excerpt of what they say),
  parses `{ "<person key>": "<text>" }` with `AIResponseParser.jsonObject`,
  trims to one line and 40 characters, drops empty or echoed-name answers.
- Answers are cached per person and field in a new `person_tag_fields` table
  (`person_key`, `field`, `value`, `provenance`), so a later reel does not ask
  again. A saved People role always wins over the cache.
- `WizardEngine` runs it once per run before timelines are built, inside the
  existing wizard task (no sheet), logs the model, records the stage in the
  output's AI details, propagates cancellation, and on failure renders the
  name alone.
- People: the person inspector lists AI-written tag fields under the role,
  editable and clearable, so the text is visible and correctable.

## Tests

`TagStyleTests` (decoding old profile JSON, defaults, round trip),
`TagLayoutTests`, updated `NameTagPlannerTests`, `TagTextWriterTests`,
`WizardEngineTests` with the stub AI (one batched call, cache reuse, role
wins, failure renders name only, cancellation), updated Mini settings, memory,
flow, steps, form-plan and task-registry suites.

## Verification

Claude: `build-for-testing` (Debug), the suites above, then the app on scratch
data: create a style with an underline and an image, generate a Mini reel with
name tags, check the tag in the output.
