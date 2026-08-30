# Instagram Tab: Reels Import, Stats & Template-Based Creation

Status: **P1–P4 done** (updated 2026-07-11; P4 shipped token-based, no OAuth flow)

## Goal

An **Instagram** sidebar tab that pulls the user's (or any public account's) reels with
statistics, lets them pick a high-performer as a **template**, and creates a new similar
video from their own scenes — either fully via the **AI Wizard**, or as an AI pre-filled
**Builder timeline** they edit manually.

User decisions (confirmed):
- **Access**: official Graph API when connected (own account, real insights) with a
  public-web/yt-dlp fallback (any public account).
- **Scope**: own account + arbitrary public accounts.
- **Template depth**: full analysis — download the reel, AI-analyze structure
  (hook, cut rhythm, pacing, style) + metadata.
- **Builder path**: AI plans real scenes onto the timeline (no render), user edits from there.

## Architecture

One orchestrating actor (`InstagramService`), providers behind the `InstagramProvider`
protocol. Phase 1 shipped `InstagramWebProvider` (Instagram's public web JSON API for
listing — yt-dlp's profile extractor is broken upstream — with yt-dlp as the
video-download fallback, where its `--cookies-from-browser` support shines).

- DB (additive, Python-sibling compatible): `ig_accounts`, `ig_media` (stats_json blob →
  all-optional `IGStats`), `ig_templates` (media_id UNIQUE, template_json + attribution).
  Downloads write through to the pre-existing `imported_externals` registry.
- Cache: `<cache>/instagram/<user>/thumbs/<id>.jpg`, `videos/<id>.mp4`.
- Settings: `AppSettings.instagram` (cookie source/file, fetchLimit); Graph credentials
  will go to Keychain only (P4).
- Refresh policy: cache-first UI, 6h auto-refresh throttle, manual Refresh always fetches.

## Phases

### P1 — Public fetch + grid ✅ (done)

`Data/InstagramModels.swift`, `Services/Instagram/{InstagramProvider,InstagramWebProvider,
InstagramService}.swift`, `Views/InstagramView.swift`; wiring in Database, AppSettings,
AppStore, ContentView, SettingsView. Account picker, sort by Recent/Views/Likes/Comments,
grid cards with cached thumbnails + stats, detail sheet with player-or-thumbnail,
Settings → Instagram tab.

### P2 — Template analysis + Wizard ✅ (done)

- `FFmpeg.sceneChangeTimestamps(of:threshold:)` — `select='gt(scene,0.3)',showinfo`,
  parses `pts_time:` → objective cut positions as ground truth for the AI.
- `InstagramService.analyzeTemplate` — cached in `ig_templates`; ensureDownloaded →
  probe → cut detection → frame sampling (`Analyzer.frameTimestamps` +
  `ThumbnailService.jpegFrame`) → `ai.call(task:"analysis")` demanding strict
  `ReelTemplate` JSON; probe-derived duration/cut counts override the model's numbers.
- `WizardOptions.templateJSON/templateLabel`; `planPrompt` inserts a
  "REFERENCE TEMPLATE (HIGH PRIORITY)" block below user instructions, above research;
  template duration/cut cadence override the research numbers.
- Handoff: detail-sheet actions (Analyze as Template → Create with Wizard / Re-analyze,
  Stop while running), analyzed badge on grid cards, `AppStore.pendingWizardTemplate` +
  `requestedSection = .wizard`, dismissible chip in WizardView consumed on run/dismiss.

### P3 — Builder pre-fill ✅ (done)

- Planning half of `WizardEngine.runThrowing` extracted into `loadPlanningInputs` +
  `makePlan`, with public `plan(options:profile:database:emit:) -> (WizardPlan, sceneMap)`
  for the Builder path (no assembly, no captions). `runThrowing` uses the same helpers.
- `WizardEngine.timelineDocument(from:sceneMap:)` maps `WizardPlanClip[]` → sequential
  `TimelineClip`s on track 0 (sourceStart/End, duration, wide, cropXFrac; transitions →
  `transIn`; musicName → one `SoundItem` spanning the timeline; per-clip textOverlay →
  `TextOverlayItem` at the top). `wideSplit` hints dropped in v1.
