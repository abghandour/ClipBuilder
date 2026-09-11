# Scriptable Builder phase 3 implementation

Implemented as an uncommitted continuation of `de518df`. Local parsing remains the default. The Wizard persists an explicit provider choice under `ai.tasks.builder_agent`; model selection uses `ai.taskModels.builder_agent`, then the selected provider's model. This path never calls AIService or its retry/fallback dispatcher.

## Endpoint and run lifetime

`BuilderMCPServer` uses SDK 0.12.1 `Server` and `StatelessHTTPServerTransport`. `MCPHTTPHost` is the spike's Network.framework framing adapter, with an ephemeral port bound to 127.0.0.1, no HTTP logging, and shutdown instead of process exit on deadline. Bearer, Host, absent-or-exact Origin, exact path, protocol pin, JSON-only POST, 202 notifications, GET 405, 16 KiB headers, 1 MiB body, 32 connections and 30-second request deadlines remain enforced.

One JSON-RPC request is active at a time. Canonical request-ID fingerprints cache successful or failed HTTP responses; identical duplicates do not execute again, changed arguments fail the preview. Cache bounds are 256 IDs and 16 MiB. Notifications remain admissible during an active call. Cancellation revokes admission and ends the run, draining both the session task and its complete SDK callback before freezing. Stopping the endpoint also cancels its CLI. Tokens are revoked before cleanup; result strings are redacted before JSON encoding, and logs retain argument field names rather than argument values.

The remote summary covers every document lane without file paths. Queries use the captured Library and working session. `run_script` exposes the existing closed command vocabulary, with per-operation schemas and typed results. Ensures are absent unless specific commands were disclosed and confirmed; a different video, an undisclosed kind, an ensure hidden in a script, or an ensure after mutations is refused. The Wizard can disclose locally recognized prerequisites before starting the agent. Other agent requests start without prerequisite permissions.

Budgets are stored in `AppSettings.builderAgent` (`builder_agent` in JSON). Defaults: 180 seconds, 64 tool calls, 2,000 affected items, 256 KiB arguments, 1 MiB result, 256 KiB logs, 8 MiB combined CLI output. Hard maxima: 600 seconds, 128 calls, 10,000 items, 256 KiB arguments, 1 MiB result/logs, 16 MiB output. Bulk mutations reserve a conservative whole-document item cost. Prerequisites retain phase 2b's separate service limits, plus at most twelve ensure calls here. A terminal audit event has reserved log space.

## Process adapter and provider gates

`ProcessRunner+Agent.swift` adds an opt-in POSIX spawn path under ProcessRunner. It accepts argv, an explicit complete environment and cwd; uses `/dev/null` stdin, bounded nonblocking pipe reads and a bounded stderr tail; creates a dedicated process group; and kills/reaps the group on completion, cancellation, timeout or parser failure. Its C setup calls are checked before launch. The existing ProcessRunner.swift, including the other session's login-shell PATH hunk, is untouched. The Wizard supplies that PATH through the existing environment helper, then the adapter filters inherited environment keys.

Private 0700 per-run directories hold 0600 configuration files and the controlled cwd. Cleanup follows process and endpoint drain. Tokens appear only in Claude/Gemini configuration or the Codex child's `CLIPBUILDER_MCP_TOKEN` variable, never argv. CLI stdout is incrementally framed as bounded JSONL before UTF-8 decoding; queued provider events are bounded too. Progress text is redacted at complete-line/final boundaries so a secret split across deltas is not exposed. The server is the authority for typed tool outcome events; provider tool observations are used only to detect confinement violations. Claude success also requires a startup inventory containing only the allowed Builder tools; missing or unconfined inventories refuse the run.

- **Claude enabled.** Preserves real HOME/Keychain subscription lookup and only the intended API-key/OAuth environment variables. Uses D4's exact base flags plus empty setting sources, explicit hook/plugin settings, restricted mode, disabled skills, an explicit system prompt, no session persistence and partial messages. No bare/safe/bypass mode. These added settings follow the installed help and [Claude settings documentation](https://code.claude.com/docs/en/settings). Their combination still needs the real-client negative suite below; the phase 1c happy-path pass does not certify the new combination.
- **Codex disabled.** Its saved 0.153.4 help does not document the per-server tool approval keys. The launch template uses the documented D4 base flags, read-only/never, a controlled cwd, child-token environment and server timeout settings. No guessed approval keys were added. Scoped approvals and effective native-tool confinement must be confirmed and real-client negative tests must pass before enabling it.
- **Gemini disabled.** The launch template has the isolated CLI home, settings, policy and optional child API-key variable. Enabling requires an app credential-provisioning route (e.g. a securely obtained key passed only to the child, or an explicit secure OAuth route in the isolated home), followed by real-client transport, parser and policy/confinement tests. Copying the user's OAuth files or assuming an empty home is authenticated is not implemented.

