# Scriptable Builder phase 4

Uncommitted implementation on top of phase 3 (`30d311f`). No xcodebuild,
app launch, commit, or push was performed.

## Finds in the B-roll picker

A `BuilderWizardPickerRequest` carries the find's ordered scenes, request,
Library snapshot, document baseline, revision, database/profile/project/timeline
identity, and the insertion position selected when opening the picker.
`Suggested` prepends these scenes, uses the exact request for both reason and
detail, and deduplicates scene IDs against normal Library suggestions. Finds
remain available in timeline gaps. A normal picker opening retains its existing
selection, suggestions, and direct-add behavior.

For a found scene, the picker offers **Preview in Wizard…**. Its chosen source
window, duration, insertion time, track, and cover-all setting become one
`addCutaway` step in a `BuilderScriptSession`. The picker closes before the
existing Builder Wizard sheet opens on that preview. Apply remains manual and
uses `AppStore.applyWizardRun`, the existing transaction, snapshot undo, saved
before-version, and `builder_runs` record. Stale or foreign finds are refused;
there is no direct-document fallback for found IDs, including when searching.

## Examples and grammar

The Wizard loads examples from `ScriptLibrarySnapshot.people` and `.tags`.
Hidden or ambiguous names and ambiguous tags are not used; absent vocabulary
gets explicit `<person>` / `<tag>` placeholders. Four click-to-fill examples sit
under the request field, with further concrete supported requests in the help
area. Loading examples never runs or applies an edit and never overwrites text
the user has entered.

The anchored parser additionally recognizes `remove clip N on track T`,
`remove the selected clip`, and `duplicate this clip`. Ordinals are one-based,
ordered by timeline start with document order breaking ties. They include B-roll
and exclude bumpers, which do not occupy the visible video track. Existing
track aliases, missing-selection refusal, and full-consumption rules apply.

## Planning results

Reviewed cuts, Builder pre-fill plans, and generated results attach a
`BuilderPlanResult` only after their new timeline has been saved and opened.
Builder displays a **Fix with Wizard…** wand action for that specific result.
The proposed-cuts and generated-results sheets also offer the wand action to
create the timeline and request the same Builder Wizard sheet immediately.
Automatic presentation is consumed once; profile/database/project/timeline
checks prevent opening the result's Wizard on another timeline.

`WizardPlan` has a strategy rationale and cut reasons; `LastPlanRecord` has
input prompts and attempt outcomes. Neither carries follow-up editing notes.
The post-plan field therefore starts with four profile-specific example lines;
users choose one example or replace the field before Run. Creative rationale,
prior planning prompts, and cut explanations are not replayed as instructions.
No plan schema, second parser, or alternate Apply path was added.

## Verification

- Swift frontend parsing passed in Swift 6 language mode with default MainActor
  isolation, with and without DEBUG, for all changed Swift source/test files.
- Focused Swift 6 typechecks passed for the parser, Wizard model, find payload,
  and planning-result model against the previously built app module. Temporary
  copies omitted Observation macros and represented new AppStore API signatures
  with bridges; this does not verify whole-app integration.
- Focused typechecks also passed for the three modified test files and the
  picker's extracted merge helper. Temporary validation copies replaced Testing
  macros with ordinary functions; tests were not executed and macro expansion
  was not verified. A pre-existing unused-result warning remains in staleApply.
- `git diff --check` passed.

The installed beta compiler reports Swift 6.4; checks used Swift 6 language mode,
MainActor default isolation, NonisolatedNonsendingByDefault, and macOS 26 target.
SwiftUI typechecking was blocked by the sandbox's inability to launch the macro
plugin. Run the full Xcode build and Swift Testing suites, especially
`BuilderRequestParserTests`, `WizardSheetModelTests`, and `BRollBuilderTests`.
New async tests do not hold a `DataFolderOverride` across suspension.

Manual checks remain: find → picker → preview → Apply/Undo, normal picker
selection and Add and Keep Going, examples with full/empty vocabulary, and each
post-plan entry point's sheet transition and target timeline. The result banner
is attached to the current in-memory planning result; no new persistence schema
was introduced for that presentation state.

## Changed files

- ClipBuilder/App/AppStore.swift (planning/timeline creation only; protected sign-in hunk preserved)
- ClipBuilder/Services/Script/BuilderRequestParser.swift
- ClipBuilder/Views/Builder/BuilderBRollPickerSheet.swift
- ClipBuilder/Views/Builder/BuilderPlanResult.swift (new)
- ClipBuilder/Views/Builder/BuilderView.swift
- ClipBuilder/Views/Builder/BuilderWizardPickerRequest.swift (new)
- ClipBuilder/Views/Builder/BuilderWizardSheet.swift
- ClipBuilder/Views/Builder/WizardSheetModel.swift
- ClipBuilder/Views/ProposedCutsSheet.swift
- ClipBuilder/Views/WizardResultsSheet.swift
- ClipBuilderTests/App/BRollBuilderTests.swift
- ClipBuilderTests/Services/Script/BuilderRequestParserTests.swift
- ClipBuilderTests/Services/Script/WizardSheetModelTests.swift
- docs/Scriptable-Builder-Phase4.md (this report)
- HANDOFF.md (already ignored in .git/info/exclude)

All other pre-existing sign-in files/hunks were left untouched. PMB reads and the completion batch succeeded; lesson-followthrough marks were
blocked by the session's never-approve policy.
