# VerticalCorn: a drop-in bug reporting kit for all of my Swift apps

September 7, 2026. Written for an AI agent to execute. Supersedes the
delivery parts (Mail, Google Drive) of `docs/Bug-Report-Implementation-Plan.md`;
the capture parts of that plan (rolling log, redaction, crash pickup, window
screenshot, environment block) move into the shared package described here.

Naming: the product, repo, Supabase project, and viewer app are
**VerticalCorn**. Code-level names stay generic: package `BugReporterKit`,
façade `BugReporter`, types `BugReport…`.

## 0. What we are building

Three pieces, one repo (`~/repos/VerticalCorn`):

1. **`BugReporterKit`**, a Swift Package. Any of my apps adds it, calls
   `BugReporter.configure(...)` at launch, and gets: persistent logging,
   crash pickup on next launch, a "Report a Bug…" sheet with screenshot, log
   tail, environment, description, and optional attachments, an offline
   queue, and upload to the cloud. No third-party dependencies.
2. **Backend** on Supabase (project `verticalcorn`): Postgres tables for
   reports, a private Storage bucket for bundles, and Edge Functions that are
   the only thing the SDK talks to.
3. **Viewer**: Supabase Studio on day one, then a CLI so a coding agent can
   pull a report as Markdown and go fix it, then a small SwiftUI macOS app
   (`VerticalCorn.app`).

### Initial clients

| | Clip Builder | How Janey Learned Russian |
| --- | --- | --- |
| Path | `~/repos/ClipBuilder` | `~/repos/ejt/native/HowJaneyLearnedRussian` |
| Platform | macOS 26, Developer ID pkg, not sandboxed | iOS 26 (iPhone + iPad), App Store / TestFlight, sandboxed |
| Project | `Clip Builder.xcodeproj`, file-system-synced sources | XcodeGen `project.yml` (edit the yml, regenerate; never hand-edit the pbxproj) |
| Swift | 5 mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | 6.2, strict concurrency complete, `MainActor` default |
| Existing services | Google Drive, Instagram, AI CLIs | CloudKit (SwiftData), Game Center, StoreKit |
| Testers | one remote friend, pkg by download | TestFlight testers |
| Config secrets | `Configuration/*.xcconfig` | add `Configuration/Secrets.xcconfig` referenced from `project.yml`, gitignored |

Because client two ships through the App Store, the kit must satisfy App
Store rules from version 1: a `PrivacyInfo.xcprivacy` in the package
(required-reason API: `UserDefaults`, reason `CA92.1`), MetricKit rather
than file scanning for crashes, and the app's privacy nutrition label
updated ("Diagnostics: crash data"; optional "Contact info: name, email",
"User ID: Game Center player ID", and "User content: photos or videos",
none linked to identity or used for tracking). No IDFA, no
fingerprinting, no persistent identifier beyond a per-install UUID that the
tester can reset.

The SDK targets macOS 15+ / iOS 17+ so it is not tied to the newest OS
either app happens to use.

Non-goals for v1: in-app screen video capture (testers attach recordings
they made with the OS recorder), tester accounts/passwords, push
notifications to testers, Android/web SDKs, a public product. This is a private tool
for my testers.

## 1. Key decisions (made; do not re-litigate without a reason)

