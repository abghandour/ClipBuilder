# Person Profile Research Plan

Date: October 10, 2026. Status: implemented October 10, 2026 (Codex), uncommitted. Verified: Debug build clean; PersonResearch, DatabaseTagFields, TagTextWriter, AISettings, SchemaVersionGate, AppStore, Database suites 119/119. Live web research and the People-screen rows not yet exercised by hand.
Implementation: Codex; build, tests and review: Claude (per the September 23 working rule).

## Problem

A person's name tag can carry a second line (Role, Profession, MMA record,
Team, Nationality: the five fields `TagStyleEditor` suggests), and a
profile should also carry the person's Instagram and X handles (added
October 10, 2026), which reels and captions can quote. Those fields
live in `person_tag_fields` and are filled only when a reel needs them, by
the `tag_text` task, from the model's memory, with no source and no date.
Nothing fills them when a person is first detected, nothing tells the user
how old a value is, and a fighter's record goes stale silently.

## Decision

- **A profile is the seven fields, researched on the web.** No new "profile"
  table: `person_tag_fields` already keys a value per person and field and
  carries an `AIProvenance` with `at` (the date of last update). Add one
  column, `source`, for the page the value came from.
- **New people are researched once their name is confirmed.** The analyzer's
  guessed name is not trustworthy until the review sheet applies it, so the
  trigger is `applyPeopleReview`, for people kept as "New person", not the
  detection itself. People named later by hand (People screen rename) are
  researched the same way when the name changes from unnamed to named.
- **Stale data refreshes on the next detection.** When a people pass
  (Analyze or Re-run) sees an existing person whose category is `.fighter`
  and whose MMA record is missing or older than 30 days, a quick
  record-only search runs for them. Other fields never refresh on their own.
- **Everything is a background job with a review.** Research runs through
  `AppJobs` (status-bar row, Stop, review sheet from the root view). Empty
  fields fill on Apply; a changed value shows old → new. The user can edit,
  refresh or clear every field on the People screen.
- **Web access is the Claude CLI's.** `AIService.call(webAccess: true)`
  already adds `WebSearch,WebFetch` for Claude and logs "runs without live
  web tools" for other providers. Nothing else fetches pages.

## Data

`Data/Database.swift` migration: `ALTER TABLE person_tag_fields ADD COLUMN
source TEXT` guarded by `columnNames(of:)`, like the `mini_batch` column
above it. No `schemaVersion` bump needed by that pattern; follow whatever the
neighbouring column additions do. `person_tag_fields` is not a sync table;
unchanged.

`Data/Database+TagFields.swift`:

- `PersonTagField` gains `var source: String? = nil`.
- `personTagFields` reads it; `savePersonTagField(personKey:field:value:provenance:source:)`
  writes it (`source` defaults to nil so existing callers compile).
- New `func personTagFieldsByPerson() throws -> [String: [PersonTagField]]`
  for the staleness check.

`Services/Wizard/TagTextWriter.swift`: `static let profileFields = ["Role",
"Profession", "MMA record", "Team", "Nationality", "Instagram", "X"]`;
`TagStyleEditor` uses it instead of its literal list. Handle fields are
stored as the bare handle without "@" or URL ("carlosprates"); the writer
normalises an `@handle` or a profile URL (`instagram.com/<h>`, `x.com/<h>`,
`twitter.com/<h>`) to the bare handle through a pure
`TagTextWriter.normalizeHandle(_:field:)`, tested. The tag-text clean rule
(40 characters, not the name) applies to all seven.

## Research service

`Services/PersonResearchService.swift`, `nonisolated enum PersonResearch`
(pure parts) plus `actor PersonResearchService` (the AI call):

