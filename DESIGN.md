---
name: Clip Builder
description: A compact native macOS workbench for moving project footage from source to finished clip.
colors:
  action-blue: "#2F6FE0"
  action-blue-hover: "#3D7CE8"
  project-blue: "#6AA5FF"
  canvas-graphite: "#1C1C1E"
  chrome-graphite: "#232325"
  raised-graphite: "#3A3A3D"
  control-border: "#4A4A4E"
  deep-divider: "#101010"
  text-primary: "#E6E6E6"
  text-secondary: "#B0B0B5"
  text-tertiary: "#8D8D92"
  source-orange: "#FF9F0A"
  timeline-purple: "#BF5AF2"
  output-green: "#30D158"
  instagram-pink: "#FF375F"
  resource-teal: "#40C8E0"
  white: "#FFFFFF"
typography:
  headline:
    fontFamily: "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, sans-serif"
    fontSize: "15px"
    fontWeight: 700
    lineHeight: 1.25
  title:
    fontFamily: "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, sans-serif"
    fontSize: "13px"
    fontWeight: 600
    lineHeight: 1.3
  body:
    fontFamily: "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
  caption:
    fontFamily: "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, sans-serif"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.3
  label:
    fontFamily: "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, sans-serif"
    fontSize: "11px"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "0.2px"
  badge:
    fontFamily: "'SF Mono', Menlo, Monaco, monospace"
    fontSize: "10px"
    fontWeight: 700
    lineHeight: 1.2
rounded:
  chip: "4px"
  media: "6px"
  card: "10px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
components:
  button-primary:
    backgroundColor: "{colors.action-blue}"
    textColor: "{colors.white}"
    typography: "{typography.body}"
    rounded: "{rounded.media}"
    padding: "0 12px"
    height: "26px"
  button-primary-hover:
    backgroundColor: "{colors.action-blue-hover}"
    textColor: "{colors.white}"
    typography: "{typography.body}"
    rounded: "{rounded.media}"
    padding: "0 12px"
    height: "26px"
  button-secondary:
    backgroundColor: "{colors.raised-graphite}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    rounded: "{rounded.media}"
    padding: "0 12px"
    height: "26px"
  project-switcher:
    backgroundColor: "rgba(106, 165, 255, 0.16)"
    textColor: "{colors.text-primary}"
    typography: "{typography.title}"
    rounded: "{rounded.media}"
    padding: "0 12px"
    height: "34px"
  sidebar-row-selected:
    backgroundColor: "{colors.raised-graphite}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    rounded: "{rounded.media}"
    padding: "0 10px"
    height: "28px"
  project-card:
    backgroundColor: "{colors.raised-graphite}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    rounded: "{rounded.card}"
    padding: "10px"
  project-card-home:
    backgroundColor: "{colors.raised-graphite}"
    textColor: "{colors.project-blue}"
    typography: "{typography.body}"
    rounded: "{rounded.card}"
    padding: "10px"
  search-field:
    backgroundColor: "{colors.canvas-graphite}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    rounded: "{rounded.media}"
    padding: "0 10px"
    height: "28px"
  chip-builder:
    backgroundColor: "rgba(191, 90, 242, 0.16)"
    textColor: "{colors.timeline-purple}"
    typography: "{typography.badge}"
    rounded: "{rounded.chip}"
    padding: "2px 6px"
    height: "18px"
  chip-wizard:
    backgroundColor: "rgba(48, 209, 88, 0.16)"
    textColor: "{colors.output-green}"
    typography: "{typography.badge}"
    rounded: "{rounded.chip}"
    padding: "2px 6px"
    height: "18px"
---

# Design System: Clip Builder

## Overview

**Creative North Star: "The Native Editing Workbench"**

Clip Builder should feel like a focused macOS production tool: compact, media-led, and ready for sustained work. Project scope is the primary orientation, while the interface stays visually quiet enough that footage, timelines, and output status carry the visual energy.

The system uses native SwiftUI controls and semantic system behavior, then adds a restrained graphite hierarchy, a small set of wayfinding hues, and gently rounded working surfaces. It avoids ornamental dashboard chrome, oversized marketing typography, and visual treatments that compete with video. Dark appearance is the binding reference; system colors, keyboard navigation, text scaling, and reduced-motion preferences must continue adapting through native APIs.

**Key Characteristics:**

- Dense, legible native macOS controls
- Project scope visible before workflow navigation
- Media thumbnails as the strongest visual elements
- Tonal graphite layers instead of decorative containers
- Semantic color reserved for wayfinding, state, and action
- A consistent 4-point spacing rhythm

## Colors

The palette is a quiet graphite workspace punctuated by familiar macOS hues that identify workflow families without recoloring whole surfaces.

### Primary

- **Decisive Action Blue** (`#2F6FE0`): Reserved for the current selection, primary commit action, progress, and focused interactive state.
- **Project Link Blue** (`#6AA5FF`): Marks project identity and project-switching controls without competing with the primary action.

### Secondary