| Decision | Choice | Why |
| --- | --- | --- |
| Backend | Supabase (Postgres + Storage + Edge Functions), own project `verticalcorn` | Already used by Rollbook, so the account and CLI habits exist. SQL, RLS, private buckets, free tier, Studio as a free dashboard. Own project so a bad migration cannot touch another app. CloudKit rejected: needs iCloud sign-in on the tester's device for public-DB writes, adds iCloud entitlements to a Developer ID app, and Clip Builder has no container. Firebase rejected: second vendor for no gain. |
| SDK ↔ backend contract | One HTTPS Edge Function (`/ingest`) plus signed upload URLs for bundle and screenshot | Keeps the anon key and table layout out of the SDK; server can validate, rate-limit, and reshape without shipping app updates. |
| Auth for ingest | Per-app **ingest key** compiled into the client + per-install UUID | Anything in a shipped binary is extractable; the key limits spam per app and is rotatable. Real protection is server-side: size caps, rate limit per install, insert-only. |
| Tester identity | **Anonymous by default.** Optional display name and optional email, entered once in the sheet, editable and clearable in the sheet's "Your details" disclosure. Game Center info only via the opt-in toggle below; never read from iCloud or the OS user name. | Client two's testers are strangers; the friend testing Clip Builder will type his name once. Optional contact lets me follow up when the tester wants that. |
| Bundle format | One zip per report (README, environment, app.log, screenshot, crash/, settings, attachments/, manifest.json) | Human-openable, agent-parsable, one object in Storage. |
| Reading reports | Only my authenticated Supabase user via RLS; the SDK can read **only its own install's** statuses through a second Edge Function | Testers see "Fixed in 1.49" without seeing anyone else's data. |
| Dependencies in SDK | None (Foundation, URLSession, AppKit/UIKit, MetricKit, Compression) | Drop-in must never fight the host's package graph. |
| Concurrency | Swift 6 language mode, `Sendable` throughout, public UI API `@MainActor`, capture/upload `nonisolated` | Both hosts build with `MainActor` default isolation and one has strict concurrency complete; the package must be clean under both defaults. |
| New-report notification | In v1. `ingest/complete` sends me an email through Resend (free tier, one API key as a function secret) and, if `SLACK_WEBHOOK_URL` is set, a Slack message. Immediate, one per report, crash reports flagged in the subject. | I want to hear about a crash without opening a viewer. Email needs no app and works from a phone. |
| Retention | Bundles deleted 90 days after a report is closed; rows kept. Confirmed. | Enough time to reproduce; bounded storage. |
| Game Center | Opt-in per report on hosts that provide a `gameCenterProvider`. The kit never links GameKit itself. | Janey uses Game Center; a tester who wants me to find their leaderboard entry can share it, others stay anonymous. |
| Distribution | Git-tagged SPM package from the private GitHub repo (SSH); local path override during development | No registry needed for two clients. |

## 2. Repository layout

```
VerticalCorn/
├── Package.swift                     # products: BugReporterKit, vc (CLI)
├── Sources/
│   ├── BugReporterKit/
│   │   ├── BugReporter.swift         # public façade, configure(), log()
│   │   ├── Config.swift              # BugReporterConfig
│   │   ├── Identity/TesterIdentity.swift     # install UUID, optional name/email/Game Center
│   │   ├── Logging/AppLogFile.swift
│   │   ├── Logging/LogRedactor.swift
│   │   ├── Capture/EnvironmentReport.swift
│   │   ├── Capture/CrashReports.swift        # macOS .ips + iOS MetricKit
│   │   ├── Capture/Snapshot.swift            # NSWindow / UIWindow
│   │   ├── Bundle/ReportBundle.swift         # zip builder + manifest
│   │   ├── Transport/IngestClient.swift      # /ingest, signed PUT, /status
│   │   ├── Transport/OutboxQueue.swift       # offline queue + retry
│   │   ├── Model/Report.swift                # ReportDraft, ReportRecord, Status
│   │   ├── UI/
│   │   │   ├── ReportSheet.swift             # SwiftUI, both platforms
│   │   │   ├── YourDetailsSection.swift      # name/email/anonymous
│   │   │   ├── CrashPrompt.swift
│   │   │   ├── MyReportsView.swift
│   │   │   └── BugReporterCommands.swift     # macOS menu Commands
│   │   └── Resources/PrivacyInfo.xcprivacy
│   └── VCCLI/                                # `vc list|show|export|set-status`
├── Tests/BugReporterKitTests/
├── Server/supabase/
│   ├── migrations/0001_init.sql
│   ├── functions/ingest/index.ts
│   ├── functions/status/index.ts
│   ├── functions/cleanup/index.ts
│   └── functions/_shared/                    # key check, rate limit, notify (Resend/Slack)
├── Apps/VerticalCorn/                        # Phase 6 macOS viewer
├── Examples/DemoApp/                         # macOS + iOS host for manual QA
└── docs/INTEGRATION.md                       # add-to-your-app guide
```

