# Captions parity: template library, filler cuts, gaze, and the rest

Date: November 4, 2026. Status: approved November 4, 2026, all phases kept; phase 1 implemented by Codex and verified by Claude on November 4, 2026 (build, caption suites, library and Express picker driven live), uncommitted; phases 2 to 5 not started.

## Why

Captions (captions.ai, by Mirage) only exposes burned-in captioning,
avatars and ad generation through its API, so none of its app features can
be bridged. This plan lists what we can build ourselves with the AI tools
already routed through `AITask` (text and vision models, image generation,
on-device Vision, transcription, translation, ElevenLabs and Mac voices),
in the order worth doing. Nothing here needs a new provider.

What we already match or beat, so it is not planned again: finding clips
(scenes, Q&A, highlights, soundbites, critic), word-level captions with
reveal, highlight and emphasis, per-speaker colours and positions,
translation, dubbing (Siri, Mac, ElevenLabs), noise reduction and loudness
(Speech polish), silence trims, framing, zoom and camera motion, B-roll
from the profile's own footage and image search, brand assets, Instagram
publishing and reports.

## Phase 1: caption template library

Captions sells "100+ caption styles" in three families: animated
word-by-word, highlights, and bold stacks. The twenty shown on its site are
named after stars and places: Cove, Energy, M81, Arion Pink, Quintessence,
Bellatrix, Prism, Freshly, Thuban, Mars, Runway, Grace, Copernicus,
Aldebaran, Nova, Alcyone Blue, Travel, Andromeda, Cassiopeia, Citadelle.
Only thumbnails are public, so the looks below are our own designs under
those names, plus the creator names every caption tool uses (Beast, Iman,
Ali, alongside our Hormozi and Karaoke).

Everything renders from `CaptionStyle` fields that exist today
(`wordsPerPage`, `weight`, `uppercase`, `highlight` colour/box/scale,
`emphasis`, `animation` pop/slide-up/fade, `reveal`, `bgOn`/`bgRadius`,
`decor` shadows, `position`, `emoji`, per-state `CaptionWordDecor`). Four
presets need small renderer additions, marked below.

