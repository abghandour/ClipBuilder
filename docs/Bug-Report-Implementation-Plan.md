# Bug reporting: in-app "Report a Bug…" with logs, screenshot, crash pickup

September 7, 2026. Written for an AI agent to execute. Repo facts were
verified against the tree on this date; re-check line numbers, they drift.

## 0. Goal and shape

A remote tester (non-developer, on his own Mac) hits a problem and, in one
sitting, sends the developer everything needed to reproduce it without a
back-and-forth. The deliverable is a **bug report bundle**: one zip with a
description, a screenshot of the app window, the persisted app log, the
latest crash report, and an environment block. Delivery is via the Mail
share sheet by default, and via the tester's Google Drive when connected.

Explicitly out of scope: in-app screen video (use Cmd-Shift-5, the sheet
accepts a dropped file), sending email from inside the app, an uncaught
exception handler, any new server or backend.

## 1. Project facts you need

- Repo `/Users/abghandour/repos/ClipBuilder`, project `Clip Builder.xcodeproj`
  (quote the space), one target, scheme `MyApp`. Sources under `ClipBuilder/`
  are a file-system-synchronized group: new `.swift` files on disk are picked
  up without pbxproj edits.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Anything that must run off
  the main actor is marked `nonisolated` (see `Services/LogRelay.swift`,
  `Services/UpdateService.swift` for the house style).
- Build/test commands: `docs/TESTING-PLAN.md` §1 and
  `.claude/skills/run-app/SKILL.md`. `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`
  is required. Tests run the app with `-ClipBuilderDataFolder` pointed at a
  scratch folder; never touch `~/Documents` in tests.
- Version: `MARKETING_VERSION = 1.48`, `CURRENT_PROJECT_VERSION = 50`
  (pbxproj). Read at runtime via `UpdateService.currentVersion`
  (`CFBundleShortVersionString`); add `CFBundleVersion` for the build.
- Data folder: `SettingsStore.dataDirectory` (`Data/AppSettings.swift:481`),
  default `~/Documents/ClipBuilder/data`. Put the log file and report
  drafts under it so the test-folder override isolates them.
- Logging today: in-memory arrays on `AppStore` (`analysisLog`, `wizardLog`,
  `builderLog`, `igLog`, `pipelineLog`, capped at `logLineCap = 4000`,
  `App/AppStore.swift:166`). All writes funnel through
  `AppStore.appendLog(_:_:)` (`AppStore.swift:921`) via `LogRelay`.
  Nothing is written to disk; a crash loses everything.
- Menu commands: `ContentView.swift:38` `.commands {}`. There is already a
  `CommandGroup(before: .help)` with "Training Guide"; the new item goes there.
- Settings window: `Views/SettingsView.swift` `TabView` with Profile, Taste,
  General, AI, Google Drive tabs.
- Google Drive: `Services/GoogleDrive/GoogleDriveClient.swift` has
  `findOrCreateFolder(name:parent:)`, `createFolder`, `metadata(id:)` and a
  resumable `upload(file:folder:checkpoint:progress:)` (line 167). Scopes
  include `drive.file`, which is enough to create a folder and upload into
  it. `GoogleDriveTransfers.uploadFolder(profile:project:)` (line 350)
  shows the "Clip Builder/<profile>/<project>" folder convention.
  Connection is per profile; tokens live in the Keychain
  (`GoogleDriveKeychain`).
- Secrets that must never reach a bundle: Google access/refresh tokens
  (Keychain, but they also appear in `Authorization: Bearer …` if any log
  line prints a request), Instagram Graph token (`KeychainStore`), AI
  provider API keys (`AppSettings.ai`), OAuth client secret if present.
- Existing alert/share patterns: `NSAlert` in `Views/AnalyzeView.swift:86`
  and `Views/GoogleDrive/DrivePlayback.swift:13`. No `NSSharingService` use
  yet.
- Sandbox: no `.entitlements` file in the tree, the app is not sandboxed.
  Reading `~/Library/Logs/DiagnosticReports` works without extra
  entitlements. First read may still trigger a one-time TCC prompt for
  "Files and Folders" on some systems; handle failure as "no crash report".

## 2. Architecture

New files, all under `ClipBuilder/`:

