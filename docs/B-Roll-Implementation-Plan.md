# B-roll (cutaways) in the Builder timeline

Status: revision 4 (September 10, 2026) after Codex reviews 1 to 3 (all
REVISE; every item folded in). Phase 1 is in progress on the working tree. Scope: the timeline data model, Builder store
operations, the multitrack renderer, the live preview, and the timeline UI
including the B-roll picker. The Wizard does not produce cutaways in this plan.

## Vocabulary as the app has it today

- The **Cropping row** (`TimelineDocument.cropBlocks`) says which Screen Crop
  layout is on screen when. Each layout has areas; **Track N** feeds area N
  (`CropLayoutRef.area(forTrack:)`, `MultitrackRenderer.applyCropBlocks`).
  Full Screen is one unmasked area fed by Track I.
- Masking is per clip portion, not universal: with crop blocks a clip gets
  the area reference for each block it crosses and portions on a track with
  no area are discarded (`applyCropBlocks` 655–684); without crop blocks the
  legacy per-clip `screenCrop` applies; a clip with non-empty `freeCrops`
  bypasses mask generation and draws into its own rectangles (847–853,
  979–1027); an uncropped wide clip (no `cropXFrac`) under Full Screen
  occupies a slot band, not the whole canvas; a wide clip with `cropXFrac`
  is scaled and padded to the canvas.
- **Bumpers** are `TimelineClip`s with `bumper == true` drawn on the cropping
  row, never in a track. They cover the whole canvas. `.overlap` hides what is
  under them; `.pause` inserts a gap through `BumperPlanner.insertGap`: video
  crossing the gap is split with source continuity, sound crossing it is
  lengthened, later sound and overlay starts move, overlays are suppressed
  under the bumper (BumperPlanner 115–152). `removeGap` is the inverse and
  leaves split video as two adjacent clips.
- **Sequential** tracks repack from zero when `resolveLayout` is called
  (add, place, trim, role changes); `updateClip` does not repack.
  `resolveLayout` steps over pausing bumpers and splits a clip that would run
  into one (BuilderStore 883–927).
- The renderer splits the timeline at every clip and crop boundary
  (`buildLayeredSegments`, intervals under 0.05 s dropped), lets a bumper own a
  segment outright, otherwise `renderSegment` builds placements with
  `layer = clip.track`, sorts them, and generates masks keyed by the sorted
  index; `compositeLayeredSegment` sorts again and consumes those indexed
  masks (791–808, 847–853, 942–967). Audio mixes every unmuted placement with
  an audio stream; the volume gain is applied to bumpers only (1084–1104);
  track mute overrides clip audio (616–620).
- The fast preview flattens to one visible clip at a time and plays that
  clip's audio only; bumper beats everything, then the higher track wins
  (`previewPlan.outranks`). It applies no crop blocks and no area masks.

Rename: the row's label becomes **Screen** ("Screen: Full Screen" in the
toolbar, "Screen" lane header). Code names (`cropBlocks`, `CropLane`) stay.

## What a cutaway is

A cutaway replaces the picture of one area for a span while the clip
underneath keeps playing, keeps its audio, and keeps its position in time.

1. It never pushes and is never pushed by packing. Sequential repacking
   ignores cutaways; a cutaway does not move when its neighbours do and is not
   an obstacle for them. The one exception is a pausing bumper: a cutaway is
   footage bound to time, so an inserted gap shifts it like any video clip
   (see D2).
2. It is muted by default. The underlying clip's sound continues.
3. It is bound to time, not to one clip. It may straddle a cut between two
   underlying clips and may extend past the end of the track's content (the
   renderer composites over a black base; the timeline duration grows).
4. It belongs to a track, so it inherits that track's area under whatever
   layout is on screen. A cutaway can instead cover the whole canvas.
5. It never beats a bumper. Bumpers keep owning the canvas.

## D1. Model

`TimelineClip` gains:

- `role: ClipRole` — `.main` (default) or `.cutaway`. Encoded as `"role":
  "cutaway"`; absent decodes to main. The custom `init(from:)`, `encode(to:)`
  and `==` are extended explicitly (stored defaults alone do nothing in this
  custom decoder; the bumper-mode test is the pattern).
- `coverAllAreas: Bool` (cutaways only, default false). Encoded as
  `"cover_all"`.
