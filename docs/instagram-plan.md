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
