# Favorites consolidation: retire "Curated" scenes

## Why

A scene today carries two shortlist marks, `favorite` and `curated`, and they
mean the same thing to every consumer: the Wizard boosts both by the same
amount and treats both as must-keep, the learned reel models label both as
positive, Drive learned-preferences syncs both, and the Curated screen is the
Scenes screen filtered to one of them. The only things `curated` adds are
provenance (which AI proposed the promotion) and the AI Curator workflow.
Two marks with one meaning confuse testers; one mark keeps the value.

Decision (2026-09-13): **favorite is the one shortlist mark.** Every user-facing
"Curated" element goes away. The AI Curator survives as "AI Favorites" and
proposes favorites with provenance. The per-scene trim/framing workbench
survives as "Edit Scene". The Wizard's "Build manually…" sheet survives (it
never depended on the mark; its identifiers are renamed).

## Data

1. `scenes` table: add `favorite_provider TEXT` and `favorite_model TEXT`.
   Bump `Database.schemaVersion`. One-time migration in the schema upgrade
   path: `UPDATE scenes SET favorite = 1, favorite_provider = curated_provider,
   favorite_model = curated_model WHERE curated = 1 AND favorite = 0`, then
   `UPDATE scenes SET favorite_provider = curated_provider, favorite_model =
   curated_model WHERE curated = 1 AND favorite = 1 AND favorite_provider IS NULL`.
   Leave the old `curated*` columns in place (SQLite drops are costly; nothing
   reads them afterwards). Never read `curated` again outside the migration.
2. `SceneRecord`: remove `curated`, `curatedProvider`, `curatedModel` and
   `curatedProvenance`; add `favoriteProvider`, `favoriteModel` and
   `favoriteProvenance: AIProvenance?` (task `"curate"` stays as the task key
   for config back-compat; its label becomes "AI favorites").
3. `Database.setSceneFavorite(_:favorite:provenance:)` gains the provenance
   parameter (nil = human; clearing the favorite clears provenance) and
   `setScenesFavorite(_:favorite:provenance:)` replaces `setScenesCurated`.
   Remove `setSceneCurated`/`setScenesCurated`. Learned-model targets
   (`row.targets["keep"]`) use `favorite`. The votes line in the ranker uses
   `favorite` only.
4. `SceneIndex.curated` becomes `favorites` (same maintenance rules).

## Wizard and pipeline

5. `WizardOptions.curatedOnly` → `favoritesOnly`. Decoding accepts the old
   `curatedOnly` key (map to `favoritesOnly`) so saved runs, run settings,
   AIRunSettings, resource bundles and scripts keep working; encoding writes
   `favoritesOnly`. Update `WizardOptionsDecoding`, `AIRunSettings`,
   `ResourceBundle` (defaults key list), `AISettingsPreferences` (map
   `favoritesOnly` → `wizard.favoritesOnly`), `WizardPreferences` (case
   `.favorites`, label "Favorite scenes only"), `WizardFieldHelp` copy.
6. `@AppStorage("wizard.curatedOnly")` → `"wizard.favoritesOnly"`; migrate the
   old default once at launch (copy value, remove old key).
7. `WizardEngine`: the scene pool filter and ranking use `favorite` only
   (`rank += 2` once; must-keep = favorite). Prompt lines print `FAVORITE`
   instead of `CURATED`.
8. Analyze pipeline (`AnalyzeWizardSheet`, `AppStore` pipeline): the step
   "AI Curator" becomes "AI Favorites" (same `pipeline.curate` key), marking
   favorites with provenance; the generated Wizard uses `favoritesOnly` when
   the batch produced favorites.
9. `AppStore.curateScenes` (the AI Curator) becomes `proposeFavorites`; the
   review sheet (`AICurateSheet`) becomes `AIFavoritesSheet` and writes
   favorites with provenance. Worked examples for the prompt come from
   existing favorites; candidates are non-favorite, non-excluded scenes.