```swift
nonisolated struct PersonResearchRequest: Sendable, Hashable {
    var person: PersonRecord
    var fields: [String]            // subset of TagTextWriter.profileFields
    var context: String             // video filenames, descriptor, fight labels
}
nonisolated struct PersonResearchProposal: Sendable, Hashable, Identifiable {
    var personKey: String
    var field: String
    var value: String               // cleaned, <= 40 characters (TagTextWriter.clean)
    var source: String?             // page URL
    var asOf: String?               // the page's own "as of" date when stated
    var confidence: Double          // 0...1
    var id: String { personKey + ":" + field }
}
nonisolated struct PersonResearchOutcome: Sendable, Hashable {
    var proposals: [PersonResearchProposal]
    var category: PersonCategory?   // suggested when the person has none
    var provenance: AIProvenance?
}
```

- `PersonResearch.prompt(for: PersonResearchRequest) -> String`: asks the
  model to search the web for the named person in the MMA / combat-sports
  context the videos imply, and to return only JSON:
  `{"found":true,"category":"fighter","fields":{"MMA record":{"value":"23-7-0","source":"https://…","as_of":"2026-09-20","confidence":0.9},"Instagram":{"value":"carlosprates","source":"https://instagram.com/carlosprates","confidence":0.8}, …},"notes":"…"}`.
  For Instagram and X the prompt asks for the handle of the person's own
  verified or clearly official account, as a bare handle, and to omit fan
  or news accounts.
  Rules in the prompt: never invent a value, omit a field rather than guess,
  prefer the governing body or a stats site for records, keep each value
  tag-length (a few words, no sentences), do not repeat the person's name.
- `PersonResearch.parse(_ object: [String: Any], request:) -> PersonResearchOutcome`:
  drops fields not requested, values that fail `TagTextWriter.clean`,
  confidence under 0.5, and ambiguous results (`found` false). Pure, tested.
- `PersonResearch.needsRecordRefresh(fields: [PersonTagField], person: PersonRecord, now: Date, maxAge: TimeInterval = 30 days) -> Bool`:
  `person.category == .fighter` and the "MMA record" field is absent, or its
  provenance `at` is nil or older than `maxAge`. Pure, tested.
- `PersonResearchService.run(_ request:, ai:, log:) async throws -> PersonResearchOutcome`
  calls `ai.call(prompt:task: .personResearch, timeout: 180, webAccess: true, log:)`,
  parses with `AIResponseParser.jsonObject`, stamps provenance (`at = Date()`).
  One call per person; a batch runs people sequentially and keeps going when
  one fails (log the failure, no proposal).

`Services/AITask.swift`: `case personResearch = "person_research"`, in the
same list as `fightResearch`; prompt builder documented as above.
`Data/AppSettings.swift` `AICatalog`: label "Person research", default
"claude", recommended chain `[("claude", "claude-sonnet-5-5"), ("gemini", …)]`
mirroring `fight_research`. Provenance task key "person_research".

## Jobs

`App/AppJobs.swift`: `AppJobKind.personResearch` ("Person Research"),
`AppJobResult.personResearch(outcomes: [PersonResearchOutcome])`.

`App/AppStore+People.swift`:

```swift
/// Research the profile fields on the web for these people (all
/// fields when `fields` is nil) as one background job with a review.
func researchPeople(_ people: [PersonRecord], fields: [String]? = nil, reason: String)
```

- Builds the context per person from `videoPeople` filenames, descriptor and
  any `fight_research` label on their videos (whatever is cheap to read from
  the store; no new queries beyond `database.personTagFields`).
- Starts `jobs.start(.personResearch, title: "Person Research — N people", …)`
  with the service running off the main actor; the result is the outcomes.
- Skips people with `isUnnamed == true` (nothing to search for) and people
  already in an in-flight research job (`personResearchInFlight: Set<Int64>`).

`applyPeopleReview(names:merges:)`: after the names are written, collect the
people that were "New person" with a non-empty name and call
`researchPeople(those, reason: "new people")`.