## 3. SDK public API (the whole surface; keep it this small)

```swift
public struct BugReporterConfig: Sendable {
    public var appID: String                 // "clipbuilder", "janey"
    public var ingestKey: String             // per-app, rotatable
    public var endpoint: URL                 // https://<proj>.functions.supabase.co
    public var logDirectory: URL             // host decides
    public var maxLogBytes: Int = 5_000_000
    public var maxAttachmentBytes: Int = 200_000_000
    public var redaction: LogRedactor.Rules = .default
    public var contextProvider: @Sendable () -> [String: String] = { [:] }
    public var identity: IdentityPolicy = .optional   // .optional | .anonymousOnly | .required
    /// Host-supplied, called only when the tester ticks "Include Game Center
    /// info". Return nil when not signed in. The kit does not import GameKit.
    public var gameCenterProvider: (@Sendable @MainActor () async -> GameCenterInfo?)? = nil
    public var attachmentSources: AttachmentSources = .all   // files, photos (iOS), drop (macOS)
    public var captureScreenshotByDefault = true
    public var pickUpCrashes = true
}

public enum IdentityPolicy: Sendable { case anonymousOnly, optional, required }
public struct GameCenterInfo: Codable, Sendable {
    public var displayName: String
    public var teamPlayerID: String       // stable across my apps; never gamePlayerID from another team
    public var alias: String?
}
public struct AttachmentSources: OptionSet, Sendable { files, photos, drop, all }

public enum BugReporter {
    @MainActor public static func configure(_ config: BugReporterConfig)
    public static func log(_ channel: String, _ line: String)      // nonisolated, cheap
    public static func log(_ channel: String, _ lines: [String])
    @MainActor public static func presentReportSheet(prefill: ReportPrefill? = nil)
    @MainActor public static func checkForCrashesAndPrompt()      // once, after first window shows
    public static var installID: UUID { get }
    @MainActor public static func resetIdentity()                 // new install UUID, clears name/email
    @MainActor public static var sheetIsPresented: Binding<Bool>
}

extension View {
    public func bugReportSheet(isPresented: Binding<Bool>, prefill: ReportPrefill? = nil) -> some View
    public func bugReporterCrashPrompt() -> some View
}
public struct BugReporterCommands: Commands { }    // macOS: Help ▸ Report a Bug…, My Reports…
public struct BugReporterSettingsRows: View { }    // iOS: rows for a Settings Form
public struct ReportPrefill: Sendable { public var title: String?; public var error: String?; public var attachments: [URL] }
```

Host integration is a handful of lines: `configure` at launch,
`BugReporterCommands()` (macOS) or `BugReporterSettingsRows()` in the
settings form (iOS), and `checkForCrashesAndPrompt()` after the first
window. Logging is opt-in per call site.

### Identity rules

- `installID`: UUID created on first run, stored in `UserDefaults` under
  the kit's own suite. Sent with every report. "Reset identity" in the
  sheet's details section regenerates it.
- Name and email: optional text fields under "Your details (optional)".
  Stored locally in `UserDefaults`, prefilled next time, sent only with
  reports made after they were entered. A "Send anonymously" toggle blanks
  both for that report without deleting them.
- `IdentityPolicy.anonymousOnly` hides the section; `.required` disables
  Send until a name is present. Clip Builder uses `.optional`; Janey uses
  `.optional`.
- Game Center: when the host passes a `gameCenterProvider`, the details
  section shows an "Include Game Center info" toggle, off by default,
  remembered per install. When on, the kit calls the provider at send time
  and includes display name, alias, and `teamPlayerID` in the report. It is
  blanked by "Send anonymously" like name and email. Janey's provider reads
  `GKLocalPlayer.local` only if `isAuthenticated`.
