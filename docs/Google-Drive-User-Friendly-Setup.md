# Google Drive: user-friendly setup

September 6, 2026. Follow-up to docs/Google-Drive-Implementation-Plan.md.

## Problem

The app currently tells users "Google Drive is not configured. Set
GoogleOAuthClientID and GoogleOAuthClientSecret in Info.plist." Users do not
know what a plist is and must never be asked to edit one. The screenshot that
raised this shows the message inside the "Add from Google Drive" sheet, in red,
next to Retry and Reconnect buttons that cannot help.

## Principle

Connecting Google Drive is one click: Settings › Google Drive › Connect, then
Google's sign-in page. The Google OAuth client belongs to the developer and
ships inside the app; users are added as test users in the Google console.
No user-facing text may mention plist, Info.plist, client id, client secret,
OAuth, PKCE, scopes, or key names.

## R1. Credentials ship with the app (build time)

- Keep `Configuration/GoogleDrive-Info.plist` in git with empty values.
- Add a git-ignored local override the build picks up automatically:
  `Configuration/GoogleDrive-Local.xcconfig` (or a git-ignored
  `GoogleDrive-Local.plist`), documented in docs/Google-Drive-Setup.md as a
  developer-only step. `scripts/make_pkg.sh` and the release flow must fail
  hard with a clear message when the release build has empty credentials,
  the same way signing identities are checked today.
- Debug builds without credentials still run; they show the "not available"
  state below, never an error.

## R2. Plain-language states in the app

Settings › Google Drive:
- Not available in this build: "Google Drive isn't available in this copy of
  Clip Builder." plus, collapsed under an "Advanced" disclosure, a small form
  where a user who has their own Google credentials can paste a Client ID and
  Client Secret (stored in the Keychain for this Mac, not in any file), with
  a "Where do I get these?" link to a short in-app help sheet. This form is
  the only place these terms may appear, and it is hidden by default.
- Not connected: one sentence and a Connect button.
- Connected: account email, "Expires <date>" with a Reconnect button, and
  Disconnect.
- Needs reconnect: "Google asked us to sign in again." and a Reconnect button.

Everywhere else (Add from Google Drive sheet, upload menu, Activity rows):
- If Drive is not connected or not available, show a friendly empty state
  with an "Open Google Drive Settings" button that opens Settings on the
  Google Drive tab. No red error text, no Retry/Reconnect pair.
- Error messages rewritten in plain language:
  - not available: "Google Drive isn't available in this copy of Clip Builder."
  - reconnect: "Please sign in to Google again to continue."
  - offline: "You appear to be offline. We'll retry when you're back."
  - quota: "Google Drive is out of space or busy. Try again later."
  - not found: "That file is no longer in Google Drive."
  - account mismatch: "Please sign in with <email>, the account this profile uses."
  - in use / conflict: keep the meaning, plain words, no jargon.

## R3. First-run guidance

The first time a user opens "Add from Google Drive" or "Upload to Google
Drive" without a connection, show a one-screen explainer: what connecting
does (browse and download your Drive videos, upload finished reels), what it
does not do (no project data leaves the Mac), and a Connect button that runs
the sign-in right there and returns to the sheet on success.

## Tests

- Every `GoogleDriveError` description passes a test asserting it contains
  none of: "plist", "Info.plist", "GoogleOAuth", "client id", "client secret",
  "OAuth", "PKCE", "scope".
- The Advanced credentials form stores and reads from the Keychain and takes
  precedence over the bundled values; clearing it falls back to the bundle.
- The release script check fails when credentials are empty (shell test or
  documented manual check).