- **Source Amber** (`#FF9F0A`): Sources, scenes, and people wayfinding.
- **Timeline Orchid** (`#BF5AF2`): Timeline and Builder identity, including Builder-type badges.
- **Output Green** (`#30D158`): Outputs, successful completion, and Wizard-type badges when the meaning remains distinct from success.
- **Instagram Pink** (`#FF375F`): Instagram navigation and account-specific surfaces.
- **Resource Cyan** (`#40C8E0`): Shared studio resources and asset navigation.

### Neutral

- **Canvas Graphite** (`#1C1C1E`): The main editing ground and deepest ordinary workspace surface.
- **Chrome Graphite** (`#232325`): Sidebar and toolbar chrome that frames content.
- **Raised Graphite** (`#3A3A3D`): Cards, selected navigation rows, and secondary controls.
- **Control Border** (`#4A4A4E`): Quiet definition around actionable controls when a native boundary is needed.
- **Deep Divider** (`#101010`): Split-view separators and strong structural dividers.
- **Primary Ink** (`#E6E6E6`): Main titles, names, and actionable labels in dark appearance.
- **Secondary Ink** (`#B0B0B5`): Metadata, explanatory copy, and secondary measurements.
- **Tertiary Ink** (`#8D8D92`): Section labels, shortcuts, timestamps, and low-emphasis status.

**The Wayfinding, Not Wallpaper Rule.** Workflow hues identify icons, compact badges, selection, and status; they do not become large decorative backgrounds.

**The Semantic Adaptation Rule.** SwiftUI implementations use semantic system colors and preserve contrast in every appearance; the dark reference values in the frontmatter are the portable visual baseline, not permission to hard-code an inaccessible theme.

## Typography

**Display Font:** SF Pro Text (with the native system and Helvetica Neue fallbacks)
**Body Font:** SF Pro Text (with the native system and Helvetica Neue fallbacks)
**Label/Mono Font:** SF Mono (with Menlo and Monaco fallbacks)

**Character:** The type system is compact and utilitarian, with weight supplying hierarchy instead of large changes in scale. Monospaced digits make durations, shortcuts, scores, and timeline positions stable while editing.

### Hierarchy

- **Headline** (bold, `15px`, `1.25`): Window and detail titles that establish the current document or collection.
- **Title** (semibold, `13px`, `1.3`): Project names, timeline names, card titles, and compact section anchors.
- **Body** (regular, `13px`, `1.35`): Standard controls, rows, and concise working copy.
- **Caption** (regular, `11px`, `1.3`): Counts, timestamps, status details, and supporting metadata.
- **Label** (bold, `11px`, `0.2px` tracking): Uppercase sidebar groups and compact structural labels.
- **Badge** (bold monospaced, `10px`, `1.2`): Durations, scores, keyboard shortcuts, and dense media overlays.

**The Working Scale Rule.** New production surfaces stay within the established headline-to-caption range; larger type is reserved for empty states, not routine navigation or editing chrome.

**The Stable Numbers Rule.** Use monospaced digits for timecodes, duration, progress, scores, and count-like data that changes in place.

## Layout

The app uses a native split workspace. The sidebar stays compact (`210–290px`, ideally `240px`) and orders controls from profile to project to Project and Studio navigation, with Activity anchored at the bottom. The Project group follows the work in order: Sources, Scenes, AI Wizard, Timelines, then Outputs; Wizard remains a project-scoped production section rather than a global utility. The detail pane owns the active project surface; deeper editing may split again into media browser, preview, inspector, and timeline, but project context remains visible.

Spacing follows the shared `4 / 8 / 12 / 16 / 20px` rhythm. Dense rows use the lower half of the scale; cards and page gutters use `16–20px`. Project cards use an adaptive grid with widths from `250–320px`, adding columns as room allows rather than stretching cards across the window. Media grids prioritize consistent aspect ratios and make scrolling available before compressing thumbnails below useful inspection size.

Toolbars place identity at the leading edge and primary actions at the trailing edge. Segmented controls consolidate sibling views such as All/Curated, Posts/Reports, and resource kinds without multiplying top-level navigation. Native split-view collapse, keyboard commands, and system-sized controls provide compact-window behavior.

**The Scope-First Rule.** Profile and project identity precede workflow navigation. A detail surface must never make the user infer which project its media or output belongs to.

**The Four-Point Rule.** Use values from the shared spacing scale before introducing a new gap or inset.

## Elevation & Depth

The workspace is flat by default. Depth comes from adjacent graphite tones, separators, selection fills, media clipping, and native materials rather than persistent drop shadows. Shadows are reserved for content that genuinely floats above the workspace: modal progress surfaces and media play overlays. Native window and menu elevation remains system-owned.

### Shadow Vocabulary

- **Media Overlay** (`0 2px 8px rgba(0, 0, 0, 0.60)`): Keeps white playback or title affordances legible over moving imagery.
- **Modal Lift** (`0 8px 24px rgba(0, 0, 0, 0.32)`): Separates a blocking progress card from its material scrim.

**The Flat Workspace Rule.** Cards and panes are tonal at rest. Do not add a shadow merely to make a container feel clickable.

## Shapes

