# Integrating VerticalCorn bug control into Clip Builder

September 7, 2026. Plan for wiring the `BugReporterKit` package from
`~/repos/VerticalCorn` into Clip Builder so testers can send a bug report with
logs, a screenshot, and crash pickup from inside the app. Supersedes
`docs/Bug-Report-Implementation-Plan.md` (the Mail/Drive design) and executes
Phase 5 of `docs/VerticalCorn-Plan.md` for the Clip Builder client.

## 0. Where things stand

- The kit already targets macOS: `Package.swift` declares `.macOS(.v15)`,
  window capture uses `cacheDisplay` on the app's own window (no Screen
  Recording prompt), crash pickup scans `~/Library/Logs/DiagnosticReports`,
  the Help menu commands (`BugReporterCommands`) and a floating QA button
  (`QAFloatingPanel`) exist. 103 unit tests pass in the kit.
- The server (Supabase project `verticalcorn`) is deployed with ingest,
  status, delete, and cleanup functions, email notification via Resend, and a
  seeded `clipbuilder` app row. The live ingest key sits in the kit's
  gitignored `configuration/keys.env` as `CLIPBUILDER_KEY`.
- Clip Builder has no reference to the kit yet. Its logs live only in memory
  on `AppStore` (`analysisLog`, `wizardLog`, `builderLog`, `igLog`,
  `pipelineLog`), fed through `LogRelay`. Nothing reaches disk; a crash loses
  everything. There is no persistent log, no crash pickup, and no report UI.
- Clip Builder is not sandboxed, has a `TerminationDelegate`
  (`NSApplicationDelegateAdaptor`), a `CommandGroup(before: .help)` holding
  "Training Guide", a `TabView` Settings window, and a global error alert in
  `MainWindowView` with a "Copy Details" button.
- Secrets reach Clip Builder through Info.plist: `Configuration/GoogleDrive.xcconfig`
  sets `INFOPLIST_FILE` to a tracked placeholder plist and `#include?`s a
  gitignored `GoogleDrive-Local.xcconfig` that points at a gitignored local
  plist with real values. The bug reporter reuses this mechanism.

## 1. Decisions

| Topic | Decision | Why |
| --- | --- | --- |
| Transport | Supabase ingest through the kit; no Mail or Drive delivery | Already built, queued offline, notifies by email; the Mail/Drive plan is retired |
| Package reference | Local package at `~/repos/VerticalCorn` during development; switch to a tagged git URL before the first public release that includes it | Fast iteration now; reproducible release builds later |
| Secrets | `VCIngestKey` and `VCEndpoint` keys in the Info.plist selected by the existing xcconfig override; empty in the tracked placeholder, real in the ignored local plist | Same pattern as Drive; nothing new to gitignore; `INFOPLIST_KEY_*` build settings cannot carry arbitrary keys (verified earlier: Xcode drops unknown names) |
| Log directory | `SettingsStore.dataDirectory/logs` | Follows the data folder, so the test-folder override isolates it and the internal-disk guard applies |
| Identity | `.optional` | Testers may add name and email; anonymous by default |
| Attachments | `[.files, .drop]` | Photos picker is iOS-only |
| QA button | A toolbar button, rightmost item of the main window toolbar, not the kit's floating panel. Always on in Debug builds; in Release it appears only when the Settings toggle is on | Decided September 7, 2026: Debug always on; toolbar placement keeps it discoverable and out of screenshots |
| Settings UI | Native rows in a new "Feedback" group of the General tab, not `BugReporterSettingsRows` | That view is shaped for iOS Forms (NavigationLink) |
| Clean-exit marker | `BugReporter.markCleanExit()` from `TerminationDelegate.applicationShouldTerminate` after saves flush | Otherwise every quit reads as a crash |
| Ship | 1.50 | 1.49 shipped September 7 without it |

## 2. Wiring in Clip Builder

### 2.1 Project and secrets

1. Add the package: File → Add Package Dependencies → Add Local → `~/repos/VerticalCorn`, product `BugReporterKit`, target Clip Builder. This edits `project.pbxproj` (`XCLocalSwiftPackageReference`). Verify a clean `xcodebuild` from the command line still resolves it with `DEVELOPER_DIR` set.
2. Add to `Configuration/GoogleDrive-Info.plist` (the tracked placeholder): `VCIngestKey` = "" and `VCEndpoint` = "". Add the real values to `Configuration/GoogleDrive-Local.plist` (already ignored). Consider renaming the pair to `App-Info.plist` / `App-Local.plist` in a follow-up since they now carry more than Drive; not required.
3. Read them in a new `Services/Diagnostics/BugReporting.swift`:
   `Bundle.main.object(forInfoDictionaryKey: "VCIngestKey")`. When the key is
   empty (developer machine without the local plist), skip `configure` and
   log one line; the menu items stay visible but the sheet shows "Bug
   reporting is not configured in this build".

### 2.2 Configure at launch

In `ClipBuilderApp.init` (ContentView.swift), before the store is used:

```swift
BugReporting.configureIfPossible(store: store)
```

