# Google Drive setup and verification

## For Clip Builder users

Open **Settings → Google Drive → Connect** and sign in with Google. You can
also connect directly from the introduction shown the first time you open
**Add from Google Drive** or **Upload to Google Drive**.

If this copy says Google Drive isn't available, ask the person who supplied
Clip Builder for an updated copy. There are no configuration files to edit.
Advanced setup in Settings is optional and hidden by default.

Google may ask you to sign in again after seven days. Reconnect with the same
account to continue paused transfers. Disconnect removes the saved connection
for the current profile from this Mac. Projects, timelines, analysis, and
settings stay on your Mac; only the media you choose is uploaded.

Sources → Add from Google Drive opens the browser. The same action is available
alongside Add Files in resource libraries; downloaded videos go into project
Sources. My Drive and shared-drive folders support breadcrumbs and paging;
Shared with me, Recent, name search, thumbnails, multi-selection, and a Videos
only filter are available. Turning the filter off lets you browse other files;
only video media can be imported into Sources.

Use a source/output cloud menu to upload, open its Drive link, fetch it, or remove
the local copy. Use an output’s More or context menu to select it for Drive actions, then use
the toolbar to upload the selection. Files already in Drive are excluded from
uploads. Wizard results also have an upload menu. The folder picker remembers a destination per profile;
on first use it creates `Clip Builder/<profile>/<project>`. Shared files display
an additional warning before off-load. Active media use prevents off-load.

Transfers stay attached to their originating profile/project across navigation.
Stop preserves partial bytes or the resumable upload session. Resume retries a
stopped/offline job. After relaunch, attach the owning profile to restore its
pending Activity rows, then Resume. A reconnect resumes jobs paused for auth.
Temporary media and download/restore checkpoints stay in a hidden `.drive`
subfolder beside the media, keyed by a hash of its original path. Existing
adjacent sidecars migrate on first use. No project data is uploaded.

## For developers only: configure a distributable build

Clip Builder uses a Google OAuth **Desktop app** client with PKCE and a loopback
redirect. Enable the Google Drive API in Google Cloud Console, configure the
consent screen, and add the intended accounts as test users while in Testing
mode. Request `drive` (full access: the asset library lives in folders the app did not create), `openid`, and `email`.

Keep `Configuration/GoogleDrive-Info.plist` unchanged with empty placeholders.
For your local build:

1. Copy that file to `Configuration/GoogleDrive-Local.plist`. Fill in
   `GoogleOAuthClientID` and `GoogleOAuthClientSecret` with your Desktop app
   credentials. Do not put account access/refresh tokens there.
2. Create `Configuration/GoogleDrive-Local.xcconfig` containing:

   ```xcconfig
   INFOPLIST_FILE = Configuration/GoogleDrive-Local.plist
   ```

Both local files are git-ignored. Both app configurations use the tracked
`GoogleDrive.xcconfig`, which automatically includes the local override when
present. Xcode merges the selected input with its generated app information.
Without these local files, Debug still builds and displays the friendly
unavailable state. Do not place credentials in the tracked project file.

`scripts/make_pkg.sh` (also used by the release workflow) refuses to proceed
without complete local values, even for an unsigned package. It validates the
actual built app as well, before signing verification/staging, so an ignored or
miswired override cannot silently ship. Validation never prints the values.
Run `/bin/sh scripts/test_google_drive_credentials.sh` to check empty, partial,
missing, unresolved, and valid fixtures and the packaging preflight.

A Desktop app's bundled client secret is not a confidential server secret.
Users' account tokens remain in their per-profile Keychain entries. The
Advanced form uses one separate device-only Keychain item for the application
credentials; it overrides the bundle for every profile on that Mac. Use App
Defaults deletes that item and falls back to the bundle. Changing application
credentials requires signing in again; it does not change stored Drive ids.

## Developer verification


Run the repository’s normal test suite:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -quiet -project "Clip Builder.xcodeproj" -scheme MyApp \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/clipbuilder-tests CODE_SIGN_IDENTITY=- \
  test -only-testing:ClipBuilderTests
```

`GoogleDriveTests` uses an injected fake transport and in-memory credential store.
The live suite is disabled unless `CLIPBUILDER_DRIVE_INTEGRATION=1` is present in
the **test process** environment. Set these environment variables in the Xcode
test scheme (or use the runner’s `TEST_RUNNER_` forwarding mechanism):

- `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`
- `GOOGLE_OAUTH_REFRESH_TOKEN` — a current testing-mode token with the `drive` scope
- `GOOGLE_DRIVE_TEST_FOLDER_ID` — a disposable folder the account can write
- `GOOGLE_DRIVE_TEST_VIDEO` — an absolute path to a small local video fixture

The integration test uploads a uniquely named fixture, lists it, downloads it,
off-loads it, restores it, compares checksums, and deletes only that newly created
remote fixture. A process crash can leave that fixture behind; clean it up in the
test folder. Credentials are never printed by the test.

## Manual pass still required

Connect a real test account; browse personal/shared drives; download a 1 GB video;
Stop and Resume mid-transfer and after relaunch; switch projects while downloading;
check registration remains in the original project; off-load; preview, analyze,
render a timeline, and publish using off-loaded media. Revoke consent or use an
expired token, confirm Activity pauses for Reconnect, then reconnect and resume.
Check upload interruption/recovery and verify existing thumbnail/analysis data
survives removal of local media.

Implementation references: [Google native OAuth](https://developers.google.com/identity/protocols/oauth2/native-app),
[Drive resumable uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads),
[Drive downloads](https://developers.google.com/workspace/drive/api/guides/manage-downloads).
