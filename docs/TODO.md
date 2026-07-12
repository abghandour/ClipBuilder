Phase 1 — Safety & trust (highest priority, UX + code combined)

These are the "works for its author → safe for anyone" fixes, and the two reviews converged on them from both sides:

1. Undo/redo in the Builder. BuilderStore mutates TimelineDocument directly with no UndoManager — every trim, move, delete, and crop edit is irreversible. Since the document is Codable, snapshot-before-mutation with a bounded undo stack is cheap to add. ⌘Z is the most basic macOS expectation for an editor.
2. Confirm destructive actions. The toolbar trash in BuilderView.swift:62 clears the timeline and deletes the autosave with one unconfirmed click. Same for "Open in Builder" silently replacing a non-empty timeline (AppStore.swift:352).
3. Make long jobs cancellable, end to end. This needs three layers: wrap ProcessRunner.run in withTaskCancellationHandler so ffmpeg processes actually die on cancel (ProcessRunner.swift:37 — today orphaned encodes run to completion); store Task handles on AppStore for wizard/analysis/render with Task.checkCancellation() at loop tops; add Stop buttons next to every spinner.
4. Human-readable errors. The alert shows raw Error Domain=NSCocoaErrorDomain… interpolations, and a second error silently overwrites the first. Introduce a small UserFacingError (message + recovery suggestion) and queue them. Also fix the ~5 places in AppStore where try? await database… swallows a failed write but updates the UI as if it succeeded.

Phase 2 — First-run experience & flow

5. An import path that doesn't require Settings. There is no in-app import at all — files must land in a folder configured in Settings. Add .dropDestination(for: URL.self) on the main window and Analyze view, plus an actionable empty state in Library ("Add videos" button) instead of the current dead-end text.
6. Sidebar order matching the workflow. Reorder to Analyze → Scenes → Builder → Wizard → Library (or group with Section headers: Source / Create / Output), add ⌘1–5 section shortcuts.
7. Render completion affordance. Success is currently one log line in a 110pt drawer. Add a toast/banner with "Reveal in Library" / "Show in Finder", and a notification when the window is inactive.
8. Settings that save on change. Explicit Save buttons are un-macOS-like, and switching profiles mid-edit silently discards changes.

Phase 3 — Timeline editor ergonomics

9. Left-edge trim — there's currently no way to adjust a clip's in-point on the timeline at all (TimelineView.swift:343). This is a fundamental editor operation.
10. Zoom-aware snapping — the fixed 0.5s grid means 100pt jumps at max zoom; scale with zoom, snap to neighbor edges, ⌥ to disable.
11. Zoom that keeps the playhead anchored instead of flinging the view back to x=0, plus keyboard nudging (arrow keys), space-to-play, and click-in-lane playhead placement.
12. Honest drag preview in sequential tracks — show an insertion caret instead of free movement that jumps on drop.
13. Filmstrip thumbnails on clip blocks (the thumbnail disk cache already amortizes this) and real audio-file durations for music blocks instead of the 10s default.

Phase 4 — Codebase hardening

14. PRAGMA busy_timeout — the DB is explicitly shared with the old Python app, but no busy timeout is set, so a concurrent write makes bulk transcript saves fail instantly (and per #4, silently).
15. Fix a small command-injection vector: the user-configurable AI provider binary name is interpolated verbatim into zsh -lc "command -v \(tool)" (ProcessRunner.swift:160). Pass it as an argument instead.
16. Extract shared RenderSupport — WizardEngine and MultitrackRenderer duplicate asset resolution, output naming, intro/outro normalization, and caption assembly, and they've already drifted (different counter-scan rules, different caption filtering/caching).
17. Race fixes: refreshAll can commit a stale snapshot after a profile switch (cancel-and-replace with a DB-identity check); didTimeOut in ProcessRunner is an unsynchronized cross-thread Bool; profile deletion leaks -wal/-shm sidecars and can delete a live DB.
18. Perf & hygiene: cache (path, size, mtime) → hash so folder events stop re-fingerprinting the entire library (~1GB of IO per dropped file at 500 clips); make ffprobe failures throw instead of propagating zero durations into renders; purge stale multi-GB scratch dirs on launch; make FolderWatcher recursive.

On Swift skills

Nothing needs to be downloaded — there's no Swift-specific skill, and none is needed: I read, write, and build Swift/SwiftUI natively, and the built-in /run, /verify, and /code-review skills all work on this project as-is. Two optional things that would genuinely help, both installable via brew, are:

- xcbeautify — makes xcodebuild output readable, so I burn far less context parsing build logs. ✅ installed 2026-07-10
- swiftlint + swift-format — gives the codebase enforced consistency and lets me catch issues mechanically before review. ✅ installed 2026-07-10

A third option if you want tighter Xcode integration: the XcodeBuildMCP server (an MCP server, not a skill) lets me build, run, and drive the app/simulator directly. ✅ installed 2026-07-10 (project-local MCP config, runs `npx xcodebuildmcp mcp` with DEVELOPER_DIR set) For a Mac app this size it's nice-to-have, not necessary — plain xcodebuild works fine. I'd also suggest we eventually add a small project skill (.claude/skills/) capturing the exact build-and-run incantation for ClipBuilder, so /run and /verify work first-try every time.