- `AppStore.planIntoBuilder(options:)` shares the wizard log panel/stop button
  (`isWizardRunning`), jumps to the Wizard tab to show the live log, then
  `builder.loadDocument(...)` (registers undo) → `requestedSection = .builder`.
  `useTemplateInBuilder(media:)` runs it with default options + the reel's template
  (text overlays enabled — they land as editable items, not burned in).
- "Pre-fill Builder" button next to "Create with Wizard" in the detail sheet.

### P4 — Graph API + insights ✅ (done, token-based)

Shipped simpler than planned: the user supplies a long-lived Meta token directly
(paste into Settings → Instagram → Own Account), so the OAuth code-exchange flow
(`InstagramAuth`) was dropped entirely.

- `Services/Instagram/KeychainStore.swift` — minimal generic-password wrapper
  (service `com.clipbuilder.instagram`, account `instagram_graph_token`).
- `Services/Instagram/GraphAPIProvider.swift` — graph.facebook.com v23.0:
  `me/accounts?fields=instagram_business_account{…}` discovery, `/{ig-user}/media`
  listing (like_count/comments_count as fallback stats), per-media `insights`
  (`views,reach,likes,comments,shares,saved,ig_reels_avg_watch_time` — watch time
  ms→s), video via `media_url` with automatic re-fetch when the signed URL expired.
  Token error (code 190) → readable "reconnect in Settings" message. No media
  duration in the Graph fields — rows keep duration 0 until probed.
- `InstagramService.provider` picks Graph when the username matches
  `connectedUsername` and a Keychain token exists; `refreshAccount` catches Graph
  failures and retries once via the public web provider.
- `AppStore.connectInstagram(token:)` validates via account discovery, stores the
  token in the Keychain, saves `connected_username`/`connected_ig_user_id`, and adds
  the account; `disconnectInstagram()` reverses it. Settings UI shows connected
  state or a SecureField + Connect.
- Detail sheet already showed Reach/Saves/Shares rows for `source == "graph"`.
- 2026-07-11: connected for @peacegrappler (IG user 17841447891636367) — token
  seeded from `peace-grappler/.env` via `security add-generic-password -A`
  (all-apps ACL, because local builds are ad-hoc signed with a changing identity).

## Verification

- **P2** ✅ verified live 2026-07-11: 4 reels analyzed in-app into `ig_templates`; rows
  decode as `ReelTemplate`. Scene detection parse confirmed against a synthetic
  two-scene video (`pts_time:2`).
- **P3** ✅ verified 2026-07-11 via a headless end-to-end harness (app service sources
  compiled into a CLI, DB copy, live claude-CLI plan): a real 32.8s/8-phase template
  produced an 8-clip 32.0s plan (2% duration deviation), every clip mapped to a real
  analyzed scene, timeline document sequential with in-bounds trims + transitions on
  every boundary, 6 text overlays carried over, JSON round-trip clean. ⌘Z restore and
  Builder render are covered by code paths shipped and verified earlier (loadDocument
  registers undo; renderer untouched by P3).
- **P4**: connect flow, insights rows, token refresh on relaunch, disconnect falls back.

## Risks & containment

- **Instagram breakage** (most likely): isolated in the provider; cache-first grid
  degrades gracefully; errors carry a "configure cookies in Settings" hint.
- **Rate limits**: fetch limit 12 default (4–24), 6h auto-refresh throttle.
- **ToS**: web/cookie fetching is ToS-gray — stated in Settings copy; Graph API is the
  compliant path once connected.
- **Disk growth**: lazy video downloads only; cache under the visible cache dir.

### P5 — Reports tab ✅ (2026-08-30)

A **Posts | Reports** segmented switch at the top of the Instagram screen.
Reports rebuilds the peace-grappler HTML reports natively (SwiftUI + Swift
Charts): Overview (KPIs, follower growth + trend, content published,
engagement analytics, account insights by content type / follower split,
content mix, reach per post), Posts (reels/feed summaries with deltas, daily
trends, sortable performance table, top-10 lists, hashtag stats, algorithm
status), Commenters (top active commenters, per-post breakdown, community
rankings with the 5/7/1/2-pt scoring and 30-minute early bonus, weekly
activity heatmap, ignore list), Audience (age, gender, countries, cities;
followers vs engaged).

