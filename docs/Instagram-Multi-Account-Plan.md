# Instagram Multi-Account Plan

Date: October 1, 2026. Status: approved October 1, 2026; not implemented. Implementation: Codex; build,
tests and review: Claude (per the September 23 working rule). Builds on
`docs/Instagram-Login-Plan.md` (phases 2–3 implemented, uncommitted) and lands
after that work is committed.

## Problem

The app holds exactly one Graph connection, and it is **app-wide, not
per-profile**:

- `InstagramSettings` (`connectedUsername`, `connectedIGUserID`, `tokenFlavor`,
  `tokenExpiresAt`, `tokenRefreshedAt`) lives in `AppSettings`, which is
  `app_settings.json`, shared by every profile.
- `KeychainStore` holds one token under the fixed account
  `instagram_graph_token`.

Consequences today:

- Connecting @peacegrappler_podcast disconnects @peacegrappler. There is no way
  to have insights, comments and publishing for both.
- The Instagram Login plan's "a second account lives in a second profile" does
  not work as written: switching profiles keeps the same single connection.
- Publish to Instagram always targets the one connected account, whichever
  profile is open.

Everything downstream is already keyed per account and needs no change: the
`ig_*` tables hang off `ig_accounts.id`, the cache folders are per username, and
`InstagramService` picks Graph or public web by matching a username against the
connection.

## Goal

Any number of own accounts connected at once, each with its own token, flavor
and refresh state. A profile can use several of them: each one fetches through
the Graph API with full insights, and Publish asks which account the reel goes
to. Existing single-connection installs migrate without reconnecting.

## Design

### M1. Connection model

```swift
nonisolated struct InstagramConnection: Codable, Sendable, Identifiable, Equatable {
    var username: String
    var igUserID: String          // identity; also the Keychain key
    var tokenFlavor: String       // InstagramTokenFlavor.rawValue
    var tokenExpiresAt: Date?
    var tokenRefreshedAt: Date?
    var id: String { igUserID }
}
```

`InstagramSettings` gains `var connections: [InstagramConnection] = []`
(`CodingKeys` entry `connections`, `decodeIfPresent ?? []`) and helpers:

- `connection(for username: String) -> InstagramConnection?` (case-insensitive);
- `isGraphConnected` becomes `!connections.isEmpty`.

The five legacy single-connection fields stay decodable but are no longer
written or read after migration.

Connections stay app-wide: a token is a credential for an account, not for a
profile. Which accounts a profile *uses* is already expressed by that profile's
`ig_accounts` rows.

### M2. Keychain

`KeychainStore.graphTokenAccount(igUserID:)` returns
`"instagram_graph_token:<igUserID>"`. One item per connection. Save, read,
refresh and delete all take the connection's id.

### M3. Migration

Pure function in `Services/Instagram/InstagramConnectionMigration.swift`
(`nonisolated enum`, tested): given decoded settings with a non-empty legacy
`connectedUsername` and empty `connections`, return settings with one
connection built from the legacy fields and the legacy fields cleared.

The store runs it once at settings load, then moves the Keychain item: read
`instagram_graph_token`, write `instagram_graph_token:<id>`, delete the legacy
item only after the write succeeds. If the legacy `connectedIGUserID` is empty
(very old connect), the connection is dropped and the user reconnects; the
token cannot be keyed without an id.

### M4. Service routing

`InstagramService.connectedGraphProvider(username:settings:)` looks up
`settings.connection(for: username)` and reads that connection's token. The
"Graph when the username matches the connection, else public web" rule is
unchanged; it now matches against a list.

Refresh (`refreshTokenIfNeeded`) operates on a connection instead of the whole
settings struct:

- `lastRefresh` becomes a dictionary keyed by `igUserID`, so two accounts
  refreshing in the same session do not evict each other;
- `persistTokenRefresh` and `AppStore.applyInstagramTokenRefresh` take the
  `InstagramConnection` snapshot and commit only if the connection with that id
  still exists with the same `tokenRefreshedAt` and Keychain token;
- the existing `refreshKey` already includes the user id and stays.