- `cutawayAudio: CutawayAudio` — `.muted` (default) or `.mixed` (its sound is
  added to the mix; the underlying clip keeps playing). Encoded as
  `"cutaway_audio"`. Ducking is a later phase.

`enforceCutawayRules()`: `bumper` wins over `role` (a bumper is never a
cutaway; `enforceBumperRules` runs first and resets `role` to main). A cutaway
has `centerStage == false`, `captions == "none"`, `freeCrops == nil` (it must
stay inside its area; scene free crops are not copied on creation), and
`muted == (cutawayAudio == .muted)`. Cover-all cutaways additionally have
`screenCrop == nil`, `areaWindow == nil`, `wide == false`, `position == nil`,
and are framed by the renderer to fill the canvas (D3).

Role conversion is lossy by design and says so in the undo name ("Make
B-roll" / "Make main clip"): converting to cutaway drops captions, Center
Stage and free crops; converting back restores none of them and rejoins the
sequential chain at the clip's current time, which repacks from zero. Both
directions are timeline edits, not appearance changes, and the context menu
help says so.

`TimelineDocument` helpers: `mainClips(inTrack:)`, `cutaways(inTrack:)`.
`isOrphaned` treats a cover-all cutaway as never orphaned.

Compatibility, stated precisely:

- New reader, old document: unchanged behaviour (absent keys decode to
  main).
- Old reader (an earlier app build), new document: it decodes without error
  but ignores the keys, so a cutaway becomes an ordinary overlapping clip on
  its track: sequential packing will move it and its neighbours, and a
  later-starting main clip can draw over it. Saving from the old build drops
  the keys. This is degraded, lossy behaviour, documented in the release
  notes; no migration exists that can express a cutaway to an old reader.
- The comments mentioning a Python renderer describe the port's history. A
  search of this checkout and the neighbouring repositories located no
  Python consumer source, so external-consumer behaviour is unverified and
  not a requirement.

## D2. Packing, snapshot, and pausing bumpers

`BuilderStore.resolveLayout` filters cutaways out of `pending` (as it does
for bumpers) and never treats them as obstacles. Packing never touches a
cutaway's `startTime`.

Pausing bumpers reuse `BumperPlanner.insertGap` / `removeGap` unchanged:
because cutaways live in `videoTrack`, `insertGap` already shifts a cutaway
that starts after the gap and splits one that crosses it (tail keeps source
continuity); `removeGap` reverses that and leaves two adjacent cutaway pieces,
exactly as it does for main clips. Every bumper mutation that goes through
those functions (add, move, resize, mode change, delete, duplicate,
load-time normalisation) therefore already handles cutaways; the plan adds no
second shift anywhere. Absolute-time pinning is a statement about packing
only; gap edits are the documented exception.

`canPlace(track:at:)` applies to cutaways unchanged; `coverAllAreas` skips it
in `addCutaway`, `placeClip` and the drop handler. A placed cutaway can still
lose its area later when the Screen row changes, exactly like a main clip
(the renderer discards portions without an area); the block shows the
existing orphan warning in that case.

`TimelineLayoutSnapshot.VideoTrack` gains `cutaways`, `cutawayRows`,
`cutawayRowCount`. Cutaways run through the same `packRows` helper on their
own input; an empty cutaway set yields zero rows (the helper's minimum of one
row applies to main rows only). Lane height = main rows × `rowHeight` +
cutaway rows × `stripHeight` (`rowHeight × 0.55`); the header height, block
vertical offsets, and cross-track drag geometry read the same numbers from
the snapshot.

## D3. Renderer

- `resolveClips` carries `role`, `coverAllAreas`, and the resolved `muted`.
- `applyCropBlocks`: a cutaway gets its track's area reference like a main
  clip. A cover-all cutaway is exempt from the area-count guard (it is kept on
  any track), gets `screenCrop = nil`, and is marked `fillCanvas` so the
  placement is scaled to cover the full frame (crop to fill, centred) instead
  of a slot band; `freeCrops` are never present (D1).
- **One ordering.** `renderSegment` computes the placement order once and
  passes both the ordered placements and their masks to
  `compositeLayeredSegment`, which no longer re-sorts. Order key:
  `(layer, originalStart, originKey)` where `layer` is `track × 2` for main
  clips, `track × 2 + 1` for cutaways, `maxTracks × 2 + 1` for cover-all
  cutaways. `originalStart` is the start before **crop** splitting, captured
  in `resolveClips`. `originKey` is a persisted identity on `TimelineClip`
  (JSON `"origin"`, always encoded, part of equality). `TimelineClip()`
  generates a fresh key itself, so every fresh constructor (Builder scene
  insertion, bumper creation, Wizard main and area clips, the legacy flat
  importer, curated picks and outro) gets one without changes; the decoder
  generates one only when the key is absent. Copy policy: gap-split tails
  (`BumperPlanner.insertGap` and the pausing-bumper split in
  `resolveLayout`) keep the head's key, and the tail's later start ordering
  it on top is intended; `duplicateClip` assigns a new key; the split-Zoom
  copies (`BuilderStore.splitZoomFeeds` and the Wizard's split-Zoom mapping)
  give the right feed a new key because it is an independent feed; the
  Wizard's prepared-render reconstruction copies the source clip's key.
  `TimelineClip.uid` is never encoded so it cannot serve. The order is made
  total and save-stable by a final tie-breaker: the clip's index in
  `videoTrack` (array order survives save and load), carried on
  `ResolvedClip` as `documentIndex`. The fast preview uses the same key.
- Overlap policy: a main clip on a higher track still draws above a cutaway
  on a lower track. With disjoint area masks that is invisible; with
  overlapping areas, legacy unmasked clips or free-crop rectangles it can
  hide the cutaway. Documented as intended: a cutaway only ever wins inside
  its own area.
- `buildLayeredSegments`: cutaways are ordinary active clips; bumper
  selection is unchanged and still wins outright.
- Audio: a `.muted` cutaway never reaches the mix. A `.mixed` cutaway mixes
  like any unmuted clip (no per-clip gain today; the bumper-only volume gain
  is extended to cutaways in this phase so the inspector's volume slider means
  something). Track mute still silences it.
- **Dissolves are new filter-graph work (phase 3).** The document stores
  them: `TimelineClip.fadeIn` / `fadeOut` seconds (keys `"fade_in"` /
  `"fade_out"`, cutaways only, default 0 = hard cut). `resolveClips` copies
  them onto `ResolvedClip` together with `originalStart` and the clip's
  original end, and `renderSegment` derives per-placement `fadeIn`/`fadeOut`
  with the offset of the segment start into the cutaway. The per-clip chain
  today ends in scale/pad/SAR/fps with no alpha, and alpha is introduced only
  by `[v][mask]alphamerge`, so the fade must come **after** the mask step:
  geometry → mask (`alphamerge`, or `format=yuva420p` when unmasked) →
  `fade=t=in:alpha=1` / `fade=t=out:alpha=1` → overlay. `fade`'s `st` can never be
  negative and the ramp always starts from transparent, so a dissolve that
  began in an earlier segment is CONTINUED rather than restarted: the clip
  is padded by the part of the fade that already happened
  (`tpad=start_duration=<lead>:start_mode=clone`), the whole fade runs over
  that padded timeline (`fade=…:st=0:d=<full duration>`), and the padding is
  trimmed away again (`trim=start=<lead>,setpts=PTS-STARTPTS`), so the
  segment opens part way up the envelope. A window that finished earlier is
  omitted. When a
  pausing bumper splits a cutaway (`BumperPlanner.insertGap`, the
  `resolveLayout` split) the head keeps `fadeIn` and loses `fadeOut`, and the
  tail keeps `fadeOut` and loses `fadeIn` — one dissolve, not two. A fade whose window
  falls entirely outside the segment is omitted.
- Segment joins: the existing transition path picks `segment.clips.first`
  and applies `incoming.transIn` at every join. It changes to pick the
  **main-clip** placement with the lowest layer as the incoming and outgoing
  clip (never a cutaway), applies `transIn` only when that clip's
  `originalStart` equals the join time, and `transOut` only when its original
  end equals it. Bumper joins keep their existing handling unchanged (the
  bumper is the segment's only clip).

## D4. Preview

Honest capability statement, shown as a caption under the fast preview when
the document has cutaways: "Fast preview shows one picture at a time, not
B-roll inside its area. It keeps the dialogue under B-roll. Check areas in
Exact preview or the render."

Changes to `previewPlan`: ranking uses the D3 key (bumper first, then
cover-all cutaway over any non-bumper, then cutaway over main within a
track, then the existing track and start order). A winning `.muted` cutaway
would otherwise silence the dialogue underneath, which is the opposite of the
feature, so the fast preview keeps the **underlying main clip's audio** while
a muted cutaway is on top: the preview segment carries the top clip's picture
source and a separate, independent audio source (the highest-ranked unmuted
main clip on the same track, when any) with its own url, source offset,
speed, gain and source-length clamp, never derived from the picture's range.
`makeComposition` gets two clip-audio tracks beside the music track:
track A carries main-clip dialogue (the picture clip's own audio when it is
a main clip, or the independent underlying source under a muted cutaway) and
track B carries a `.mixed` cutaway's own audio, so concurrent contributions
never share a track (HEAD inserts one range at a time into a single clip
audio track). Bumper spans suppress both, as they suppress clip audio today;
music is untouched. Segment coalescing compares the audio source identity
(url, contiguous offset, gain, speed) as well as the picture, so a change of
dialogue under one continuous cutaway is never merged away. This is the one
preview change that is required rather than nice to have.

Exact preview goes through the renderer and inherits D3.

## D5. Builder operations

- `addCutaway(source:, at:, track:, duration:, coverAll:)` where source is a
  scene or a Library asset: creates a clip with `role = .cutaway`, start =
  playhead, duration = the gap to the next main-clip cut on the target track
  clamped to 1–5 s (3 s when there is no cut ahead), on the given track;
  `canPlace` unless `coverAll`. Registers undo "Add B-roll". `sourceStart`
  comes from the picker window (D6).
- `placeClip` keeps the role; moving a cutaway to another track moves its
  area with it; `coverAll` skips the area check. `trimClip` and
  `setClipSourceRange` work unchanged.
- `setClipRole(_ uid:, role:)` per D1 (lossy, repacks the track).
- `setCutawayAudio`, `setCutawayCoverAll` (the latter runs
  `enforceCutawayRules` and `isOrphaned` re-evaluates).
- `duplicateClip` keeps the role.
- Library B-roll tags and timeline roles stay separate concepts: converting a
  clip's role never edits a scene's or asset's tag, and every scene can be
  used as a cutaway regardless of tag; the tag only orders the picker.

## D6. Timeline UI and the B-roll picker

**Strip block.** A cutaway draws as a thinner block riding above the track's
main rows: hatched edge, a "B" badge, the mute icon when muted, an "all areas"
badge when cover-all, the orphan warning when its area is gone. Same move and
trim gestures as a clip; moving never reflows neighbours.

**Picker: park, press B, slide, Enter.** The primary way to add B-roll:

1. Playhead at the cut to cover. Press **B** (or Add ▸ B-roll…). The picker
   opens anchored to the timeline.
2. Left: scenes and Library assets, B-roll-tagged first, with the clip
   browser's search and filters. Up/Down cycle sources. **Deferred:** the
   picker ships with search plus B-roll and Favorites toggles only; the
   browser's full filter menu (tag, analyze batch, orientation, length,
   scene grouping) is not reused yet.
3. Right: the source's filmstrip using `VideoTrimSlider` (the component
   under `ClipTrimEditor` and the dispatch sheet; it already supports a
   middle drag that slides a fixed-length span plus independent edge handles).
   `ClipTrimEditor` itself is not reused: it commits straight to
   `setClipSourceRange` and scrubs the Builder playhead, and the picker needs
   draft state that is cancelable. The window starts at the D5 default
   length, clamped to the source length, editable in a duration field. Drag
   the body to slide; drag an edge to change length; the loupe shows the
   edges; Space loops the selection in a small player. Cut markers: the
   underlying track's main-clip boundaries that fall inside the cutaway's
   timeline span are mapped to source time (marker = cut time − playhead,
   scaled by the window's speed, offset by the window's source start) and
   drawn as ticks on the strip, replacing the periodic ticks while the picker
   is open. Arrow keys nudge a frame, Shift-arrow a second. Digits 1–6 pick
   the target track when the layout has several areas; **A** toggles
   cover-all.
4. **Enter** adds at the playhead on the chosen track and closes.
   **Shift-Enter** adds, advances the playhead to the cutaway's end, and keeps
   the picker open for the next one. Escape cancels.

The picker remembers the last source and window position per document.
Source cards show a "B" badge when tagged and a small "used" mark once added.
A cutaway added over a spot with no main clip under it shows a yellow badge.

**Secondary entry points, all landing in `addCutaway`:**

- Right-click a spot on a track ▸ "Cover with B-roll…": same picker, start
  from the click, default length to the next cut at that spot. SwiftUI's
  context menu carries no event, so the lane reads `NSEvent.mouseLocation`
  in its menu content builder (which runs at menu invocation) and converts
  it through its own window; the last hovered x is the fallback when the
  view has no window yet. Only x is used — it is what maps to a time.
- While a scene plays in the browser (double-click), **I** and **O** mark in
  and out, **B** adds that range at the playhead. No sheet.
- Option-drag a scene onto a track: the drop payload becomes
  `scene:<id>:cutaway` (the lane parses the suffix) and adds with the default
  window; the inspector's Trim section refines it.
- A clip's context menu: "Make B-roll" / "Make main clip", with help text
  naming what is dropped and that the track repacks.

**Inspector** for a cutaway: Audio (Muted / Mixed in), volume when mixed,
Cover all areas, Dissolve in/out seconds (0 = cut), and the usual Trim.

**Screen row rename** as above; the "Bumpers" section of the row header keeps
its name. Track header hint when a track has cutaways: "n B-roll".

## D7. Out of scope now, planned next

- Ducking the underlying audio while a cutaway plays.
- Wizard suggestions ("cover this jump cut with B-roll") using the B-roll
  tag and the existing media-suggestions sheet.
- Cutaways on the Screen row (whole-screen only): rejected, bumper semantics
  conflict with keep-playing cutaways, and per-area is the primitive.

## Phases

1. **Model + renderer + preview** (D1, D3, D4) with tests. Documents with
   cutaways render, and the fast preview keeps dialogue under a muted
   cutaway. No UI yet.
2. **Store + snapshot + strip block + picker** (D2, D5, D6 picker, context
   menu, Add ▸ B-roll…, B key). Usable end to end.
3. **Dissolves, inspector, Option-drag, I/O marking, rename** (D3 fades, D6
   rest).

## Tests

- `TimelineModelsTests`: role / cover-all / audio encode, decode, absent
  keys, equality; `enforceCutawayRules` truth table including bumper
  precedence and cover-all resets; a bumper is never a cutaway.
- `BuilderTimelineModelTests`: repack ignores cutaways and never moves them;
  cutaway is not an obstacle; `canPlace` skipped for cover-all; role
  conversion in both directions (drops, repack, undo names); `addCutaway`
  default duration against the next cut; `isOrphaned` for cover-all.
- `BumperBuilderTests`: pausing bumper splits a crossing cutaway with source
  continuity and shifts a later one; `removeGap` restores; move, resize,
  mode change and delete of the bumper leave the cutaway consistent; nothing
  is shifted twice.
- `TimelineLayoutSnapshot` tests: cutaway rows separate from main rows; zero
  cutaway rows when none; lane height.
- `MultitrackRendererPlanningTests`: placement order and **mask-to-placement
  association** for main, cutaway, cover-all and bumper in one segment; order
  preserved across crop splits (`originalStart`, `originKey`,
  `documentIndex`), while a gap-split tail intentionally orders after its
  head; equal layer, start and origin still order deterministically by
  document index; area inheritance;
  cover-all unmasked and fill-canvas; muted cutaway absent from the mix,
  mixed cutaway present with its gain; join transitions not retriggered by a
  cutaway boundary; fade offsets across a split.
- Real-output probes on short renders (ffmpeg present): a muted cutaway over
  a talking clip keeps the dialogue level (ffprobe `astats`) and shows the
  cutaway's frame in its area (frame hash inside the area, main frame hash
  outside); a `.mixed` cutaway raises the level by its gain; a dissolving
  cutaway's mid-fade frame differs from both endpoints and keeps the area
  mask (phase 3).
- Model tests: `originKey` generated when absent, round-trips, copied to
  gap-split tails, new on duplicate; two overlapping cutaways keep their
  order after a crop split.
- Preview tests: ranking key; dialogue retained under a muted cutaway with
  an independent audio source; one cutaway over two consecutive main clips
  yields two segments with the same picture and different audio; mixed
  cutaway adds a second audio track.

## Resolved questions

1. A cutaway may extend past the end of the underlying content; area
   eligibility still applies unless cover-all.
2. Pausing bumpers shift and split cutaways through `BumperPlanner`, like any
   video; packing never moves them.
3. Cutaways use a separate strip band that shares `packRows`; zero rows when
   empty.