- Data: new tables `ig_account_snapshots`, `ig_report_media` (all post types,
  90 days — `ig_media` stays reels-only), `ig_media_insight_snapshots`
  (append-only), `ig_account_insights`, `ig_audience_demographics`,
  `ig_comments`, `ig_commenter_*_import`, `ig_comment_heatmap_import`,
  `ig_ignored_accounts`, `ig_report_sync_state`. Every row carries
  `source` = graph | import; live rows win over imported ones.
- Sync: `InstagramReportSync` runs inside the existing Refresh for the
  Graph-connected account (page token when available): account snapshot,
  paginated media, typed media insights, comments with `replies{}`
  expansion, batched daily account insights (4 calls/day, 30-day floor),
  `follower_count` series, rolling 28-day totals, daily demographics.
  Checkpointed per step so Stop/rate limits resume on the next Refresh.
- History: `PeaceGrapplerImporter` (Settings → Instagram → Report History)
  reads the committed report artifacts in a peace-grappler checkout — every
  daily git version of `engagement-report.html` and
  `peacegrappler-insights.html`, the monthly reports, and the
  `video-analysis-*.json` sidecars. Idempotent. The engagement report's
  "Account Insights" cards are skipped on purpose (that generator sums daily
  and 28-day rows together).
- Builder: `InstagramReportBuilder` (pure, off-main) → `InstagramReport`
  for a `ReportPeriod` (7d / 30d / this month / past months / all time).
- Verified 2026-08-30 with a headless harness against the real checkout:
  8 s import, 127 snapshots (2026-04-09 → 08-21), 354 posts, rankings per
  month, numbers match the HTML (followers 3,296 / +1 / −9 / +112; age,
  gender, country buckets; all-time #1 commenter after ignoring the own
  handle). Live Graph sync and the UI still need an in-app pass.

### P6 — Engagement loop ✅ (2026-08-30)

The Reports data now steers generation instead of only being displayed.

- `Services/Instagram/AccountBenchmarks.swift` — deterministic "what
  performs here" from the connected account's last 90 days of reels
  (falls back to all time under 5 reels): reach/views medians and top
  quartile, saves/shares/comments per 1k reach, avg watch, quality
  (`ReelPerformance`) median/p75, the top reels' duration sweet spot and
  cut cadence (from probed durations + reel templates), top- vs
  bottom-quartile traits, best posting slots/weekdays (local time), hashtag
  reach lift, caption-length note, comment-magnet subjects (capitalized
  names in captions weighted by comments and first-hour comment velocity),
  and a per-reel quality percentile (`reelScores`). Rebuilt by
  `AppStore.reloadIGBenchmarks()` after every Refresh/import.
- Planner: `WizardOptions.accountBenchmarks` → a "THIS ACCOUNT'S
  BENCHMARKS" block in `planPrompt`; the sweet spot and cadence replace the
  playbook's generic duration/cuts-per-minute unless a template or an
  explicit duration is set.
- Critic: `ReelCritic` gets the account's outcome rubric and returns
  `engagement_forecast` (0–100 vs the account's own reels) with
  `forecast_reasons`; reasons ride into the re-plan notes, and a forecast
  under 55 triggers another version even when the craft score is fine.
- Calibration: published reels get `audience_score` / `audience_percentile`
  (`generated_videos`, migrated) once insights land; Reports → Posts shows
  "Critic vs Audience" (forecast vs actual percentile, average error) and
  the Library card shows the audience line.
- Lessons: `PerformanceLessons` receives the benchmarks block; distilling
  works as soon as benchmarks exist.
- Captions: `captionPrompt` receives lifting hashtags + hot subjects;
  the gap report's inventory includes the benchmarks summary.
- Publish sheet: best posting slots and an "Add Top Hashtags" button.
- Verified with the headless harness on the real checkout: 103 reels,
  median 660 reach, sweet spot 16–37s, Saturday evenings best, comment
  magnets Bonfim / McGregor / Holloway. Forecast calibration accumulates
  as reels are published; the critic's forecast itself is model-judged and
  untested against live data.