| Name | Family | Settings |
| --- | --- | --- |
| Cove | word-by-word | 3 words, bold, reveal word, highlight colour (teal), soft shadow, bottom |
| Energy | word-by-word | 1 word, black, uppercase, highlight scale, pop, yellow emphasis, middle |
| M81 | highlights | 4 words, bold, highlight box (rounded, white on dark), no stroke |
| Arion Pink | highlights | 3 words, bold, highlight colour pink, emphasis colour, fade |
| Quintessence | bold stacks | 2 words, black, uppercase, two-line stack, slide-up, hard shadow |
| Bellatrix | word-by-word | 2 words, reveal word, highlight scale, glow shadow |
| Prism | highlights | 3 words, highlight colour cycling per page (renderer: colour list) |
| Freshly | bold stacks | 3 words, bold, boxed page, green bg, white text, radius 12 |
| Thuban | word-by-word | 1 word, black, uppercase, bounce animation (renderer: spring frames) |
| Mars | highlights | 3 words, bold, highlight box red, uppercase, pop |
| Runway | bold stacks | 4 words, serif bold, middle, letter spacing 0.05 |
| Grace | word-by-word | 3 words, serif, reveal word, italic emphasis (Interview Serif's cousin) |
| Copernicus | highlights | 3 words, mono, highlight underline (renderer: underline on highlight decor exists per state) |
| Aldebaran | bold stacks | 2 words, black, orange bg box, uppercase, hard shadow |
| Nova | word-by-word | 1 word, black, highlight scale, emoji on |
| Alcyone Blue | highlights | 3 words, bold, highlight colour blue, blue stroke |
| Travel | bold stacks | 3 words, bold, white bg, dark text, bottom |
| Andromeda | word-by-word | 2 words, reveal word, highlight colour purple, glow |
| Cassiopeia | highlights | 4 words, bold, highlight box yellow on black text |
| Citadelle | bold stacks | 2 words, black, uppercase, stroke 2, no bg, top |
| Beast | creator | 1 word, black, uppercase, highlight colour cycling (renderer: colour list), pop, emoji on |
| Iman | creator | 3 words, lowercase, light weight, highlight weight bold only |
| Ali | creator | 3 words, bold rounded sans, highlight colour, fade, bottom |

Renderer additions (two small ones): `highlightColors: [String]?` cycled per
page for Prism and Beast, and a `bounce` entry in `CaptionAnimation.frames`.
Glow and underline already exist through decor and `CaptionWordDecor`.

Library UI: the existing style library inserts a fresh copy of a preset;
add the family as a section header and a `CaptionPreviewImage` thumbnail
per preset so the list reads like Captions' gallery. Picker on the Express
Overlays tab lists the same groups.

Tests: every preset decodes and round-trips, no two presets are equal,
highlight, emphasis and speaker-colour defaults never collide (the
October 20 review rule), one preview render per family.

Effort: two days. Files: `Services/CaptionPresets.swift`,
`Services/CaptionAnimation.swift`, `Services/CaptionRenderer.swift`
(colour cycling), `Views/CaptionLibrary*.swift`, tests next to them.

## Phase 2: filler-word removal as a one-click option

We already have it, hidden: `TranscriptCleanupProposer` finds fillers,
stutters, false starts and retakes over the timed words,
`CleanupCutPolicy` (review / accept dead air / accept all) lives in the
podcast editing policy in Settings, proposals are reviewed in Transcript
Tools, and `WizardEngine` takes `cleanupCuts` into the plan (except the
podcast preset). The gap is that nothing on the wizard pages turns it on.

- New stored option `removeFillerWords: Bool?` on `MiniWizardSettings` and
  `WizardOptions` (Optional so existing JSON decodes). Default nil = off.
- Express Audio tab and Full wizard Settings: a toggle "Remove filler
  words" with the detail "Cuts um, uh and repeated starts from the kept
  footage. Review the cuts in the rough cut before generating."
- When on, the engine runs the proposer over each take's words with the
  profile's policy thresholds, accepts the filler and stutter proposals,
  and feeds them as `cleanupCuts`; dead-air trims stay governed by the
  existing Trim Silence. The podcast preset exception goes away for this
  path.
- Filler lists per language: the proposer's set is English only. Add
  Portuguese (né, tipo, então, hã, é), Spanish (este, o sea, eh, pues),
  French (euh, bah, genre), German (äh, ähm, halt), Arabic (يعني, اه),
  keyed by the transcript language.
- Rough cut and preview: cut spans show as markers on the scrubber so the
  user sees what will go; the run summary gains a "Filler words cut" chip.
- Tests: the proposer per language, the option round trip, a plan rule
  test that cuts never land inside a kept word.

Effort: one day. Files: `Data/WizardOptions.swift`,
`Services/Wizard/MiniWizardSettings.swift`,
`Services/TranscriptCleanupProposer.swift`, `Services/WizardEngine.swift`,
`Views/MiniSettingsCard.swift`, `Views/WizardView+Steps.swift`.

## Phase 3: eye contact

Honest answer: real gaze redirection repaints the eyes in every frame with a
generative model. Captions runs its own model for that; macOS ships no
such model, and none of our providers (text and vision LLMs, still image
generation) can re-synthesize video at frame rate. We cannot add the
Captions feature itself without their API, and the API does not expose it
either.

What we can add with Vision on device, as "Gaze-aware framing":

- `GazeMeter`: Vision face landmarks (pupil and eye contour points) and
  head pose yaw per sampled frame, through the same sampling the
  `InterviewFaceSampling` and `VisualSpeechActivity` passes use. Produces
  looking-away spans per person per recording, stored like camera motion.
- Framing planner: inside a looking-away span, prefer the other speaker's
  tile, a B-roll cut, or a punch-in, so the viewer sees the reading glance
  less. An option "Hide glances" on the Picture tab, off by default.
- Critic: a note when a reel's talking head looks away more than a third of
  the time, with the spans, so the user can reshoot or cut.
- If a CoreML gaze-redirection model becomes available, it plugs in as a
  clip effect through `EffectCatalog` without changing the above.

Effort: two days for the meter and planner rule, half a day for the critic
note. Files: new `Services/GazeMeter.swift` with a synthetic-frame test (the
camera motion meter's pattern), `Services/Framing/*`, `Services/ReelCritic.swift`.

## Phase 4: the rest of their app, feature by feature

| Captions feature | Where we stand | Plan |
| --- | --- | --- |
| AI Edit (describe the edit in words) | Ask AI on Express and the Builder agent already map text to settings and timeline edits | Nothing new; add two example prompts to the Ask AI placeholder |
| Auto zooms from the script | Interview zoom, punch-in and camera moves exist, keyed to speakers | Add an "Emphasis zoom" option: a short punch-in on `CaptionEmphasis` words (numbers, names), rate-limited to one per 6 s. Half a day |
| Sound effects | None; music and beat detection exist | A Sound effects resource (whoosh, pop, riser, bundled royalty-free set plus user files) and a plan rule that places one on transitions and emphasis zooms, mixed under the dub and music ducking. One day |
| AI B-roll generator | Image generation produces stills; B-roll comes from footage and image search | "Generate B-roll" in the B-roll panel: keywords from the transcript segment become image prompts, each still becomes a Ken Burns clip through the existing image overlay path. One day |
| Auto emojis | Exists (`emoji` on the style) | Make it visible: an Emoji toggle on the Overlays tab next to the template picker |
| AI Denoise | Exists as Speech polish | Rename the chip to "Denoise and level" so it is recognisable |
| Eye contact | Phase 3 | |
| Caption templates | Phase 1 | |
| Filler removal | Phase 2 | |
| Lipdub (lip sync to the dub) | Not possible with our tools; needs a video generative model | Out of scope |
| AI Twin, AI actors, text-to-video, AI ads | Not possible without their API; also outside the product's purpose (real footage) | Out of scope |
| Translate captions, 100+ languages | Exists through the translate task | Nothing new |

## Order and estimate

1. Phase 1 templates (two days). Visible, no risk.
2. Phase 2 filler option (one day). Mostly wiring.
3. Emphasis zoom and sound effects (one and a half days).
4. Generated B-roll (one day).
5. Phase 3 gaze-aware framing (two and a half days). Needs the meter first.

About eight working days in total, each phase shippable on its own.