- Apart from that opt-in, the kit never reads Game Center, iCloud account
  info, the macOS user name, or device name. The environment block records device
  *model* (e.g. `iPhone17,1`), not the user-assigned device name.

## 4. Data model (Postgres)

```sql
create table apps (
  id text primary key,                 -- 'clipbuilder', 'janey'
  name text not null,                  -- 'Clip Builder', 'How Janey Learned Russian'
  platform text not null,              -- 'macos', 'ios'
  ingest_key_hash text not null,       -- sha256; raw key only in the client
  created_at timestamptz default now()
);

create type report_status as enum ('new','triaged','in_progress','fixed','wont_fix','duplicate','closed');
create type report_kind   as enum ('bug','crash','feedback');

create table reports (
  id uuid primary key default gen_random_uuid(),
  app_id text references apps(id) not null,
  install_id uuid not null,            -- per-install SDK UUID
  tester_name text,                    -- null when anonymous
  tester_email text,                   -- null when anonymous
  game_center jsonb,                   -- {displayName, alias, teamPlayerID} when opted in
  kind report_kind not null default 'bug',
  status report_status not null default 'new',
  title text not null,
  description text,
  steps text,
  app_version text, app_build text,
  os text, os_version text, device_model text,
  context jsonb default '{}',          -- contextProvider output
  environment text,                    -- environment.txt verbatim
  log_tail text,                       -- last 200 redacted lines
  crash_summary text,                  -- exception type / top frame, if any
  bundle_path text, bundle_bytes bigint,
  screenshot_path text,
  fixed_in text,                       -- shown back to the tester
  developer_notes text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index on reports (app_id, status, created_at desc);
create index on reports (install_id, created_at desc);

create table report_events (
  id bigserial primary key,
  report_id uuid references reports(id) on delete cascade,
  at timestamptz default now(),
  actor text,                          -- 'developer' | 'tester' | 'system'
  type text,                           -- 'status','note','attachment'
  payload jsonb
);

create table ingest_rate (             -- sliding-window rate limit
  install_id uuid, app_id text, at timestamptz default now()
);
```

RLS: `reports`, `report_events`, `ingest_rate` deny everything to `anon`;
my authenticated user has full access; Edge Functions use the service
role. Storage bucket `bundles` is private; objects are
`<app_id>/<report_id>/bundle.zip` and `<app_id>/<report_id>/screenshot.png`.

## 5. Edge Functions

`POST /ingest`
- Headers `X-VC-App`, `X-VC-Key`, `X-VC-Install`. Body: JSON with the
  `reports` columns except paths, plus `bundle_bytes`, `has_screenshot`.
- Server: verify key hash; rate-limit 20/install/day and 5/install/minute;
  cap `bundle_bytes` at 250 MB; strip `tester_name`/`tester_email` to null
  when `anonymous = true`; insert with status `new`; return `{report_id,
  bundle_put_url, screenshot_put_url}` (signed, 15 min).
- SDK PUTs the objects, then `POST /ingest/complete {report_id}`; server
  verifies sizes, writes paths, emits a `report_events` row, then calls
  `notify(report)`.

`notify` (shared module, invoked from `ingest/complete`)
- Email via Resend (`RESEND_API_KEY`, `NOTIFY_TO`, `NOTIFY_FROM` as function
  secrets). Subject: `[VerticalCorn] <App> <kind>: <title>` with `CRASH`
  prefixed for crashes. Body: app and version, tester (name or
  "Anonymous", Game Center name if included), device and OS, first 300
  chars of description, crash summary, last 20 log lines, a link to the
  Studio row, and the ready-to-paste `vc show <id>` command. Screenshot
  attached when under 2 MB.
- Slack via incoming webhook when `SLACK_WEBHOOK_URL` is set; same fields,
  compact.
- Failures to notify are logged in `report_events` (`type = 'notify_failed'`)
  and never fail the ingest; the cleanup job retries them once.

`GET /status` (headers as above)
- Returns `[{id, title, status, fixed_in, updated_at}]` for that install only.

