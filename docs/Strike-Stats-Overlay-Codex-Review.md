# Strike Stats Overlay: Codex review

Date: October 11, 2026. Reviewer: Codex (gpt-6-astra), read-only, of docs/Strike-Stats-Overlay-Plan.md as drafted that day.

## Verdict

**Revise before implementation.** The timed PNG overlay architecture is a good fit, and takedown statistics are feasible. The proposed pose measurements, however, do not yet justify the labels “speed at impact,” “head snapped,” or “fastest of the round.”

The main risk is presenting uncertain 2D tracking as physical measurement. Better badges alone cannot resolve that. Add a real-footage feasibility and validation gate before committing to absolute units or automatic rankings.

This was a read-only review of the plan, conventions, implementation paths, and primary references. No files were modified; no builds, tests, app launches, or performance benchmarks were run.

## Blocking issues

1. **The proposed scale and angle heuristic cannot establish physical speed.** Known height does not remove torso foreshortening, perspective, camera motion, or motion toward the camera. The “70% in the image plane” criterion cannot be inferred from the stated limb-length ratio. See [plan:72](/Users/abghandour/repos/ClipBuilder/docs/Strike-Stats-Overlay-Plan.md:72).

2. **Fight-event timestamps are unsuitable as contact timestamps without refinement.** The scorer receives approximately one frame per second, sometimes fewer after retry thinning. A −0.6/+0.4-second window can miss contact or contain several strikes. A maximum near that timestamp can select a different strike, retraction, or tracking error. See [Analyzer.swift:1306](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/Analyzer.swift:1306).

3. **The unconditional ranking rule is false.** Calibration cancels in rankings only when its error is a common positive multiplier. Different camera angles, depths, tracking errors, and torso poses change the multiplier between strikes. Hiding low-quality numbers while retaining their rankings preserves the misleading claim. See [plan:179](/Users/abghandour/repos/ClipBuilder/docs/Strike-Stats-Overlay-Plan.md:179).

4. **Takedown outcomes need an unresolved state and sequence identity.** A three-second timeout does not distinguish a failed attempt from a continuing attempt. Excluding conflicts without disclosing them biases the rate; displaying legacy results as “n of n” invents a denominator.

5. **Persistence and time mapping are underspecified.** Re-scoring deletes and recreates event rows; coverage has only a visual/podcast pipeline integer; text overlays contain timeline times without a source-clip binding. These require explicit designs before metrics become durable or editable.

6. **The proposed first deliverable lacks prerequisites.** Height entry arrives in phase 6, although earlier phases depend on it. Builder and Wizard controls arrive after the proposed overlay deliverable. Validation currently tests plausibility rather than measurement accuracy.

## Measurement validity

**Torso-ratio scale**

The intended conversion should be explicit:

`metres_per_pixel = 0.29 × height_metres / projected_torso_pixels`

The plan’s wording describes the reciprocal, pixels per metre.

Even with correct units, `0.29` needs a source tied to the exact anatomical landmarks used. Shoulder-to-hip distance, midpoint-to-midpoint distance, and an anthropometric “trunk length” are not interchangeable.

Under a simplified orthographic model, foreshortening the torso by angle θ reduces its projected length by `cos θ`. That inflates the inferred scale by `1 / cos θ`; at 60°, the error is 2× before considering the strike trajectory. Averaging the window reduces random variation, not this systematic error.

Required changes:

- Define the landmarks and reject unsuitable calibration poses.
- Calibrate each fighter separately; the striker’s scale is not automatically valid for the defender’s head.
- Handle camera pan, zoom, shake, cuts, and changing depth.
- Treat absent calibration as **unavailable for absolute units**, rather than assuming 1.78 m and displaying a physical number.
- Preserve calibration provenance and invalidate results when height or source media changes.