`configureIfPossible` builds `BugReporterConfig(appID: "clipbuilder",
ingestKey:, endpoint:, logDirectory: SettingsStore.dataDirectory.appendingPathComponent("logs"),
identity: .optional, attachmentSources: [.files, .drop],
captureScreenshotByDefault: true, pickUpCrashes: true)` and a
`contextProvider` returning: active profile name, active project name,
current sidebar section, app version and build, ffmpeg version string if
already probed, `driveConnected`, `instagramConnected`, data folder path
(home-relative), and the last 3 wizard/pipeline status lines. The provider
must be `@Sendable` and cheap: read from a `Mutex`-guarded snapshot that
`AppStore` updates when those values change, never from the main actor.

Redaction: append rules for anything the redactor's defaults miss in this
app: Instagram Graph tokens (`IGQ`, `EAA` is already covered), Google OAuth
client secret if it ever prints, and the `X-VC-Key` header itself.

### 2.3 Tee the logs

In `AppStore.appendLog` (the funnel every `LogRelay` feeds), add
`BugReporter.log(channel, line)` with channel names `analysis`, `wizard`,
`builder`, `instagram`, `pipeline`. Also log: launch with version and data
folder, profile and project switches, render start and end with durations,
analysis start and end, every `presentError` call with its context and
error description, Drive transfer state changes (job title and status, never
URLs with tokens). Keep the in-memory arrays; they drive the Activity panels.

### 2.4 Menu, sheet, crash prompt

- `.commands`: replace the current `CommandGroup(before: .help)` block with
  the kit's `BugReporterCommands()` plus the existing "Training Guide" button
  in a `CommandGroup(before: .help)`. Check that ⇧⌘B does not collide with
  an existing shortcut (grep for `keyboardShortcut("b"`).
- `MainWindowView`: add `.bugReporterCrashPrompt()` at the root, exactly once.
  This hosts the global report sheet and the crash prompt.
- Call `BugReporter.checkForCrashesAndPrompt()` from the first `onAppear`
  of `MainWindowView`, after the library snapshot begins loading so the
  prompt does not race the data-folder guard alert.
- `TerminationDelegate.applicationShouldTerminate`: call
  `BugReporter.markCleanExit()` right before replying `terminateNow`, after
  the autosave drain.

### 2.5 Prefilled reports from error paths