`renamePerson` (or whatever the People screen's rename calls): when the
previous `isUnnamed` was true and the new name is non-empty, call
`researchPeople([person], reason: "named")`.

People pass hook, `App/AppStore+Analysis.swift` where `videoNewPeople` /
the roster is known for a video (both the Analyze path ~L256-282 and
`runPeopleDetection` ~L776-800): after the roster is saved, for every roster
person that already existed, read their tag fields and when
`PersonResearch.needsRecordRefresh` is true collect them; one call
`researchPeople(stale, fields: ["MMA record"], reason: "record refresh")`
per pass. Never for people without a category or not fighters.

## Review sheet

`Views/AppJobReviewSheet.swift`: a `case .personResearch(outcomes)` section,
one block per person: avatar (`PersonFaceAvatar` 28), name, and a row per
proposal with a checkbox (on by default), the field name, the current value
struck through when it differs, the proposed value, a "Source" link
(`Link` to the URL, `lineLimit(1)`), and "as of <date>" when given. A
"Category: Fighter" row with its own checkbox when the person has none and a
suggestion came back. Apply writes `savePersonTagField(... provenance,
source)` for every checked row and `setCategory` for checked categories,
then `refreshAllNow()`; the sheet closes. Nothing writes before Apply.

## People screen

`Views/PersonTagFieldsView.swift` shows every profile field (not only the
ones tag styles name): `withStyleFields` adds `TagTextWriter.profileFields`
to the missing set. Instagram and X rows show the value as "@handle" with a `Link` to the
profile (`https://instagram.com/<h>`, `https://x.com/<h>`) beside the
field, `lineLimit(1)`. Per row, under the field: a caption "Updated <date> ·
<source host>" when provenance `at` or `source` exists ("Added by hand"
when provenance is nil and the value is non-empty), and for "MMA record"
on a fighter older than 30 days the caption is orange with "stale". Row
buttons stay (Save, Clear) plus a "Refresh" button per row that calls
`store.researchPeople([person], fields: [field], reason: "refresh")`.
Section header gets one button "Research on the Web" (all seven fields)
with `help` "Searches the web for this person's role, profession, record,
team and nationality and proposes values for review." Disabled while a
research job for this person is in flight. `lineLimit(1)` + `fixedSize` on
all of them.

## Tests

- `PersonResearchTests` (new, `ClipBuilderTests/Services`): `parse` keeps
  only requested fields, drops low confidence and unfound, cleans values
  through `TagTextWriter.clean` (name repeated → dropped, over 40 chars →
  dropped), reads `source` and `as_of`; handle fields come back bare from `@handle`
  and from profile URLs (`normalizeHandle`), and an empty or non-handle
  value is dropped; `needsRecordRefresh` for fighter
  without record, fighter with fresh record, fighter with 31-day-old
  record, non-fighter with old record, nil provenance; `prompt` contains the
  name, the requested fields and the "never invent" rule.
- `DatabaseTagFieldsTests` (new or added to an existing Database test):
  `source` round-trips; existing rows read with `source == nil`.
- `AppStoreTests`: `applyPeopleReview` with one new named person and one
  merged person starts a research job for the new one only (assert through
  `jobs` or a recorded request list; no network); the record-refresh hook
  selects the stale fighter and not the fresh one.
- `AISettingsTests`: `person_research` has a label, default and chain.

## Not changed

- Sync: `person_tag_fields` stays local. Syncing it is a separate plan
  (new Supabase table + migration).
- The `tag_text` task keeps filling blank fields at render time; a researched
  value is simply already there.
- No automatic research without a confirmed name; no research on every
  Analyze for people who already have values.

## Phases

1. Data (`source` column, struct, writer), `profileFields`, `AITask` +
   catalog entry, `PersonResearch` pure parts + service, tests.
2. Job kind + result, `researchPeople`, the three triggers (review apply,
   rename, record refresh), review sheet section, People screen rows and
   buttons, `AppStoreTests`.