| File | Responsibility |
| --- | --- |
| `Services/Diagnostics/AppLogFile.swift` | `nonisolated final class AppLogFile: Sendable`. Append-only rolling text log on disk. Thread-safe (Mutex). Rotation at 5 MB, keep `app.log` + `app.log.1`. Lines are `ISO8601 [channel] text`. |
| `Services/Diagnostics/LogRedactor.swift` | `nonisolated enum LogRedactor`. Pure functions that scrub secrets and personal paths from strings. Unit-tested. |
| `Services/Diagnostics/CrashReportLocator.swift` | `nonisolated enum CrashReportLocator`. Finds `.ips` files for this process name in `~/Library/Logs/DiagnosticReports` (and `Retired/`), newer than a stored watermark. |
| `Services/Diagnostics/EnvironmentReport.swift` | `nonisolated enum EnvironmentReport`. Builds the environment text block (app, OS, hardware, ffmpeg, data folder, connected services, active profile/project, memory, free disk). |
| `Services/Diagnostics/WindowSnapshot.swift` | `@MainActor enum WindowSnapshot`. PNG of the key window using `CGWindowListCreateImage` with the window's own `windowNumber` (own windows need no Screen Recording permission). Fallback: `NSView.cacheDisplay`. |
| `Services/Diagnostics/BugReportBuilder.swift` | `nonisolated enum BugReportBuilder`. Given a `BugReportDraft` and attachment inputs, writes `Clip Builder Report <date>.zip` into `dataDirectory/bug-reports/`. Zip via `NSFileCoordinator` + `ditto -c -k --sequesterRsrc` through `ProcessRunner`, or `Compression`/`Archive` if simpler. Returns the zip URL and a manifest. |
| `Services/Diagnostics/BugReportDelivery.swift` | `@MainActor enum BugReportDelivery`. Two paths: `composeMail(zip:subject:body:)` using `NSSharingService(named: .composeEmail)` with `recipients`; `uploadToDrive(zip:profile:)` using the Drive client into `Clip Builder/Bug Reports/`, returning the `webViewLink`. Plus `revealInFinder`. |
| `Views/BugReportSheet.swift` | The sheet UI. |
| `Views/CrashNoticeBanner.swift` (or an alert) | Shown once per new crash report at launch: "Clip Builder quit unexpectedly last time. Send the crash report?" |

Changes to existing files:

- `App/AppStore.swift`: own an `AppLogFile`; tee `appendLog` into it with
  the key path's name as channel (`analysis`, `wizard`, `builder`,
  `instagram`, `pipeline`); add `showBugReport: Bool`,
  `pendingCrashReport: URL?`, `bugReportDraft: BugReportDraft`,
  `reportBug(prefill:)`. On launch (where the data-folder rejection is
  read), call `CrashReportLocator.newReports(since:)` and set
  `pendingCrashReport`.
- `ContentView.swift`: in `CommandGroup(before: .help)` add
  `Button("Report a Bug…") { store.showBugReport = true }` with
  `.keyboardShortcut("b", modifiers: [.command, .shift, .option])` (check it
  does not collide with existing shortcuts in the same block).
- `Views/MainWindowView` (wherever sheets/alerts are attached): present
  `BugReportSheet` on `showBugReport`; present the crash notice when
  `pendingCrashReport != nil`.
- `Views/SettingsView.swift` General tab: "Bug reports" group with the
  developer email (default `abghandour@icloud.com`, editable), "Include
  screenshot by default", "Include recent crash reports", and an "Open
  Reports Folder" button. Stored in `AppSettings` as a new
  `BugReportSettings` struct with defaults, Codable with
  `decodeIfPresent` so old settings files still load.
- Wherever the app already catches and surfaces a failure to the user
  (the `NSAlert`s in Analyze and Drive playback, render/pipeline error
  banners): add a "Report…" button that opens the sheet with the error
  text prefilled. Do this for the top three or four user-visible error
  paths only; do not sweep the whole app.

Data model:

```swift
nonisolated struct BugReportDraft: Codable, Sendable, Equatable {
    var title: String = ""
    var description: String = ""
    var stepsToReproduce: String = ""
    var includeScreenshot = true
    var includeLog = true
    var includeCrashReports = true
    var includeSettings = false        // redacted app_settings.json
    var extraFiles: [URL] = []         // dropped screen recordings etc.
    var prefilledError: String? = nil
}

nonisolated struct BugReportSettings: Codable, Sendable, Equatable {
    var recipient = "abghandour@icloud.com"
    var includeScreenshotByDefault = true
    var includeCrashReportsByDefault = true
    var lastSeenCrashReportDate: Date? = nil
}
```

## 3. Phases

Each phase is independently shippable and ends with the build and unit
tests green. Do not start a later phase until the previous one is merged
or at least reviewed.

### Phase 1: persistent log file (highest value, lowest risk)

1. `AppLogFile`:
   - `init(directory: URL, maxBytes: Int = 5_000_000)`; creates the folder.
   - `append(channel: String, lines: [String])` opens the handle once,
     buffers, flushes on each call (cheap; lines are already batched by
     `LogRelay`). Rotation: when size > `maxBytes`, rename `app.log` to
     `app.log.1` (replacing) and reopen.
   - `recent(maxBytes: Int = 1_000_000) -> String` reads the tail of the
     current file plus the previous file when the current one is short.
   - `write(marker:)` for session boundaries: on launch write
     `=== Launch Clip Builder 1.48 (50) macOS 26.x pid N ===`; on
     graceful termination write `=== Quit ===`. A launch marker without a
     preceding quit marker is a strong crash/kill signal and the crash
     notice can use it when no `.ips` exists (SIGKILL, force quit).
   - Never throw into the caller; log-file failures print once to stderr
     and disable themselves.
2. Tee in `AppStore.appendLog`: derive the channel name from the key
   path (a small `switch` on the key path, default `"app"`), call
   `logFile.append`. Keep this off the observed array path so UI cost is
   unchanged; the file write is a few microseconds and stays on the
   main actor for ordering. If profiling shows it matters, move it
   behind a `LogRelay`-style coalescer.
3. `LogRedactor.redact(_ text: String) -> String`. Rules, each with a
   unit test:
   - `Bearer <token>` → `Bearer •••`
   - `access_token=…`, `refresh_token=…`, `"access_token":"…"` → masked
   - `sk-…`, `AIza…`, `ya29.…`, `EAA…` (Meta) prefixes, any 32+ char
     base64/hex run adjacent to `key`, `token`, `secret` → masked
   - `/Users/<name>/` → `~/`
   - Emails other than the configured recipient → `<email>`
4. Unit tests (`ClipBuilderTests/Services/Diagnostics/`):
   - append + read round-trip; rotation happens at the threshold and keeps
     exactly two files; `recent` returns the tail across rotation.
   - redactor table tests.
   - `appendLog` writes to the file (use the data-folder override).

### Phase 2: environment block and crash-report pickup

1. `EnvironmentReport.text() -> String`. Include: app version and build,
   bundle path (tells you if he runs from Downloads), macOS
   `ProcessInfo.operatingSystemVersionString`, chip (`sysctl
   machdep.cpu.brand_string` or `hw.machine`), physical memory, free space
   on the data volume, data folder path (redacted), ffmpeg/ffprobe path and
   `-version` first line (via `ProcessRunner`, 2 s timeout), which AI CLIs
   are on PATH, active profile name, active project name, Drive connected
   (yes/no per profile, no account email unless the tester opts in),
   Instagram connected (yes/no), uptime of this app session, locale, display
   count and scale.
2. `CrashReportLocator`:
   - Directory: `~/Library/Logs/DiagnosticReports` and its `Retired/`
     subfolder. Files: `Clip Builder-*.ips` (process name has the space).
   - `newReports(since: Date?) -> [URL]` sorted newest first, using file
     creation date. Cap at 3.
   - Parse the first line of an `.ips` (JSON header) for `timestamp`,
     `bug_type`, and `app_version` to show in the notice; treat parse
     failures as "unknown".
   - Also detect the log-marker heuristic from Phase 1 and expose
     `lastSessionEndedAbnormally: Bool`.
3. Launch check in `AppStore` (same place the data-folder rejection is
   consumed): compute `pendingCrashReport`; the notice is shown once, then
   `lastSeenCrashReportDate` is advanced whether or not he sends.