Extend the global error alert in `MainWindowView` (the one with "Copy
Details") with a "Report…" button that calls
`BugReporter.presentReportSheet(prefill: ReportPrefill(title: context, error: details))`.
Do the same for the three `NSAlert` sites that surface failures: Drive
playback "Could not open media", the render failure alert, and the pipeline
failure notice. Do not sweep every error string in the app.

### 2.6 QA toolbar button

`MainWindowView` installs an `NSTitlebarAccessoryViewController` with
`layoutAttribute = .trailing` hosting the menu (a root `ToolbarItem` sorts
before each screen's own items and cannot be rightmost; verified on 1.49): a `Menu` with the kit's
`QAButtonLogo` (or `ladybug` symbol) as label and items "Report a Bug…"
(`BugReporter.presentReportSheet()`), "Take Screenshot" (captures the front
window into `ScreenshotStore.shared`, shows the count in the label badge),
and "My Reports…". Visibility: `#if DEBUG` always shown and
`BugReporter.isQAModeEnabled` forced true at launch; in Release shown only
when `BugReporter.isQAModeEnabled`. The kit's floating `QAFloatingPanel` is
not used by Clip Builder: call `configure` with the panel suppressed (add a
`showsFloatingButton` flag to `BugReporterConfig` in the kit, default true,
Clip Builder passes false). Screenshots taken from the toolbar must exclude
nothing special since the toolbar is part of the window; that is acceptable.

### 2.7 Settings

General tab, new "Feedback" group:

- Button "Report a Bug…" → `BugReporter.presentReportSheet()`.
- Button "My Reports…" → `MyReportsWindowPresenter.show()`.
- Toggle "Show the QA button in the toolbar" bound to
  `BugReporter.qaModeBinding`; disabled with the caption "Always on in
  development builds" under `#if DEBUG`.
- Button "Reveal Log Folder" → opens `dataDirectory/logs` in Finder.
- Static text showing the install ID's first 8 characters and a "Reset
  identity" button (`BugReporter.resetIdentity()`), so a tester can quote it
  when asking about a report.

### 2.8 Getting Started guide

Add a short "Reporting a problem" section: Help → Report a Bug… (⇧⌘B), what
the report contains, that name and email are optional, and the QA button
toggle in Settings. The release script re-renders the PDF.

## 3. Gaps to close in the kit first

These are in `~/repos/VerticalCorn`, not Clip Builder, and should land as kit
commits before or alongside the integration.

1. **macOS annotation rendering is untested.** `AnnotationRenderer`'s AppKit
   path (`NSBitmapImageRep` plus a y-flip) compiles but has never produced an
   image. Add a kit test that renders one box on a known bitmap and checks
   the box lands at the expected rows, then fix the flip if it is wrong.
   Without this, the first annotated Clip Builder report may have boxes
   mirrored vertically.
2. **Toolbar entry point and panel suppression.** Add
   `BugReporterConfig.showsFloatingButton` (default true) so a host can keep
   QA mode on without the floating panel, and expose
   `BugReporter.captureScreenshotToStore()` (front-window PNG into
   `ScreenshotStore.shared`, returns the count or nil when the store is
   full) for the host's toolbar menu. The macOS floating panel itself stays
   as is for other hosts.
3. **Swift 6 language mode versus Clip Builder's Swift 5 + MainActor
   default.** The kit is documented as clean under both isolation settings
   and its DemoApp builds with MainActor default. Verify on the first
   Clip Builder build; expect zero code changes.
4. **Docs path.** `docs/INTEGRATION.md` writes the package path as
   `~/repos/VerticalCorn`; the directory is lowercase. Fix the doc.
5. **Resource bundle and notarization.** The kit ships a
   `PrivacyInfo.xcprivacy` and a PNG as package resources. Confirm
   `scripts/make_pkg.sh` signs the resulting `BugReporterKit_BugReporterKit.bundle`
   inside the app (Xcode does this for SwiftPM resource bundles) and that
   notarization accepts it. Test with a local `make_pkg.sh` run before the
   release.

## 4. Phases and estimates

| Phase | Work | Estimate |
| --- | --- | --- |
| A. Kit hardening | Annotation test and fix; docs path; `showsFloatingButton` flag; `captureScreenshotToStore()` | 3 h |
| B. Project wiring | Local package, plist keys, `BugReporting.swift`, configure at launch, clean-exit marker | 1.5 h |
| C. Logging | Tee `appendLog`, add lifecycle and error log lines, redaction rules | 1.5 h |
| D. UI | Help menu commands, crash prompt on root, rightmost QA toolbar menu (Debug always on), prefilled "Report…" on four alerts, Settings group | 2.5 h |
| E. Verification | Manual checklist below on a Debug build against a scratch data folder; one real report end to end; one crash pickup; one offline queue drain | 2 h |
| F. Release prep | Switch the package to a tagged git URL, Getting Started section, `make_pkg.sh` dry run, ship as 1.50 | 1.5 h |

Total about 12 h.

## 5. Verification checklist

Run on a Debug build with `-ClipBuilderDataFolder` pointed at a scratch
folder and the local plist present.

1. Launch: `logs/app.log` appears under the scratch data folder with a
   launch marker; `defaults read` shows no secret; no crash prompt.
2. Help → Report a Bug… opens the sheet with a screenshot of the main window
   that does not include the QA panel; "Retake" works; drag a file in; send.
   Supabase Studio shows the report row and the bundle object; the
   notification email arrives with the screenshot inline.
3. Open the bundle: `app.log` contains the session's analysis and wizard
   lines with the tester's home path replaced by `~` and no `Bearer`,
   `ya29.`, `AIza`, or `EAA` strings. `environment.txt` shows the context
   provider fields.
4. Quit normally, relaunch: no crash prompt. Force quit (`kill -9`) during a
   render, relaunch: the prompt offers to send; "Not now" and "Don't ask for
   this crash" behave.
5. Trigger a real crash (a Debug-only menu item behind an environment
   variable, removed before release) and confirm the `.ips` is attached.
6. Debug build: the QA menu is the rightmost toolbar item on every screen
   and the Settings toggle is disabled with the "Always on in development
   builds" caption. Release build: the item is absent until the Settings
   toggle is on, then present, and the state survives relaunch. "Take
   Screenshot" three times shows a count of 3 and the report sheet lists
   three screenshots; the 11th is refused with a message. No floating panel
   ever appears.
7. Disconnect the network, send a report: the sheet says it is saved and
   will send later; reconnect: the outbox drains and My Reports shows it as
   received.
8. Remove the local plist and build: the app launches, the menu items are
   present, the sheet explains reporting is not configured, nothing is
   logged to disk beyond the launch marker.
9. Error paths: force a Drive playback failure and a render failure; the
   alert offers "Report…" and the sheet opens prefilled with the error text.
10. Existing tests still pass (203 unit tests as of 1.49); add tests for the
    context-provider snapshot, the `appendLog` tee, and the plist-missing
    fallback.

## 6. Risks and open points

- **Data folder guard.** `SettingsStore.dataDirectory` may be rejected at
  launch when it points at external storage; the kit is configured before
  that check runs. Configure with the resolved directory only after the
  guard has accepted it, or fall back to Application Support for the log
  directory when rejected.
- **Tester privacy.** Screenshots may include video frames of people.
  Testers see the screenshot in the sheet and can untick it. The release
  notes and the Getting Started section must say what a report contains.
- **Rate limits.** 20 reports per install per day and 5 per minute. Fine for
  testers; the sheet shows the server's sentence when exceeded.
- **Retention.** Bundles are deleted 90 days after a report is closed; rows
  remain.
- **Viewer.** Triage is in Supabase Studio until the Phase 6 viewer exists.
  The email notification carries the screenshot and summary, which is enough
  for the first weeks.
- **Decided September 7, 2026:** QA mode is always on in Debug builds and
  surfaces as the rightmost toolbar button; Release keeps it behind the
  Settings toggle.