## UI (remove every "Curated" element)

10. Sidebar: remove `SidebarSection.curated` and its row; the restored-section
    logic maps an old saved `curated` value to `.scenes`.
11. `ProjectScenesView`: remove the "Curated" mode; if the segmented control has
    only one mode left, remove the control.
12. `ScenesView`: `curatedOnly` init parameter → `favoritesOnly` filter toggle in
    the toolbar ("Favorites"), keyboard C removed (F already favorites), ⏎ opens
    "Edit Scene" (the workbench), context-menu and bulk actions "Curate"/"Remove
    from Curated" become "Favorite"/"Unfavorite" only where a favorite action
    doesn't already exist. Toolbar "AI Curate" → "AI Favorites" (help text
    updated). Card badges: no "Curated" badge; AI-proposed favorites show the
    existing favorite mark with a small provenance tooltip ("Favorited by
    Claude Code").
13. `CuratedView.swift`: delete the screen. Move `CurateSceneSheet` and
    `CuratedSceneEditor` into `SceneEditSheet.swift` as `SceneEditSheet` /
    `SceneEditor`; the primary button is "Done" (trim/framing save as today);
    a secondary "Favorite" toggle replaces "Save as Curated".
14. `AppStore.curateScene` / `setScenesCurated` → `favoriteScene(_:favorite:provenance:)`
    / `setScenesFavorite`. Project summary line prints "N favorites" instead of
    "N curated". The AppStatusBar activity ids/labels for the manual build keep
    working under their new names.
15. `CuratedWizardSheet` ("Build manually…"): keep the feature and its entry
    point; rename `CuratedWizardSheet` → `ManualBuildSheet`,
    `renderCuratedDocument` → `renderManualBuildDocument`,
    `renderCuratedExactPreview` → `renderManualBuildExactPreview`,
    `openCuratedInBuilder` → `openManualBuildInBuilder`, `isCuratedRendering` /
    `isCuratedPreviewRendering` → `isManualBuildRendering` /
    `isManualBuildPreviewRendering`, `curatedWizardPool` → `manualBuildPool`,
    the created timeline name "Curated Edit" → "Manual Edit", the outro scratch
    folder prefix, and the status-bar labels ("Rendering manual build").
    Anywhere it reads `scene.curated`, read `scene.favorite`.
16. Comments in `MultitrackRenderer`, `OverlayTemplatesView`, `GapReporter`,
    `ClipTrimEditor`, `SceneStackViews`, `AnalyzeBatchFilterList`: update wording.
17. `docs/ClipBuilder-Getting-Started.html`: no Curated references remain
    (grep confirms zero today; keep it that way and describe Favorites + AI
    Favorites where the Scenes screen is explained).

## Tests

18. `DatabaseTests`: migration test (a legacy row with `curated = 1` and
    provenance becomes a favorite with the same provenance; a row that was both
    keeps its favorite and gains provenance; `setSceneFavorite` provenance
    round-trips and clears on unfavorite). Update `JSONStoresTests`, `Fixtures`,
    `EffectControlsTests` for the removed fields.
19. `WizardOptions` decoding test: legacy JSON with `curatedOnly: true` decodes
    to `favoritesOnly == true`; encoding never emits `curatedOnly`.
20. `WizardEngine` test: a favorite scene ranks above an equal non-favorite by
    exactly the boost and is must-keep; no double boost.
21. `ScenesView` filter test if one exists for `curatedOnly`; otherwise a
    `SceneIndex.favorites` maintenance test.

## Acceptance

- `grep -rni curated ClipBuilder ClipBuilderTests` returns only: the
  `"curate"` AI task key and its chain, the `pipeline.curate` defaults key,
  the migration SQL, and the `WizardOptions` legacy decode key.
- No "Curated" string is visible in the app.
- Full suite passes. Commit only when asked.
