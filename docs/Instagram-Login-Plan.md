# Instagram Login Support Plan

Date: September 30, 2026. Status: draft for review. Implementation: Codex; build,
tests and review: Claude (per the September 23 working rule).

## Problem

Clip Builder reaches Instagram only through the **Facebook Login** flavor of the
Graph API. `GraphAPIProvider` is pinned to `https://graph.facebook.com/v23.0`, and
`resolveAccount` discovers the Instagram account by listing the token's Facebook
Pages and reading each Page's `instagram_business_account`. That path requires:

- a Professional Instagram account **linked to a Facebook Page**;
- a Facebook user with a role on that Page, who generates the token;
- for the token to be pasted by hand (Settings › Instagram), then extended.

The user wants to connect **@peacegrappler_podcast**, for which they hold the
Instagram login but no Facebook Page or Page role. Meta's second flavor,
**Instagram API with Instagram Login**, needs no Facebook account at all: the
token is issued for the Instagram professional account itself and served from
`graph.instagram.com`. The media, insights, comments and publishing endpoints
have the same shapes on both hosts; only discovery, the host, the scope names and
the token lifecycle differ.

Today an Instagram-Login token pasted into Settings fails at
`me/accounts` on the Facebook host with error 190 and the app says the token is
"expired or invalid", which is misleading.

A second, independent limitation: `KeychainStore` holds one token
(`instagram_graph_token`) and `InstagramSettings` one connected account per
profile. That is not changed by this plan; a second account lives in a second
profile (see Out of scope).

## Goal

Accept an Instagram-Login token in the same Settings field, detect which flavor
it is, route every call to the right host, keep it alive without user action,
and report a clear message when either flavor is missing something. The rest of
the app (reports, comments, publishing, benchmarks) keeps working unchanged
because the provider's public surface (`InstagramProvider`, `ResolvedAccount`,
`IGMediaItem`, `PublishedReel`, insights structs) does not change.

## Meta-side facts the design relies on

Verified against Meta's documentation as of September 2026; step 0 of phase 1
re-verifies them with a live token before any code is written.

| | Facebook Login (today) | Instagram Login (new) |
| --- | --- | --- |
| Host | `graph.facebook.com/v23.0` | `graph.instagram.com/v23.0` |
| Token prefix | `EAA…` | `IG…` |
| Discovery | `me/accounts` → `instagram_business_account` | `me?fields=user_id,username,name,account_type,followers_count,media_count` |
| Account id for paths | `instagram_business_account.id` | `user_id` from `me` (not `id`, which is app-scoped) |
| Media, insights, comments, publish | `/{ig-id}/media`, `/{media}/insights`, `/{media}/comments`, `/{ig-id}/media` + `media_publish` | same paths, same fields and metric names |
| Scopes | `instagram_basic`, `instagram_manage_insights`, `instagram_manage_comments`, `instagram_content_publish`, `pages_show_list`, `pages_read_engagement` | `instagram_business_basic`, `instagram_business_manage_insights`, `instagram_business_manage_comments`, `instagram_business_content_publish` |
| Permission check | `me/permissions` | not available; infer from the granted scopes at token generation, surface per-call 10/200 errors |
| Long-lived token | Access Token Debugger "Extend", or Page token (never expires) | 60 days; `GET graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token&access_token=…` (no app secret, token must be ≥ 24 h old and unexpired) |
| Where the user gets one | Graph API Explorer | App dashboard › Instagram › "API setup with Instagram login" › add the account as an Instagram Tester › **Generate token** (long-lived, no OAuth code needed) |
| App requirement | app has Facebook Login for Business | app has the **Instagram** product added; account added as tester in Development mode, or App Review for Live |

The dashboard's Generate token button is what makes a paste-only flow enough:
no OAuth redirect, no app secret in the app.

## Design

### D1. Token flavor

```swift
nonisolated enum InstagramTokenFlavor: String, Codable, Sendable {
    case facebook, instagram
    static func detect(_ token: String) -> InstagramTokenFlavor  // "IG" prefix → .instagram, else .facebook
}
```

Prefix detection is the fast path; `connectInstagram` (D4) confirms it by
probing, and the confirmed flavor is what gets stored. The stored flavor, not
the prefix, drives every later call.

### D2. Provider

`GraphAPIProvider` gains `let flavor: InstagramTokenFlavor` (default
`.facebook`, so every existing call site and test compiles unchanged) and
`private var base: String` derived from it. All request helpers use `base`.

`resolveAccount(matching:)` branches:

- `.facebook`: unchanged.
- `.instagram`: `GET me?fields=user_id,username,name,account_type,followers_count`.
  `ResolvedAccount(id: user_id, username:, name:, followers:)`. A `username`
  mismatch produces the same "@x is not among the token's Instagram accounts"
  error as today, with the single found account listed. `account_type` other
  than `BUSINESS` or `MEDIA_CREATOR` throws
  "@x is a personal account; switch it to Business or Creator in the Instagram
  app".

`missingPermissions()` returns `[]` for `.instagram` (no `me/permissions`), and
`noVisiblePagesMessage` is never reached on that flavor. The 10/200 error text in
`getJSON(url:label:)` names the right scope set per flavor.

`pageToken()` (the Page-token derivation used at connect) returns `nil` for
`.instagram`.

Everything else in the provider (media listing, insights, comments, downloads,
publishing, account insights, followers) is unchanged: same paths, same fields.
Publishing on the Instagram host uses the identical container → status →
`media_publish` sequence.

### D3. Token lifecycle