`publishReel(file:caption:shareToFeed:settings:log:)` gains
`account username: String` and resolves the provider for that connection. It
throws "@x is not connected" rather than falling back to another account.

### M5. Store

- `connectInstagram(token:)`: probe as today. If a connection with the resolved
  `igUserID` exists, replace its token and dates (reconnect); otherwise append.
  For a Facebook token that sees several Instagram accounts, prefer the one
  matching the active profile's handle, then the first not yet connected, then
  the first. One paste connects one account.
- `disconnectInstagram(_ connection:)`: deletes that Keychain item and removes
  that connection only.
- `primaryInstagramAccount`: the account benchmarks, the wizard and the critic
  read. Order: the profile's own handle (`socials["instagram"].handle`) when it
  is in `igAccounts`; else the first `igAccounts` row that has a connection;
  else the first `isOwn` row. Replaces the `connectedUsername` lookups in
  `reloadIGBenchmarks` and `importPeaceGrapplerReports` (the import prefers the
  selected own account, then the primary).
- `isGraphAccount(_:)`: `settings.instagram.connection(for: account.username) != nil`.
- `addInstagramAccount`: `isOwn` when the handle matches the profile handle or
  any connection.
- `publishReelToInstagram(video:caption:shareToFeed:account:log:)` passes the
  chosen account through and refreshes that account afterwards.

Benchmarks stay single (`igBenchmarks` for the primary account). One profile
has one audience model; per-account benchmarks are out of scope.

### M6. UI

- **Settings › Instagram › Own Accounts (Graph API)**: one row per connection
  (handle with the green seal, the flavor/expiry caption from the Instagram
  Login work, a Disconnect button), then the token field and **Connect
  Account**, always visible. The two help paragraphs move under the field
  unchanged. Rows are `lineLimit(1)`.
- **Publish sheet**: the header label becomes a `Picker` over the connections
  whose account is in this profile's `igAccounts`, shown as a plain label when
  there is one. Default: the account this profile last published to
  (`BrandProfile.instagramPublishAccount: String?`, key
  `instagram_publish_account`, `decodeIfPresent`, written on a successful
  publish), falling back to the primary account when it is unset or no longer
  connected. Publishing tips (best times, top
  hashtags) show only when the chosen account is the benchmarks account. With
  several connections and none in this profile, the sheet says to add the
  account on the Instagram screen first, so a reel cannot go to another
  profile's account by accident.
- **Instagram screen**: no change. The account list already marks Graph
  accounts through `isGraphAccount`.

## Phases

1. **Model, Keychain, migration** (M1–M3). No behavior change for a
   one-connection install.
2. **Service and store** (M4, M5). Routing, per-connection refresh, connect and
   disconnect, primary account, publish target parameter.
3. **UI** (M6). Settings list, publish picker.

One PR. Each phase compiles on its own.

## Tests

- `InstagramConnectionMigrationTests`: legacy fields become one connection;
  already-migrated settings are untouched; empty legacy id drops the
  connection.
- `SettingsCodableTests`: pre-change JSON decodes with empty `connections`;
  a two-connection round trip keeps both.
- `InstagramServiceTests`: two connections of different flavors route to their
  own hosts and tokens; a username with no connection goes to the web provider;
  refreshing one connection leaves the other's token and dates alone; the
  existing refresh timing and dedupe tests run against a connection.
- `AppStoreTests`: second connect appends; reconnecting the same account
  replaces in place; disconnect removes one and keeps the other's Keychain
  item; primary account order; publish with an unconnected account throws; a
  successful publish stores the account on the profile, and a remembered
  account that was disconnected falls back to the primary.
- `BrandProfile` decoding: a profile JSON without `instagram_publish_account`
  decodes with nil.

Keychain reads and writes are already injected in the store methods; the
service's token read gets the same injection so no test touches the real
Keychain.

## Out of scope

- Per-account benchmarks, wizard targets or critic briefs within one profile.
- Publishing one reel to several accounts in one action.
- Connecting every account a Facebook token sees in one paste.
- Per-profile connection lists. Revisit if two profiles must never see each
  other's accounts.