No database migration is needed. Existing `builder_runs` columns already hold provider, model, timing, summary, Library effects and structured events. The Wizard writes the completed/failed audit before Apply, then existing SQL status transitions retain that data through Apply/Discard. Database schema remains 14.

## Validation and remaining build checks

Performed without xcodebuild:

- `plutil -lint` accepted the edited project; `git diff --check` passed.
- Swift parsing of changed sources/tests, with and without DEBUG.
- Swift 6 language-mode typechecks with default MainActor isolation and macOS 26 target for new service files against the locally resolved MCP module and previously built app types. Small bridges represented the phase 2b session APIs missing from that older app module; this is not a full app build.
- A standalone helper executable passed split UTF-8/final parsing, cwd/environment isolation, stderr-tail bounds, descendant-group cleanup and cancellation using the actual new ProcessRunner implementation.
- Installed `claude auth status --help` confirms the `--json` option used by the real suite's authentication probe.

Not run: full Xcode build, Swift Testing macro expansion/execution, Wizard UI, or authenticated model calls. The focused typechecks found no remaining new Swift/SDK API errors, but cannot validate whole-app integration or test-host linking. In particular, verify that the app-only MCP product is visible/linkable to the hosted tests importing MCP; no package dependency was added to either test target.

Run `MCPServerTests`, `BuilderAgentRunTests`, `WizardSheetModelTests` and the existing Script/commit/prerequisite suites, then the full suite. `BuilderClaudeClientTests` is separate and uses a real authenticated client against transient scratch fixtures. Its async condition skips if Claude is absent or `auth status --json` does not report `loggedIn: true`. It checks real query/mutation outcomes and tries native shell/file/web, inherited project hooks/instructions and unrelated MCP configuration. It does not touch the user's Library. Managed enterprise policy/plugin combinations and deliberately daemonized processes that escape their process group have not been certified by these tests.

## Exact project-file edits

All new object IDs are distinct from the existing VerticalCorn/BugReporterKit entries:

1. `000000000000000000000412`: `XCRemoteSwiftPackageReference`, repository `https://github.com/modelcontextprotocol/swift-sdk`, requirement `{ kind = exactVersion; version = 0.12.1; }`.
2. Add that reference to the project's `packageReferences` array.
3. `000000000000000000000413`: `XCSwiftPackageProductDependency`, product `MCP`, package reference `...412`.
4. Add that product to the **app target's** `packageProductDependencies` array.
5. `000000000000000000000411`: `PBXBuildFile` pointing at product `...413`.
6. Add that build file to the **app target's** Frameworks phase `000000000000000130000000`.

These edits are structurally complete for the requested app-only dependency. I did not run package resolution or write Package.resolved. An untracked workspace `xcshareddata/swiftpm/Package.resolved` appeared during implementation, pinning MCP 0.12.1 and its transitive dependencies; it was preserved. Synchronized source groups pick up the new Swift files automatically.

## Changed repository files

- `Clip Builder.xcodeproj/project.pbxproj`
- `ClipBuilder/Data/AppSettings.swift`
- `ClipBuilder/Services/Script/BuilderQuery.swift`
- `ClipBuilder/Services/Script/BuilderScriptSession.swift`
- `ClipBuilder/Services/Script/MCP/BuilderDocumentSummary.swift` (new)
- `ClipBuilder/Services/Script/MCP/BuilderMCPServer.swift` (new)
- `ClipBuilder/Services/Script/MCP/BuilderTools.swift` (new)
- `ClipBuilder/Services/Script/MCP/MCPHTTPHost.swift` (new)
- `ClipBuilder/Services/Script/Agent/BuilderAgentLaunch.swift` (new)
- `ClipBuilder/Services/Script/Agent/BuilderAgentLimits.swift` (new)
- `ClipBuilder/Services/Script/Agent/BuilderAgentParser.swift` (new)
- `ClipBuilder/Services/Script/Agent/BuilderAgentProvider.swift` (new)
- `ClipBuilder/Services/Script/Agent/BuilderAgentRun.swift` (new)
- `ClipBuilder/Services/Script/Agent/BuilderRunEvent.swift` (new)
- `ClipBuilder/Services/Script/Agent/ProcessRunner+Agent.swift` (new)
- `ClipBuilder/Views/Builder/BuilderWizardSheet.swift`
- `ClipBuilder/Views/Builder/WizardSheetModel.swift`
- `ClipBuilderTests/Services/Script/MCPServerTests.swift` (new)
- `ClipBuilderTests/Services/Script/BuilderAgentRunTests.swift` (new)
- `ClipBuilderTests/Services/Script/BuilderClaudeClientTests.swift` (new)
- `ClipBuilderTests/Services/Script/WizardSheetModelTests.swift`
- `docs/Scriptable-Builder-Phase3.md` (new; this report)
- `HANDOFF.md` (ignored baton)

The pre-existing protected worktree changes are not part of this implementation and were not edited. The separately appearing untracked `Clip Builder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` was also left untouched. No commit or push was made.