The form language is gently rounded and compact. Chips use a tight `4px` radius, media and ordinary controls use `6px`, and cards use `10px`. Thumbnails clip cleanly to their container, while native controls keep their platform-standard silhouettes and focus treatment. Borders are thin and structural: use them for selection, control definition, or pane separation, not as decoration around every group.

**The Nested Radius Rule.** Inner media uses the smaller media radius inside a card, leaving the larger card silhouette visible around it.

## Components

### Buttons

Buttons feel native, direct, and workmanlike.

- **Shape:** Compact native control with gently rounded edges (`6px` portable reference).
- **Primary:** Action blue with white text, a `26px` reference height, and `12px` horizontal padding. Use one prominent action per immediate decision group.
- **Hover / Focus:** Brighten to action-blue-hover on pointer hover; preserve the native focus ring and keyboard activation.
- **Secondary / Ghost:** Raised graphite with a quiet border for ordinary commands; plain icon or text buttons are appropriate inside lists and media surfaces.

### Chips

Chips are compact type and state markers, not miniature buttons.

- **Style:** Bold badge typography, `4px` corners, `2px 6px` padding, and a low-opacity semantic fill.
- **State:** Timeline Orchid identifies Builder documents; Output Green identifies Wizard documents. Scores and warnings retain their domain-specific colors and always include text or icon meaning.

### Cards / Containers

Cards are low-elevation work surfaces led by real media.

- **Corner Style:** Gently rounded (`10px`), with nested thumbnails at `6px`.
- **Background:** Raised graphite or the equivalent semantic secondary background.
- **Shadow Strategy:** Flat at rest; see the Flat Workspace Rule.
- **Border:** None by default. Add a semantic stroke for drop, focus, or selected state only.
- **Internal Padding:** Compact card inset (`10px`) with `8–12px` internal rhythm.

### Inputs / Fields

Inputs are native and visually recessive until focused.

- **Style:** System text field or search field on a dark recessed surface, with `6px` portable corner reference.
- **Focus:** Use the native macOS focus ring and insertion behavior; do not substitute a decorative glow.
- **Error / Disabled:** Preserve native disabled opacity and pair errors with text or an icon rather than color alone.

### Navigation

Navigation is a compact native sidebar. Group labels are uppercase and tertiary; rows pair a semantic SF Symbol with a plain text label and an optional monospaced keyboard shortcut. The selected row uses a neutral raised fill, while the project switcher receives a restrained Project Link Blue tint and stroke so project scope remains distinct from the current section.

### Project Card

A project card opens with up to three equal media thumbnails, then shows a two-line project title, source/timeline/output counts, and a quiet relative last-opened timestamp. Its entire surface is clickable, supports file drop, and keeps management actions in the context menu so the home grid remains scannable.

Home keeps the same media-led card geometry but uses `house.fill` and Project Link Blue on its title to mark the durable catch-all workspace. It offers Open Home without rename, archive, duplicate, or delete actions; ordinary projects retain the folder treatment and management menu.

### Confirmation Dialogs

Destructive project and timeline actions use the native macOS confirmation dialog with an explicit destructive role and Cancel action. When deletion has a preservation path, such as moving timelines to Home, present that path as a plain secondary choice and state what remains in Home in the dialog message.

**The Native Destruction Rule.** Keep destructive decisions in system confirmation surfaces; do not replace them with custom cards, inline warnings, or ambiguous unlabeled buttons.

### Timeline Row

A timeline row combines an `84 × 46px` thumbnail, document name, Builder or Wizard chip, one line of metadata, monospaced duration, an explicit Open action, and an overflow menu. Rows remain visually flat and aligned; document kind and duration must be recognizable without opening the editor.

## Do's and Don'ts

### Do:

- **Do** use native SwiftUI controls, system colors, keyboard focus, and accessibility behavior as the implementation source of truth.
- **Do** keep project identity visible when moving from sources through scenes, AI Wizard, timelines, and outputs.
- **Do** distinguish Home with the house symbol and restrained project tint while preserving the shared project-card geometry.
- **Do** use native confirmation dialogs for destructive project and timeline actions, with a clearly labelled preservation alternative when one exists.
- **Do** use the `4 / 8 / 12 / 16 / 20px` spacing scale and the `4 / 6 / 10px` radius family.
- **Do** let footage thumbnails, preview frames, waveforms, and timeline blocks carry the visual density.
- **Do** pair status color with a label, icon, pattern, or shape so meaning survives reduced color perception.
- **Do** use relative dates in user-facing recency labels and monospaced digits for time-based data.

### Don't:

- **Don't** turn workflow tints into large decorative panels or gradients.
- **Don't** add a top-level destination when a segmented control or contextual action keeps the same scope clear.
- **Don't** use persistent shadows around ordinary cards, rows, or panes.
- **Don't** introduce oversized headings, spacious marketing layouts, or non-native control chrome into production screens.
- **Don't** hide project scope during long-running analysis, rendering, or Wizard work.
- **Don't** hard-code the dark reference palette in SwiftUI where a semantic system color provides adaptive contrast.
