# Performance stability validation

September 14, 2026. Validate the normal Release app with the production scheduler,
whole-finishing cache and crossfade-group cache. Incremental overlays remain an
opt-in experiment outside normal exports.

## Fixture and isolation

Used the available Du Plessis vs Strickland round-five fight recording:
**140.54449 seconds (2:20.544)**. The scratch database reuses the deterministic
40-clip, 80-second timeline with two fades, captions, text and an overlay block.
The normal app launches with `-ClipBuilderDataFolder` pointing into the ignored
`build/stability-validation/data` directory. User projects and media are preserved.

## Confirmed save failure and fix

The pre-fix normal Release app reported `ApplyFailure.staleRevision` after a
timeline drag followed by quitting. It exited in approximately 0.6 seconds;
that interaction did not reproduce the earlier shutdown timeout.

Autosave had already persisted the current document revision. The termination
flush submitted it again, and the database correctly rejected an equal revision.
AppStore now skips acknowledged revisions and duplicate revisions queued while a
write is in progress. The database compare-and-swap guard remains unchanged, so
an equal-revision autosave cannot overwrite a competing Wizard commit.

The repeated-flush regression failed before the fix and passed afterward.
Focused tests also cover overlapping flushes, subsequent edits and the existing
Wizard persistence/conflict cases. The full suite passed **843 tests**, with one
opt-in live Google Drive integration test skipped.

## Real-app validation

The fixed normal Release build passed. The app used the scratch profile and
actual UI controls; the available fight source remained read-only.

| Check | Observed result |
| --- | --- |
| Preview, scrubbing and clip selection under load | Preview rendered and played; timeline interactions remained usable. No latency percentile is claimed. |
| Caption placement edits | Changed the selected clip between Bottom, Top and None. The database retained the final None setting through relaunches. |
| Completed exports and cache reuse | Completed initial, repeated and caption-position-edited exports. Logs confirm a whole-finishing cache hit for the repeat and both crossfade-group cache hits after the caption edit. |
| Preview cancellation | Cancel acknowledged; no direct child processes observed afterward (about 0.08 s after pressing Cancel in this check). |
| Render cancellation | Stop acknowledged; observed child processes drained in about 0.24 s. This request arrived during post-render work; a completed output had already been registered. |
| Quit during preview | Exited in about 0.67 s with no observed children remaining. |
| Quit during full export | An active FFmpeg child was observed before Cmd-Q. Exited in about 0.30 s with that child gone. |
| Save and relaunch | No new save errors across the fixed-app sessions. The timeline reopened and the persisted caption edit remained in the database. |

The earlier shutdown timeout did not reproduce. The normal Release UI logs
showed roughly 35.4 s for the initial export, 5.4 s for its repeat and 17.2 s
for the completed caption-position edit. These are single functional runs with
normal publishing/metadata work and an interactively edited fixture, not paired
controls against the earlier diagnostic baselines. The repeated export spent
about 4.8 s between its finishing-cache hit and its saved-output log; profiling
that normal-export work is a useful follow-up before choosing the next optimization.

No evidence here establishes long-recording behavior, live Drive cancellation,
or the worst-case latency of quitting. The app was closed after validation.

## Evidence

Machine-local evidence lives in ignored `build/stability-validation/`, including
the pre-fix log, screenshots, database snapshots and full-test result summary.
Build and test logs are under `/private/tmp/clipbuilder-stability-*.log`.
These checks establish behavior; they are not new paired performance benchmarks
or measurements of UI latency percentiles, long recordings or live Drive work.