`InstagramSettings` gains:

```swift
var tokenFlavor: String = "facebook"          // InstagramTokenFlavor.rawValue
var tokenExpiresAt: Date? = nil               // nil = unknown / never (Page tokens)
var tokenRefreshedAt: Date? = nil
```

with `CodingKeys` entries `token_flavor`, `token_expires_at`,
`token_refreshed_at` and `decodeIfPresent` defaults (the settings struct uses
synthesized Decodable, so new fields must be optional or given an explicit
init; see the AnalysisRunSettings lesson).

`InstagramService.refreshTokenIfNeeded(settings:)` runs at the start of every
Graph fetch and publish when `tokenFlavor == "instagram"`:

- if `tokenRefreshedAt` is more than 24 h ago and `tokenExpiresAt` is within 14
  days (or unknown): call `refresh_access_token`, save the new token to the
  Keychain under the same account, set `tokenExpiresAt = now + expires_in`,
  `tokenRefreshedAt = now`;
- on failure, log once and continue with the current token (the fetch will
  produce the real error if it is dead).

For `.facebook` nothing changes; Page tokens never expire and User tokens are
extended by hand as today.

The Settings screen shows the flavor and expiry under Connected:
"Instagram Login · refreshes automatically · expires Nov 29" or
"Facebook Page token · never expires".

### D4. Connect

`AppStore.connectInstagram(token:)`:

1. `flavor = InstagramTokenFlavor.detect(token)`.
2. Probe with that flavor's `resolveAccount`. On failure, probe the other
   flavor once; if that succeeds, use it (prefix heuristics can be wrong). If both
   fail, present the error from the detected flavor.
3. Save the token, `connectedUsername`, `connectedIGUserID`, `tokenFlavor`,
   and for `.instagram` set `tokenRefreshedAt = now`, `tokenExpiresAt = now + 60 d`
   (the dashboard-generated token is long-lived; the first refresh corrects the
   estimate from `expires_in`).

Settings › Instagram help text gains one paragraph describing the Instagram
Login route: add the account as an Instagram Tester in the Meta app, accept the
invite in the Instagram app (Settings › Apps and websites › Tester invites),
click Generate token, paste it here. No Facebook Page needed.

### D5. Errors

- An `EAA` token that sees no Page keeps the improved wording from
  `noVisiblePagesMessage`, plus one sentence: "Or generate an Instagram Login
  token for the account instead (no Facebook Page needed)".
- An `IG` token on a personal account: the D2 message.
- Error 190 on `.instagram`: "Instagram Login token expired or was revoked;
  generate a new one in the Meta app dashboard".
- Error 10/200 on `.instagram`: names the `instagram_business_*` scopes.

## Phases

1. **Verification spike (no code).** With a token generated from the dashboard
   for @peacegrappler_podcast, run `me`, `/{user_id}/media?fields=…`,
   `/{media}/insights?metric=views,reach,…`, `/{media}/comments` and
   `refresh_access_token` by curl, and record the exact responses in this
   document under "Verified responses". This pins the `user_id` vs `id` question
   and the metric names before anything is written.
2. **Provider** (D1, D2). Flavor enum, `base`, `resolveAccount` branch, error
   text. Tests below.
3. **Lifecycle + connect** (D3, D4, D5). Settings fields, refresh, connect probe,
   Settings text.

Phases 2 and 3 are one PR. Nothing changes for an existing Facebook connection.

## Tests (`ClipBuilderTests/Services/Instagram/`)

Use the existing `InstagramTestTransport` (keyed by path) so both hosts can be
stubbed.

- `GraphAPIProviderTests`: `.instagram` resolve reads `user_id`; personal
  account type throws the switch-to-Professional message; username mismatch
  lists the found account; `missingPermissions` is empty; every media/insights/
  comments/publish request goes to `graph.instagram.com` when the flavor is
  `.instagram` and to `graph.facebook.com` otherwise (assert on request hosts).
- `InstagramTokenFlavorTests`: prefix detection for `EAA…`, `IG…`, and garbage.
- `InstagramServiceTests`: refresh runs only when older than 24 h and within
  14 days of expiry; a failed refresh keeps the old token and the fetch proceeds;
  a successful refresh writes the Keychain and the two dates.
- `AppStoreTests`: connect with an `IG` token stores flavor `instagram` and the
  60-day estimate; connect with an `EAA` token stores `facebook` and leaves the
  dates nil; a mis-prefixed token is recovered by the second probe.
- `SettingsCodableTests`: settings JSON from before this change decodes with
  `tokenFlavor == "facebook"` and nil dates.

## Out of scope

- **OAuth in-app login.** The Business Login redirect flow needs the app secret
  and a redirect URI; the dashboard's Generate token covers the owner's own
  accounts without it. Revisit if a non-owner user ever needs to connect.
- **Several own accounts in one profile.** Keychain and settings hold one
  token; the podcast account gets its own Clip Builder profile. Multi-account
  would be its own plan (Keychain account per handle, `kind == "own"` rows per
  token, Settings list).
- **Messaging scopes** (`instagram_business_manage_messages`); the app has no
  DM feature.
- **App Review.** Development mode with the account added as a tester is
  enough for the owner's own accounts.

## Open questions

1. Should the refresh also apply to Facebook User tokens through the debug
   endpoint? They are extended by hand today and Page tokens never expire, so
   the plan leaves them alone.
2. Reports history backfill (`peaceGrapplerRepoPath`) is keyed by handle, not
   by token flavor; confirm nothing there assumes a Facebook Page id.