4. Unit tests: locator with a fixture folder (create fake `.ips` files with
   a minimal JSON header); watermark filtering; environment text contains
   version and OS and never contains `/Users/<name>`.

### Phase 3: bundle builder and Mail delivery

1. `BugReportBuilder.build(draft:log:environment:screenshot:crashReports:settingsJSON:) async throws -> BugReportResult`
   (`nonisolated`, runs off main). Layout inside the zip:

   ```
   Clip Builder Report 2026-09-07 14-32.zip
   ├── README.txt          title, description, steps, timestamp, app version
   ├── environment.txt
   ├── app.log             redacted tail (≤ 1 MB) + app.log.1 if included
   ├── screenshot.png
   ├── crash/Clip Builder-2026-09-07-1410.ips
   ├── settings.json       only if opted in; redacted
   └── attachments/        dropped files, copied as-is, 200 MB cap total
   ```

   Also writes `manifest.json` inside the zip listing each file, size, and
   whether redaction ran, so you can trust what you receive.
2. `WindowSnapshot.capture(window:) -> URL?`. Use
   `CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])`.
   Verify on this machine that no Screen Recording prompt appears for the
   app's own window; if it does, fall back to
   `window.contentView?.bitmapImageRepForCachingDisplay` + `cacheDisplay`,
   which never prompts but omits the title bar. The sheet must not be in
   the capture: take the snapshot when the sheet opens, before it is
   presented, and show the thumbnail in the sheet with a "Retake" button
   that hides the sheet, waits one run loop, captures, and re-presents.
3. `BugReportDelivery.composeMail`: `NSSharingService(named: .composeEmail)`,
   set `recipients = [settings.recipient]`, `subject = "Clip Builder bug: <title>"`,
   `perform(withItems: [bodyText, zipURL])`. If `canPerform` is false (no
   Mail account configured) fall back to "Reveal in Finder" with a hint to
   attach the zip to any message. Always also offer "Reveal in Finder" and
   "Copy Report Path".