Cage geometry can help establish camera pose and scale, but a floor-plane homography does not directly calibrate elevated hands and heads. That follows from the planar constraint described in [OpenCV’s homography documentation](https://docs.opencv.org/doc/doxygen/html/d9/dab/tutorial_homography.html).

**Smoothing and differentiation**

A Savitzky–Golay derivative is a reasonable candidate, not a validated choice here. Specify polynomial degree, boundary handling, missing samples, and actual timestamp spacing.

Five samples span four intervals: approximately 133 ms at 30 fps, 67 ms at 60 fps, and 33 ms at 120 fps. The three-frame median broadens the effective support further. Thus the proposed algorithm changes its physical smoothing scale with frame rate.

Additional problems:

- Coordinate-wise median filtering can flatten real peaks.
- Symmetric derivative windows around contact incorporate post-contact motion.
- A 3× neighboring-speed rule can reject a real short peak while retaining a multi-frame identity swap.
- Differentiation amplifies localization noise; selecting the maximum adds another sensitivity to noise.
- Interpolating across missing contact frames can fabricate the quantity being reported.

Choose the filter using realistic localization noise and manually annotated trajectories, with time-based windows and confidence-aware rejection. Research on rapid eye movements demonstrates that conventional SG filtering can underestimate peak velocity; that supports testing the bias, but does **not** validate a particular filter for punches. [Dai et al., 2017](https://pmc.ncbi.nlm.nih.gov/articles/PMC5852949/)

**Which motion is measured**

Wrist speed is a proxy for fist speed; ankle speed is a proxy for some kicks. Wrist-for-elbow and ankle-for-knee are unsuitable contact-point choices. The fastest moving joint also does not reliably classify technique: a recovery leg, guard hand, or tracking jump can win.

Use elbow and knee landmarks for those techniques, explicitly identify the active limb, and initially allow editor confirmation. Call the result “estimated peak projected wrist speed” unless contact timing and the intended physical quantity have been validated. Peak speed somewhere before an event is not necessarily speed at impact.

**Angle heuristic**

Apparent limb-length change does not identify the fraction of velocity in the image plane. Joint flexion, shoulder movement, perspective, and landmark error all affect length. A limb can retain nearly constant projected length while translating in depth.

Remove the numerical 70%/50% interpretation. Use a conservative “view unsuitable” gate, supported by validation, rather than a purported geometric correction.

**Head displacement and rotation**

Nose motion combines translation and head rotation. Switching from nose to ear midpoint creates a landmark discontinuity. Ear-to-ear vector angle measures projected orientation—primarily an image-plane tilt—not general head rotation or yaw.

The proposed measurement also includes camera motion, whole-body retreat, ducking, and voluntary motion after contact. None uniquely measures strike effect.

If retained, define a fixed landmark and reference frame, compensate camera motion, use the defender’s calibration, and label the output “estimated projected head movement.” Drop rotational degrees and “hardest-looking hit” from the first release.

Apple specifically documents difficulties with bent bodies, overlapping people, and subjects near image edges. Fight footage regularly contains those conditions. [Apple’s body-pose guidance](https://developer.apple.com/videos/play/wwdc2020/10653/)

**Validation**

The requirement that a 30 fps result must always be lower than a 120 fps result is invalid. Noise, filtering, frame phase, scale, and viewpoint can produce either ordering. A slowed replay also needs its capture-to-playback time relationship established; container fps alone is insufficient.

Use:

- The same high-rate source, deliberately downsampled at several temporal offsets.
- Independent manual tracks to separate Vision error from derivative error.
- Controlled calibrated footage for physical-unit accuracy.
- Fight footage covering camera motion, occlusion, combinations, cuts, and identity crossings.
- Reported error distributions, rejection rates, and ranking agreement—not just plausible output ranges.

The cited ballpark is useful only as a sanity check. One instrumented Olympic-boxer study found hand velocity averaging 9.14 m/s, but that does not establish a universal 5–15 m/s acceptance interval. [Walilko et al., 2005](https://pubmed.ncbi.nlm.nih.gov/16183766/)

## Presentation honesty

**The rules are a good start, but insufficient.**

- Every absolute pose-derived value should say **estimated**, including “clear” results. Define badges as visibility/tracking assessments unless their relationship to measurement error has been established.
- Use an **unavailable/rejected** state. Badly occluded contact, uncertain identity, camera cuts, and unknown timebase should not merely produce “≈”.
- Export the qualification with the number. Inspector-only calibration information does not reach viewers.
- Restrict rankings to comparable, accepted observations and label the scope: “highest estimated speed among 12 analyzed strikes.” Do not claim the fastest strike of an entire round when coverage is incomplete.
- Mark existing strike counts and combinations as AI-scored too. They come from the same sparse visual inference process as takedowns.
- Distinguish “in analyzed footage” from “in the round.” Recaps omit action and repeat highlights.
- Keep numerators and denominators visible even above four attempts. Four is a formatting threshold, not evidence of statistical reliability.
- Use restrained precision. Whole-unit results can still be overprecise when calibration error is large.
- Keep authoritative numeric metadata and generated copy consistent. Editing the text must not leave a badge endorsing a manually changed number.

**Do not ship energy initially.** The proposed masses are unsupported constants, and `½mv²` is not energy delivered to the opponent. Speed errors are squared. Published effective mass is experimentally inferred and highly variable; Walilko’s study reported 2.9 ± 2.0 kg, illustrating why fixed technique coefficients need evidence. [Study](https://pubmed.ncbi.nlm.nih.gov/16183766/)

A no-force vocabulary test is useful, but cannot catch misleading claims such as “impact energy,” “hardest hit,” or unsupported rotational measurements.

## Code feasibility (with file:line evidence)

| Area | Verified behavior and required work |
|---|---|
| Fight-scoring scope | [Analyzer.swift:1247](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/Analyzer.swift:1247) checks `supportsFightFeatures`; [1252](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/Analyzer.swift:1252) restricts scoring to action-tagged scenes. This does not establish exhaustive round coverage. |
| Existing takedown semantics | [Analyzer.swift:1216](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/Analyzer.swift:1216) already describes completing a takedown and ending in control. The plan overstates the absence of completion semantics. What is missing is an explicit failed-attempt category and consistent outcome protocol. |
| Event identity | [Models.swift:290](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Models.swift:290) has performer, action, timestamp, points, and model provenance. It lacks target, contact time, attempt interval, outcome uncertainty, scoring version, and round interval. Add these concepts explicitly or define tightly constrained inference rules. |
| Fighter tracking | [Models.swift:404](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Models.swift:404) supplies a portrait box at one timestamp, not a continuous identity track. IoU requires a tracking and re-identification subsystem. Keeping the previous identity through ambiguity is dangerous during crossings and clinches. |
| Metric lifetime | [Database+Fights.swift:21](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Fights.swift:21) deletes all events for a video before inserting replacements. Define foreign-key invalidation, event-generation identity, and protection against a pose job committing after concurrent re-scoring. |
| Coverage | [AnalysisPipeline.swift:3](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/AnalysisPipeline.swift:3) contains only `podcastPass` and `visualPass`. [AnalysisCoverage.swift:34](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/AnalysisCoverage.swift:34) examines the latest run’s single pipeline integer. Merely adding constants cannot express independent scoring/pose status, partial completion, failure, or a successful zero-result pass. |
| Overlay rendering | [TextOverlayRenderer.swift:169](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/TextOverlayRenderer.swift:169) dispatches `nameTag`, `hero`, and `tag`. New static designs fit here. [MultitrackRenderer.swift:444](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/MultitrackRenderer.swift:444) confirms full-frame timed PNGs and transition propagation. |
| Serialization | [TimelineModels.swift:1230](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/TimelineModels.swift:1230), [1259](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/TimelineModels.swift:1259), and [1292](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/TimelineModels.swift:1292) implement explicit coding keys, decoding, and encoding. Adding an optional property alone will not persist it. Prefer a typed, versioned payload over `[String: String]`. |
| Slow motion | [MultitrackRenderer.swift:463](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/MultitrackRenderer.swift:463) uses overlay timeline times directly; [1410](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/MultitrackRenderer.swift:1410) separately remaps source captions by clip speed. New stats need source-to-timeline binding, including trims, repeated clips, speed changes, and clip movement. |
| Placement | [NameTagPlanner.swift:42](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/Wizard/NameTagPlanner.swift:42) sizes name-tag layouts inside supplied areas and chooses corners. Reuse collision logic, but it is not a ready-made tracked callout planner. Transform source boxes through crop/layout geometry and account for other overlays. |
| Look and Builder | [WizardView+Look.swift:112](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Views/WizardView+Look.swift:112) gates Overlays through `lookFormPlan.step2Controls`; capability handling is indirect. [BuilderAddMenu.swift:77](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Views/Builder/BuilderAddMenu.swift:77) provides a suitable visible entry point. Settings also need run-option persistence and copied-run behavior. |
| Wizard inputs | [WizardEngine.swift:899](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/WizardEngine.swift:899) accepts scenes, outcomes, and fight research; the existing planner does not receive the claimed strike-event list. Add explicit event/metric loading and prompt context. |

Further missing pieces:

- **Round mapping:** `FightOutcome.round` is the outcome’s round number, not a timeline of round boundaries. Rates need elapsed fight time excluding breaks, replays, and missing coverage.
- **Deduplication:** define whether `strike`, `significant_strike`, `hurt`, and `knockdown` can describe one physical blow. Otherwise metrics and counts can duplicate it.
- **Cancellation and atomicity:** retain the previous valid result until a replacement pass completes; never advertise cancelled partial results as complete.
- **Provenance:** retain source identity, actual timestamps, capture/playback interpretation, calibration snapshot, Vision revision, algorithm version, rejection reasons, and manual corrections.
- **Builder selection:** “nearest event” must mean nearest eligible event in the selected clip’s source interval, with a bounded distance. Takedown cards should not require pose metrics.
- **Snapshot behavior:** decide whether existing overlays remain frozen after re-analysis or offer an explicit refresh.

**Apple-silicon performance**

The API exists and accepts pixel/sample buffers directly. Its documentation does not establish the proposed throughput. [Apple API documentation](https://developer.apple.com/documentation/vision/detecthumanbodyposerequest?changes=l__4)

For 3,600 frames:

| Total processing cost per frame | Arithmetic runtime |
|---|---:|
| 10 ms | 36 seconds |
| 20 ms | 72 seconds |
| 40 ms | 144 seconds |

These are scenarios, not measured estimates. At 120 fps the same windows contain twice as many frames. Takedown confirmation adds five-second windows, while decoding, seeking, tracking, stabilization, and scheduling add work.

Use merged overlapping windows, sequential bounded-buffer decoding, reusable request configuration, and background scheduling. The app already limits Vision work to one permit in [MediaWorkScheduler.swift:7](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/MediaWorkScheduler.swift:7); [CenterStageService.swift:430](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/CenterStageService.swift:430) demonstrates decoding permits and [512](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/CenterStageService.swift:512) Vision permits.

Benchmark the complete pass on representative footage and the actual machine. Include cancellation latency and concurrent preview/render responsiveness. Native-frame processing is plausible for an offline job; “well under a minute” is presently unsupported.

## Takedowns

**Replace the three-second rule with an attempt sequence and outcome.**

Record an entry, continuation, and resolution. Use outcomes such as completed, defended/failed, and unresolved. Preserve start and completion timestamps. A continuing chain that succeeds after five seconds should not become both one failed attempt and one completed attempt.

Three seconds may be an initial observation window that expands. It should not determine the result.

A takedown that establishes the defined control and is immediately reversed can count as completed, followed by a separate reversal. Merely standing back up is an escape, not automatically a reversal. A transient touch of the mat without established control needs its own explicit treatment.

The current ABC judging criteria emphasize effective results from grappling and do not supply the proposed three-second statistical convention. Keep Clip Builder’s counting protocol separate from official judging. [ABC scoring clarification](https://www.abcboxing.com/wp-content/uploads/2025/08/ABC-MMA-Scoring-Criteira-Clarification-7.2025.pdf)

**Rates**

For resolved attempts against a known opponent:

`success = completed / (completed + failed)`

`defense = failed / (completed + failed)`

These are complementary for the **same attacker–defender pair, scope, and inclusion set**. A fighter’s own offensive success rate and defensive rate are not generally complementary.

Show unresolved counts alongside the result, for example: “3 of 5 resolved attempts; 2 unclear.” For legacy scoring, show “3 completions; attempts unavailable.” For no attempts, display “No attempts,” not 0% or 100%.

**Pose confirmation**

The 55% hip-height heuristic is not dependable ground-state evidence. Image coordinates have an arbitrary origin; camera tilt, zoom, crouching, and occlusion alter the result. It also should not flag failed attempts merely because the defender stayed upright.

Keep any such check experimental and advisory. Do not automatically remove those rows from rates. Store `outcome_conflict` separately from measurement quality; `quality = conflict` mixes unrelated concepts.

**Points**

Giving failed attempts one point changes existing pace and “who is winning” outputs, because those derive from stored event points ([Models.swift:287](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Models.swift:287)). Recommend zero points initially, or a separate activity metric. Adding a denominator should not silently change the app’s scoring model.

## Phase order

Recommended order:

1. **Revise definitions and storage contracts.** Resolve event identity, target attribution, uncertainty, independent pass coverage, round scope, invalidation, and timeline binding.
2. **Revised phase 0: takedown statistics.** Include unresolved outcomes, legacy handling, sequence deduplication, visible review controls, and real annotated examples.
3. **Feasibility spike before production metrics.** Measure identity reliability, contact localization, pose availability, physical error, and runtime on representative fight footage. Establish acceptance gates.
4. **Move height/calibration entry forward.** Manual entry and provenance precede absolute-unit output; automated research can follow.
5. **Implement phases 1–2 together.** Iterate the numerical core against real observations. Synthetic trajectories remain useful for mathematical correctness.
6. **Ship phases 3–4 together.** Rendering plus Builder event selection, inspection, correction, and export qualification form a usable first metrics release.
7. **Phase 5 automation last.** Wizard selection should consume validated metrics and coverage rules. Defer energy, rotational degrees, and fatigue interpretations.

Phase 0 can be independent, but it is larger than a prompt change. Phases 1–3 alone are not a complete user-facing overlay deliverable.

## Answers to open questions

1. **Torso ratio or cage geometry?**  
   Torso ratio is insufficient for confident absolute measurements. Begin with conservative, explicitly estimated projected motion under validated conditions. Investigate cage geometry as supplemental calibration; do not treat a floor homography as a complete solution for elevated limbs.

2. **Ship energy?**  
   **No, defer it.** The mass assumptions, uncertain velocity, and “impact” interpretation compound uncertainty without adding a defensible measurement.

3. **Native-frame requests or ±0.3 seconds?**  
   **Benchmark native-frame processing first; do not shrink blindly.** Coarse event timing makes narrower windows risky. Refine contact, merge overlapping windows, then use adaptive windows that retain derivative padding and post-event context.

4. **Three-second rule and immediate reversals?**  
   **Reject three seconds as the outcome rule.** Count a completed takedown when the declared control criterion is met, even if later reversed. Distinguish reversal, escape, and unresolved continuation.

5. **Sync metrics or keep local?**  
   **Keep raw pose tracks local initially; preserve self-contained overlay snapshots in timelines.** Later sync compact approved measurements, calibration provenance, and corrections using stable identities and source fingerprints. Existing fight events and research already participate in sync ([SyncTable.swift:165](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/TeamSync/SyncTable.swift:165)), so remote event replacement must invalidate local metrics too.

## Smaller nits

- The plan repeatedly says “three designs” but proposes four cards/callouts plus a separate `takedown` callout. Align designs, controls, and Wizard values.
- The example **108 km/h with 6 kg corresponds to 2,700 J**, not 90 J. It is also 30 m/s, outside the plan’s own sanity range.
- Impulse divided by contact duration gives **average**, not peak, force. At 240 fps, 5–20 ms spans approximately 1.2–4.8 frame intervals, not uniformly one or two.
- `ground_strike` exists but is absent from the metric action list. Explicitly defer it or define support.
- “More than two missing frames” is both out of scope and assigned low quality elsewhere. Choose one policy; express gap duration in time as well as frames.
- A single quality badge should not cover both valid striker speed and an occluded defender’s head. Store per-metric validity.
- “Speed decay” across a round can reflect different techniques, camera views, or selection bias. Do not imply fatigue without controlling those factors.
- A static PNG placed beside someone will not follow them. Keep its duration short or use a named panel when spatial attribution would become ambiguous.

