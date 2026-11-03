# Express Ask AI: a described reel sets the form

Date: November 2, 2026. Status: implemented November 2, 2026 (Claude), verified live; Codex read-only review done, 8 findings applied (framing choices per source type, dub languages from installed voices, overlay design resets texts, outputMode dropped, caption-language guidance, looks limited to the card, bottom name-tag corners, footage kind applied before an action).

## Why

On the AI Wizard page, Ask AI treated almost every typed request as a
highlight brief: the text went into the Highlights instructions field and
Generate was pressed. Only a short request with no reel words ("turn on
captions") reached the AI, and the AI could change seven Express settings
(length, four switches, transition, instructions). A description such as
"vertical 30 s reel of the best counters, Portuguese captions, music, no
source audio" therefore became an instruction line while every picture and
audio control stayed as it was. The user wants the AI button to drive the
form: read a requirement and choose the right selections.

## Design

- **Express routing.** In Express mode `WizardAssistant.handle` keeps only
  the regenerate shortcut; every other request goes to `AITask.assist`
  with the page context, the action catalogue and the full settings
  whitelist. Full mode keeps its old behaviour (hand the text to the
  Wizard's instructions and Generate).
- **Whitelist.** `WizardAssistant.expressSettings(profile:overlays:)`
  covers the Settings card: footage kind, length, quality, canvas, effect
  (look), transition, framing subject, captions with position, style and
  language, name tags with position and style, safe area, watermark with
  design and opacity, overlay with design, intro and outro, mute source
  audio, music, dub with language, output mode, AI instructions. B-roll is
  deliberately absent (Express B-roll is manual by decision of
  October 25, 2026). Music track and bumper choice are absent too (lists
  are loaded asynchronously by the card); the AI turns the switch on and
  the card's default applies.
- **Guidance.** `PageAssistant.understandingGuidance` is a page-specific
  paragraph appended to the prompt's TASK. Express tells the model to
  translate picture and audio requirements into settings, put "which
  moments" into `aiInstructions`, choose `express.findHighlights` only
  when the request asks to find or make the reel now, and otherwise leave
  the action null so the user reviews the form.
- **Action.** New `express.findHighlights`: the old hand-off (instructions
  from the patch, Footage set to Highlights, `generateMiniFootage`), run by
  MiniWizardView after the settings patch lands.
- **Apply.** `WizardAssistant.applyExpress` writes every new key into
  `MiniWizardSettings`, `footageKind` and `length`. Caption and name tag
  styles are matched by their profile ids (labels carry the names);
  framing sets `Framing.subject`.
- **Examples.** The Express chips show mixed requests so the user learns
  that settings are understood.

## Files

- Services/Assistants/PageAssistant.swift (guidance hook)
- Services/Assistants/PageAssistantPrompt.swift (guidance in TASK)
- App/AppStore+Assistant.swift (passes the guidance)
- Services/Assistants/WizardAssistant.swift (routing, whitelist, apply,
  action, guidance)
- Views/MiniWizardView.swift (footageKind in the patch, findHighlights)
- Tests: WizardAssistantTests, PageAssistantPromptTests

## Verification

Live in the scratch profile (Blachowicz vs Ulberg selected in Express):
"Square 1:1 reel of the knockdown, compact quality, vintage look, captions
at the top, music on, mute the source audio" set canvas square1080,
quality compact, look vintage, captions on at top, music on, source
muted, instructions "the knockdown", action null. The call took about
14 s through the Claude CLI, over the old 12 s limit, hence the separate
45 s `understandTimeout` for typed requests.

## Not done

- Full mode keeps the narrow whitelist and the deterministic hand-off.
- Music track and bumper selection by name.
