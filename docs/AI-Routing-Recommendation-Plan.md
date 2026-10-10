# AI Routing Recommendation Plan

Date: October 9, 2026. Status: implemented October 9, 2026 (Codex), uncommitted. Verified: Debug build clean; AISettings, AIService, AppStore, SettingsCodable, SyncMapping, TeamSyncCoordinator, SyncEngine suites 168/168. Settings › AI controls not yet exercised by hand.
Implementation: Codex; build, tests and review: Claude (per the September 23 working rule).
Follows docs/Profile-Editing-Defaults-Sync-Plan.md (implemented the same day).

## Problem

Which AI provider and model handle each task (`AIConfig.tasks`,
`AIConfig.taskModels` in `app_settings.json`) is partly team policy: a brand
wants its reels planned and critiqued the same way on every Mac. But it is
only usable where that provider's CLI is installed and signed in, and the
dispatcher already writes per-Mac choices into the same fields. Syncing the
effective value would make one member's install state everyone's problem.

## Decision

Sync the routing as a **team recommendation** stored on the profile, keep
`app_settings.json` as the **local override**, and resolve the effective
config in one pure function. Precedence per task:

1. local override (`settings.ai.tasks[task]` set), provider and model
   together;
2. team recommendation (`profile.aiRouting.tasks[task]`, with
   `aiRouting.taskModels[task]`);
3. catalog default (`AICatalog.taskDefaults`, recommended chain).

A recommendation naming a provider this Mac lacks is harmless: dispatch
already restricts candidates to installed CLIs and falls through the
recommended chain, so the next usable provider runs.

## Types

```swift
nonisolated struct ProfileAIRouting: Codable, Sendable, Equatable {
    var tasks: [String: String] = [:]        // task → provider key
    var taskModels: [String: String] = [:]   // task → model
}
```

`BrandProfile.aiRouting: ProfileAIRouting?`, coding key `ai_routing`,
`decodeIfPresent`. Nested keys `tasks` and `task_models`. Optional so every
existing profile JSON decodes.

Resolver, `Services/AIRoutingResolver.swift`, `nonisolated enum`:

```swift
enum AIRoutingSource: Equatable { case localOverride, team, catalogDefault }

static func effectiveConfig(local: AIConfig, team: ProfileAIRouting?) -> AIConfig
// Copy of `local` whose tasks/taskModels are the team's entries with every
// task that has a local provider replaced by the local provider AND local
// model (a local override wins as a pair; a team model never rides under a
// local provider). Provider settings, cooldown, on-device fields untouched.

static func source(task: String, local: AIConfig, team: ProfileAIRouting?) -> AIRoutingSource
```

## Wiring

- `AppStore.effectiveAIConfig: AIConfig` returns
  `AIRoutingResolver.effectiveConfig(local: settings.ai, team: activeProfile.aiRouting)`.
- Every place that hands a config to an `AIService` uses it:
  `AIService(config:)` in `AppStore` construction (`AppStore.swift` ~L672),
  `AppStore+AITools.swift` ~L608, and `saveSettings()`'s `updateConfig`.
  Grep for `AIService(config:` and `settings.ai)` to catch the rest, and
  decide per site: dispatch and routing use the effective config; the
  on-device policy (`OnDevicePolicy.isEnabled(config:)`) and provider
  binaries read local fields that the resolver copies unchanged, so either
  is correct there.
- `activeProfile.didSet` in `AppStore.swift`: when
  `oldValue.aiRouting != activeProfile.aiRouting`, push
  `effectiveAIConfig` to `ai.updateConfig`. This covers profile switches
  and sync adoption.
- Display readers switch to `store.effectiveAIConfig`: the routing
  bindings' getters in `SettingsView.swift` and `TaskModelPickers.swift`,
  `routingSummary(task:config:)` callers, `DispatchPlanSheet.seedChoices`
  (which today falls to the catalog when no local value exists; it must fall
  to the team recommendation first), `WizardSheetModel` builder-agent reads
  (~L117, L123, L618).
- Writers stay as they are: they write local overrides into `settings.ai`.
  That includes the dispatch plan sheet's start, the analysis replay in
  `AppStore+Analysis.swift` ~L484, `setTaskModel`, and the builder agent
  sheet. `resetDispatcher` keeps clearing the local fields; with a team
  recommendation present that now means "follow the team".

## Sync

- Add `"ai_routing"` to `TeamProfileDocument.keys`. The merge recurses into
  objects, so two members recommending different tasks in one cycle both
  land.
- No seeding. A profile has no recommendation until a member sets one.
  Nothing changes for anyone until then.
- No `schemaVersion`, SQLite or Supabase change. Older clients preserve
  the unknown key.

## UI

Settings › AI › Task Routing:

- Each task row keeps its `ModelPicker`, now showing the effective value.
  Under it, one caption line, `lineLimit(1)`:
  "Team recommendation" when the source is `.team`;
  "This Mac overrides the team's choice (<provider · model>)" plus a
  "Use team choice" button when the source is `.localOverride` and the
  profile has a recommendation for that task; nothing when there is no
  recommendation. "Use team choice" removes the task from
  `settings.ai.tasks` and `taskModels` and saves settings.
- Section footer: a button "Recommend this routing to the team" and the
  caption "Saves the current routing on the profile. Shared with the team
  when the profile has one. Each Mac can still override a task." The button
  writes the effective tasks and models for every key in `AICatalog.tasks`
  (plus `translate`) into `activeProfile.aiRouting`, clears the same keys
  from the local override (the Mac now follows what it just recommended),
  saves the profile and settings.
- The Dispatch Plan sheet and the Wizard pickers need no new controls; they
  show the effective value and write local overrides as today.

## Tests

- `AISettingsTests` or a new `AIRoutingResolverTests`: precedence for all
  three sources; a local provider override with no local model does not
  inherit the team's model; non-routing fields copied unchanged; `source`
  for each case.
- `SettingsCodableTests`: profile decodes with and without `ai_routing`;
  snake_case keys; unknown nested key tolerated.
- `SyncMappingTests`: `ai_routing` is in the encoded document; `applying`
  sets it; `merging` keeps a remote edit to one task and a local edit to
  another.
- `AppStoreTests`: switching to a profile with a different recommendation
  changes `effectiveAIConfig`; "recommend to team" clears the local
  override for the written keys.

## Out of scope

- Syncing provider settings (binaries, models), cooldowns, on-device
  policy, muted dispatch plans. All per Mac.
- Any server change.