`cleanup` (scheduled daily)
- Delete `new` reports never completed after 24 h; delete bundles and
  screenshots for reports closed > 90 days (rows stay, `bundle_path` set
  to null); prune `ingest_rate` older than 2 days; retry failed
  notifications once.

`DELETE /reports/mine` (headers as above)
- Deletes all reports and bundles for the install. Backs the "Delete my
  reports" button in the sheet's details section. Cheap to add now and it
  makes the App Store privacy story straightforward.

## 6. SDK internals

- **TesterIdentity**: install UUID, optional name/email, anonymous toggle,
  reset. `UserDefaults(suiteName: "<bundle id>.verticalcorn")`.
- **AppLogFile**: rolling `app.log` + `app.log.1`, ISO8601 `[channel]`
  lines, launch/quit markers so an unclean exit is detectable without a
  crash file. Mutex-protected, never throws to the caller.
- **LogRedactor**: rule table (Bearer, `access_token`, `sk-`, `AIza`,
  `ya29.`, `EAA`, long secrets near key/token/secret, `/Users/<name>` →
  `~`, emails other than the tester's own). Hosts can append rules.
- **CrashReports**: macOS scans `~/Library/Logs/DiagnosticReports` for
  `<process>-*.ips` newer than a watermark; iOS subscribes to
  `MXMetricManager`, persists `MXCrashDiagnostic` JSON when delivered
  (next launch), and treats it like an `.ips`. Both use the log-marker
  heuristic for force quits.
- **Snapshot**: macOS `CGWindowListCreateImage` on the app's own window
  number (no Screen Recording prompt), fallback `cacheDisplay`; iOS
  `UIGraphicsImageRenderer` + `drawHierarchy` on the key window. Taken
  before the sheet is presented; "Retake" hides the sheet for one run loop.
- **EnvironmentReport**: app/build/bundle path, OS, device model, memory,
  free disk, locale, display info, session uptime, plus `contextProvider`.
  No external tool probing inside the SDK.
- **ReportBundle**: zip built in a temp dir with a minimal dependency-free
  zip writer (store or deflate via `Compression`); writes `manifest.json`.
- **OutboxQueue**: metadata + bundle land in `logDirectory/outbox/<id>/`
  first, then upload. On failure the sheet says "Saved, will send when
  online"; retry on launch and on `NWPathMonitor` reconnect with backoff.
  Manual fallback: share sheet / Reveal in Finder for the zip.
- **UI**: `ReportSheet` in SwiftUI, one implementation with small `#if os`
  branches. Attachments: macOS drag-and-drop and Open panel; iOS Files
  picker and `PhotosPicker` filtered to videos and screenshots so testers
  can attach an OS screen recording. Videos over 200 MB are refused with a
  hint to trim in Photos; HEVC/MOV are passed through untouched. Sections: What happened, Steps, Attachments (toggles
  with sizes), Your details (optional; name, email, Include Game Center info
  when the host provides it, anonymous toggle, reset identity, delete my
  reports), Send / Save for later / Cancel.
  `MyReportsView` lists this install's reports and statuses. `CrashPrompt`
  offers Send / Not now / Don't ask for this crash.
- **PrivacyInfo.xcprivacy**: declares `UserDefaults` (CA92.1) and
  `NSPrivacyCollectedDataTypes` for crash data and optional name/email.

## 7. Phases

Each phase ends with `swift build`, `swift test`, and both hosts building
against the package.

### Phase 1: repo, package skeleton, identity, logging, redaction (≈ 2.5 h)
- Create `~/repos/VerticalCorn`, `Package.swift` (swift-tools 6.0,
  platforms `.macOS(.v15), .iOS(.v17)`), targets, test target,
  `PrivacyInfo.xcprivacy` resource.
- `TesterIdentity`, `AppLogFile`, `LogRedactor`, `BugReporter.log` with a
  coalescer. Unit tests: rotation, tail, redaction table, identity reset
  and anonymous blanking.
- `docs/INTEGRATION.md` first draft.

### Phase 2: backend (≈ 3 h)
- `supabase init` under `Server/`, new project `verticalcorn`.
- Migration `0001_init.sql`: tables, enums, indexes, RLS, bucket.
- `ingest`, `ingest/complete`, `status`, `reports/mine` (delete),
  `cleanup`, and the shared `notify` module, with key check and rate
  limit; `deno test` for pure parts (rate limit window, email body
  rendering, anonymous stripping).
- Resend account + verified sender, `RESEND_API_KEY`, `NOTIFY_TO`,
  `NOTIFY_FROM`, optional `SLACK_WEBHOOK_URL` set with `supabase secrets set`.
- Seed `apps` rows `clipbuilder` (macos) and `janey` (ios); keys via
  `openssl rand -hex 24`, hashes in DB, raw keys in each app's
  gitignored `Secrets.xcconfig`.
- Verify end to end with `curl`: ingest, PUT, complete, row in Studio,
  object in bucket, status scoped by install, delete-mine removes both,
  and the notification email arrives with the right subject and link.

### Phase 3: capture and bundle (≈ 4 h)
- `EnvironmentReport`, `CrashReports` (both platforms), `Snapshot` (both),
  `ReportBundle` with manifest. Unit tests with fixture `.ips` and
  MetricKit JSON, zip round trip.
- Verify on this Mac: own-window capture without a permission prompt; a
  forced crash in `Examples/DemoApp` yields an `.ips` picked up next
  launch. On the iOS simulator use `MXMetricManager.shared.simulateCrash`
  equivalents (Xcode ▸ Debug ▸ Simulate MetricKit Payloads).

### Phase 4: transport, queue, UI (≈ 5 h)
- `IngestClient`, `OutboxQueue`, `ReportSheet` with `YourDetailsSection`,
  `CrashPrompt`, `MyReportsView`, `BugReporterCommands`,
  `BugReporterSettingsRows`.
- `Examples/DemoApp` for macOS and iOS simulator exercising every path,
  including offline, anonymous vs named sends, a Photos video attachment,
  and a stub `gameCenterProvider`.
- Tag `v0.1.0`.

### Phase 5: integrate both clients (≈ 3.5 h)
- **Clip Builder**: add the package; `configure` in the `App` init with
  `logDirectory: SettingsStore.dataDirectory/logs`, `identity: .optional`,
  and a `contextProvider` (profile, project, section, ffmpeg version,
  Drive/Instagram connected flags); tee `AppStore.appendLog` into
  `BugReporter.log`; add `BugReporterCommands()` to `.commands`; call
  `checkForCrashesAndPrompt()` after the main window appears; add
  "Report…" to the Analyze and Drive playback alerts via `ReportPrefill`.
  Ship as 1.49; note it in the Getting Started guide.
- **How Janey Learned Russian**: add the package dependency in
  `project.yml` (`packages:` + target `dependencies:`), regenerate with
  `xcodegen`; add `Configuration/Secrets.xcconfig` for the ingest key and
  reference it from the yml; `configure` in `HowJaneyLearnedRussianApp`
  init with `logDirectory` under Application Support, `identity: .optional`,
  `contextProvider` (current language, hub screen, game mode, feature
  flags); `gameCenterProvider` returning `GKLocalPlayer.local` display
  name, alias, and `teamPlayerID` only when authenticated; `attachmentSources: [.files, .photos]`; add `BugReporterSettingsRows()` to `Hub/SettingsView.swift`;
  `bugReporterCrashPrompt()` on `RootView`; call
  `checkForCrashesAndPrompt()` on first `scenePhase == .active`. Update the
  App Store privacy label (Diagnostics: crash data; Contact info: name and
  email, optional; User ID: Game Center player ID, optional; User content:
  photos or videos, optional; none linked to identity, none used for
  tracking). No `NSPhotoLibraryUsageDescription` is needed because
  `PhotosPicker` runs out of process. Ship via `scripts/upload-testflight.sh`
  and mention "Report a Problem in Settings" in the TestFlight notes.

### Phase 6: viewer and agent access (≈ 4 h, once real reports exist)
- `vc` CLI: `vc list --app janey --status new`, `vc show <id>` (README,
  environment, log tail, crash summary as Markdown), `vc export <id> <dir>`,
  `vc set-status <id> fixed --fixed-in 1.49 --note "…"`. Uses my Supabase
  session stored in Keychain. This is what a Claude Code session uses to
  pick up a bug.
- `Apps/VerticalCorn`: SwiftUI macOS viewer: sidebar by app and status,
  list, detail with screenshot, searchable log tail, crash summary, status
  picker, notes, "Open bundle", "Copy as Markdown". PostgREST over
  URLSession with my JWT; no supabase-swift.

## 8. Security and privacy rules

- The ingest key is a spam limiter, not a secret; real limits are
  server-side (rate limit, size caps, insert-only, private bucket).
- Nothing is uploaded that the tester has not seen listed in the sheet; no
  silent uploads, no telemetry, no launch-time sends except draining the
  tester's own outbox.
- Identity is opt-in and reversible: anonymous by default, name/email only
  when typed, Game Center info only when toggled on, "Send anonymously" per report, reset identity, delete my
  reports. No OS, iCloud, or Game Center identity is ever read.
- Everything textual is redacted client-side before it leaves the device;
  bundles are private in Storage and readable only by my authenticated
  user; cleanup deletes them 90 days after close.
- Notification emails go only to `NOTIFY_TO`; they contain the redacted
  excerpt, never the bundle itself.
- Databases, Keychain contents, and SwiftData stores are never captured.
  Screenshots are of the app's own window only.
- Keys per app, rotatable by updating `ingest_key_hash` and shipping a
  build.

## 9. Acceptance checklist

- [ ] Package builds in Swift 6 mode with strict concurrency on macOS and
      iOS, under both default-isolation settings; `PrivacyInfo.xcprivacy`
      ships in the package resources.
- [ ] Each client integrates with ≤ 20 lines of host code beyond the log
      tee; Janey's `project.yml` regenerates cleanly.
- [ ] Anonymous report: row has null name/email even if the tester had
      previously saved them and toggled "Send anonymously".
- [ ] Named report: name/email present; reset identity yields a new
      install UUID and blank fields; delete-mine removes rows and objects.
- [ ] Report from each client appears in Studio within seconds with bundle
      and screenshot; `vc show <id>` prints it.
- [ ] Crash on macOS (`.ips`) and on iOS (MetricKit, simulated payload)
      both produce a `kind = crash` report after the tester accepts.
- [ ] Offline send lands in the outbox and drains on reconnect.
- [ ] Redaction: an unzipped bundle contains no `Bearer`, `ya29`,
      configured API keys, or the home username.
- [ ] Rate limit: the 21st report from one install in a day is refused
      with a clear message in the sheet.
- [ ] Tester sees "Fixed in 1.49" in My Reports after I set the status.
- [ ] A completed report triggers exactly one email (and Slack message when
      configured) within a minute; an anonymous report shows "Anonymous";
      a report with Game Center on shows the display name and
      `teamPlayerID`; an ingest with the Resend key revoked still succeeds
      and logs `notify_failed`.
- [ ] iOS: a screen recording picked from Photos lands in `attachments/`
      inside the bundle; a 250 MB video is refused with the trim hint.
- [ ] Cleanup run on a report closed 91 days ago removes its objects and
      nulls `bundle_path`; the row and events remain.
- [ ] Janey's TestFlight build passes App Store Connect upload with the
      updated privacy label; no required-reason API warnings.

## 10. Decisions confirmed on September 7, 2026

- New-report notifications (email, optional Slack) are in v1.
- iOS testers can attach screen recordings from Photos, 200 MB cap.
- Retention is 90 days after close for bundles; rows are kept.
- Testers may opt in to include their Game Center display name, alias,
  and team player ID; off by default, host-provided, never read otherwise.

No open questions remain; the plan is ready to execute from Phase 1.