4. `BugReportSheet` (SwiftUI, in the house style of the existing sheets):
   - Title field, description editor (multi-line, placeholder "What
     happened? What did you expect?"), steps editor.
   - Attachment list with toggles: Screenshot (thumbnail + Retake), App log
     (size), Crash reports (count, newest date), Settings (off by default,
     explains it is redacted).
   - Drop zone / "Add File…" for screen recordings. Reject > 200 MB with a
     message suggesting Drive or a link.
   - Footer: "Send with Mail", "Save to Drive" (Phase 4, hidden until
     then), "Save to Folder", Cancel. Progress and errors inline.
   - Prefill from `draft.prefilledError` when opened from an error alert.
   - Keep the draft in `AppStore` so an accidental Cancel does not lose
     typed text; clear it on successful send.
5. Wire the menu item and the crash notice. The notice has "Send Report…"
   (opens the sheet with the crash pre-attached and title "Crash on
   launch/…"), "Not Now", and "Don't Ask for This Crash".
6. Unit tests: builder produces the expected entries (unzip with `ditto -x`
   in the test and assert file names and README content); redaction ran on
   log and settings; attachment cap enforced; a draft with everything off
   still yields README + environment.
7. Manual checks (record results in HANDOFF.md): screenshot has no
   permission prompt; Mail opens with attachment and recipient; the zip
   opens on the receiving side; a forced crash (`fatalError` behind a
   hidden debug flag, or `kill -SEGV`) produces an `.ips` that the notice
   picks up on the next launch.

### Phase 4: Google Drive delivery

1. In `GoogleDriveTransfers` (or a small helper next to it) add
   `bugReportFolder(profile:) -> DriveFile`: `findOrCreateFolder("Clip
   Builder", parent: "root")` then `findOrCreateFolder("Bug Reports",
   parent: root.id)`. Remember the id in the profile's drive settings under
   `"bugReportFolder"` like `uploadFolder`.
2. `BugReportDelivery.uploadToDrive(zip:profile:)`: reuse
   `GoogleDriveClient.upload(file:folder:checkpoint:progress:)` with a
   checkpoint under `dataDirectory/bug-reports/.checkpoints/`. Show it as a
   normal transfer job so it appears in the Activity list and survives the
   sheet being closed. On completion copy `webViewLink` to the pasteboard
   and show it in the sheet with "Copy Link".
3. First-time helper text in the sheet: "Reports go to *Clip Builder/Bug
   Reports* in your Google Drive. Share that folder with
   <recipient> once and every report will appear there." Add a "Share
   Folder…" button that opens the folder's `webViewLink` in the browser.
   Do not call the Drive permissions API to auto-share: it would silently
   grant an outside account access to his Drive folder, and the manual
   one-time share is clearer for the tester.
4. Enable the "Save to Drive" button only when the active profile is
   connected; otherwise show "Connect Google Drive in Settings" as a link
   that opens the Drive tab.
5. Unit tests: folder resolution reuses the remembered id; upload job is
   created with the right folder; button state follows connection state.

### Phase 5: polish and error-path hooks

- Add "Report…" to the existing error alerts (Analyze, Drive playback,
  render failures) passing the error text.
- Add the log file and the reports folder to the "Open Data Folder"
  style helpers if the app has them.
- Log-file hygiene: on launch, delete reports in `bug-reports/` older than
  30 days (drafts only; sent reports are already elsewhere).
- Update `docs/ClipBuilder-Getting-Started.html` with a short "Found a
  problem?" section: Help > Report a Bug…, what gets sent, and how to add
  a Cmd-Shift-5 recording.
- Add a line to the release notes and bump the version per
  `.claude/skills/release/SKILL.md` when shipping.

## 4. Privacy and safety rules (non-negotiable)

- Everything that leaves the machine passes through `LogRedactor`. The
  builder refuses to include a file it cannot redact (binary settings,
  databases). Databases are never included; if a DB is needed later, that
  is a separate explicit "Include database" option with a warning.
- The sheet lists every attachment by name with a size before anything is
  sent. There is no silent upload and no upload on launch.
- Screenshot captures only the app's own window, never the screen.
- The crash notice never sends by itself; it only opens the sheet.
- Drive upload uses the tester's own account and folder; the app never
  changes sharing permissions on his behalf.
- No new network endpoints, no telemetry, no analytics.

## 5. Acceptance checklist

- [ ] After a crash (real `.ips`) the next launch shows the notice; "Send
      Report…" opens the sheet with the crash attached; the zip contains the
      `.ips` and the log tail ending with the last lines before the crash.
- [ ] After a force quit (no `.ips`) the notice still appears using the
      launch-marker heuristic and says "quit unexpectedly" without a crash
      file attached.
- [ ] Help > Report a Bug… on a healthy app: screenshot thumbnail appears
      with no permission prompt; Send with Mail opens Mail with recipient,
      subject, body, and the zip attached.
- [ ] Redaction: run the app with an AI key configured and a Drive account
      connected, produce a report, `grep -r` the unzipped folder for the key
      prefix, `Bearer`, `ya29`, and the home username; all absent.
- [ ] Drive: with Drive connected, Save to Drive creates
      `Clip Builder/Bug Reports/<zip>` and shows a link; with Drive not
      connected the button explains how to connect.
- [ ] A 250 MB dropped file is refused with a clear message; a 50 MB file is
      included.
- [ ] Log file rotates at 5 MB in a test and the app keeps running.
- [ ] All unit tests green with
      `xcodebuild … test`; if the run reports zero tests, rerun with
      `build-for-testing` then `test-without-building` (known flake).
- [ ] Getting Started guide updated.

## 6. Estimates

| Phase | Size |
| --- | --- |
| 1 Log file + redactor | ~2 h |
| 2 Environment + crash pickup | ~2 h |
| 3 Bundle, screenshot, Mail, sheet UI | ~4 h |
| 4 Drive delivery | ~2 h |
| 5 Polish, docs | ~1.5 h |

Phases 1 to 3 are the useful minimum; ship them first and let the tester
use Mail while Drive lands in a following release.

## 7. Open questions for the owner

1. Recipient email default: confirm `abghandour@icloud.com` or another
   address for reports.
2. Should the tester be able to include the SQLite databases on request?
   (Default plan: no.)
3. Keyboard shortcut for Report a Bug…: proposed ⌥⇧⌘B; say if you prefer
   none.
