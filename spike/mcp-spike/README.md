# Phase 1c: MCP transport spike

Throwaway, standalone macOS 15+ Swift package for revision 2 of
`docs/Scriptable-Builder-Plan.md`, Phase 1c / D3 / D4. No app target dependency,
Library access, application edits, or production transport commitment.

**Review status (September 10, 2026):** installed CLI help was actually run and
saved under `evidence/`. Swift source parsing, Bash syntax, Python syntax, and
TOML parsing passed. **Not built; no server or real client session was run.**
The task explicitly prohibited builds/client sessions in this review. Swift
6.4 is installed, but shell network access also failed with
`curl: (6) Could not resolve host: api.github.com`; package resolution was not
attempted because dependencies cannot be fetched. Parsing is not typechecking
or proof that the package compiles. A reviewer must build and run the checks below.

## SDK pin and transport decision

`Package.swift` pins **`modelcontextprotocol/swift-sdk` exactly `0.12.1`**.
It is the newest published tagged release shown on the upstream
[release list](https://github.com/modelcontextprotocol/swift-sdk/releases).
Its [Versioning.swift](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/Sources/MCP/Base/Versioning.swift)
explicitly includes `2025-06-18` in `Version.supported`, alongside newer and older
versions. This is compatibility evidence from the pinned tag, not an assumption
based on SDK main. Transitive dependency versions remain for the reviewer's
first resolution to select and capture in `Package.resolved`.

**SDK-native Streamable HTTP transport, with a custom socket hosting adapter.**
This release DOES provide server-side HTTP transports:
[`StatelessHTTPServerTransport`](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/Sources/MCP/Base/Transports/HTTPServer/StatelessHTTPServerTransport.swift)
and `StatefulHTTPServerTransport`. We use the former: JSON responses, empty
202 notifications, no session IDs or SSE, GET/DELETE 405. It is framework-agnostic
and does not bind a listening socket. `HTTPHost` supplies that missing hosting
layer using Apple's Network framework and converts requests/responses to the
SDK's `HTTPRequest`/`HTTPResponse`. Tool registration, dispatch, result encoding,
ping and cancellation handling use `MCP.Server`.

The SDK normally negotiates its latest supported version when necessary. This
spike replaces its `Initialize` handler **after `server.start()` and before
listening** to return exactly `2025-06-18`, `serverInfo`, and `capabilities.tools`.
Subsequent POSTs must send `MCP-Protocol-Version: 2025-06-18`; absent or different
headers get 400. Initial client proposals may be newer; they get the pinned
version back and must decide whether they support it.

HTTP guards apply before dispatch, including GET: exact bearer token (401 with
challenge), exact `Host: 127.0.0.1:PORT` (421), absent Origin or exact
`http://127.0.0.1:PORT` (otherwise 403), exact `/mcp` (otherwise 404). No CORS
allowance. SDK validates POST Content-Type and Accept. All complete request lines
are logged to stderr, escaped and token-redacted, followed by known MCP method
and tool names and HTTP response status. Bodies/headers are not logged.

Deliberate spike limits:

- One request per TCP connection; the server sends `Connection: close`. Supports
  Content-Length and chunked bodies, but rejects trailers and Expect/100-continue.
- 16 KiB headers, 1 MiB body, 32 open connections, 30-second whole-request deadline.
  A deadline stops the whole spike with exit 1 to release any SDK response waiter.
- Only one JSON-RPC call is admitted at a time (overlap returns 409). Notifications
  can still pass. This avoids cross-client request-ID collisions in the shared
  stateless SDK transport; run clients sequentially.
- Stateless lifecycle: initialized notifications are accepted, but there is no
  per-client initialization state or session ID. Repeated initialize is supported
  so all three clients can run against one server. This does **not** test strict
  lifecycle enforcement, multi-client concurrency, SSE, or resumable sessions.
- SIGINT/SIGTERM cancels the listener, stops SDK admission/transport, releases
  waiters and closes connections. The fixed tools have no asynchronous side effects.
  Cancellation delivery for long-running product work remains untested.

## Build and run the server (reviewer)

Requires macOS 15+, Swift 6+, network access to resolve the SDK, and Python 3 for
the client harness. From the repository root:

```sh
cd spike/mcp-spike
swift package resolve
swift build
mkdir -p out
PORT=8765
TOKEN="$(openssl rand -hex 32)"
.build/debug/mcp-spike "$PORT" "$TOKEN" 2>out/server.log &
SERVER_PID=$!
```

Wait for `Listening http://127.0.0.1:8765/mcp protocol=2025-06-18 SDK=0.12.1` in
`out/server.log`. Port conflicts fail startup. Keep this terminal for the next
commands so `PORT`, `TOKEN` and `SERVER_PID` are available. The required server
token argv is visible in local process inspection; use a fresh disposable token.

## Run all installed clients (reviewer)

Authenticate Claude and Codex beforehand using your intended account route.
Their authentication lookup is preserved; no global CLI configuration is edited.
For this spike, provision **`GEMINI_API_KEY`** in the environment without putting
it in the repository. `GEMINI_CLI_HOME` relocates OAuth credential lookup as well
as settings, so a blank temporary home is not signed in. The harness explicitly
chooses `gemini-api-key` auth and does not copy your OAuth files. Without a key,
Gemini is recorded as BLOCKED and the overall run is unsuccessful.

```sh
./run-clients.sh "$PORT" "$TOKEN"
kill -TERM "$SERVER_PID"
wait "$SERVER_PID"
```

The shell entry point delegates to the standard-library Python harness. It
creates private per-client configurations and working directories under `.tmp/`,
runs the exact same prompt sequentially, and removes configs on exit, Ctrl-C or
SIGTERM. SIGKILL cannot run cleanup; inspect/remove stale `.tmp/clients-*` after
such a termination. Credentials are never copied from global config. Existing
HOME/CODEX_HOME and provider auth environment are inherited, so this harness is
not a hermetic environment or an instruction/plugin isolation claim.

Each child has stdin `/dev/null`, a 180-second timeout, a 16 MiB combined output
limit, and its own process group, killed on cleanup. Missing binaries get SKIP;
authentication/launch errors do not stop the other clients from being attempted.
`out/claude.log`, `out/codex.log`, and `out/gemini.log` contain merged
stdout/stderr, UTC start time, exit status and timeout/limit diagnostics. Logs
are overwritten on each run, private, and bearer/API-key redacted. The combined
logs are intentionally not pure JSONL; inspect the embedded provider events.

Every client receives precisely:

> Call ping_tool, then echo_tool with text 'hello', then timeline_stub, and reply with the three results verbatim.

## Actual help versus D4

Checked the specified absolute binaries, **not** alternate PATH installations:

| Client | Installed version | Commands actually run | Differences in requested flags |
| --- | --- | --- | --- |
| Claude | 2.1.268 | `/Users/abghandour/.local/bin/claude --help` | None. `-p`, stream-json, verbose, tools, allowedTools, mcp-config, strict-mcp-config and `dontAsk` are all advertised. |
| Codex | 0.153.4 | `/opt/homebrew/bin/codex --help` and `codex exec --help` | None. exec/json/ephemeral/ignore-user-config/ignore-rules and dotted `-c` TOML overrides are advertised. |
| Gemini | 0.53.1 | `/usr/local/bin/gemini --help` | None. prompt, stream-json, allowed-mcp-server-names, default approval and policy are advertised. |

No requested flag was removed, renamed, or substituted. The recorded help also
reveals semantic limits worth preserving:

- Claude says `--tools ""` disables the built-in set and `--strict-mcp-config`
  restricts MCP configuration. These say nothing about suppressing all inherited
  instructions, plugins and hooks. This harness keeps the requested D4 baseline;
  it does not add `--safe-mode`, which advertises disabling MCP too.
- Codex says `--ignore-user-config` skips `config.toml` but preserves auth lookup;
  `--ignore-rules` skips execpolicy `.rules`, **not AGENTS.md**. The script adds
  help-supported global `-a never`, `--sandbox read-only`, and
  `--skip-git-repo-check` for the controlled working directory, consistent with
  D4's prose. These are additions, not replacements for unavailable flags.
  Neither help advertises a flag equivalent to Claude's `--tools ""`.
  Dotted MCP config keys are not individually documented by help; their runtime
  acceptance and scoped MCP approval behavior remain live-test requirements.
- Gemini describes `default` as prompting for approval. The provided policy
  denies all tools at user priority 900 and allows only the three named tools
  from `clipbuilder` at priority 999. The installed bundle's `PolicyRuleSchema`
  confirms `mcpName`, array `toolName`, decisions, and integer priorities 0–999;
  its loader qualifies tool names with the server. User priorities are below
  admin policy; do not weaken policy if a managed rule blocks this run.
  `--allowed-tools` is deprecated, but D4 correctly uses `--policy` already.
  The temporary settings also disable hooks with `hooksConfig.enabled=false`.

The installed Gemini implementation was read at
`/usr/local/lib/node_modules/@google/gemini-cli/bundle/chunk-2NH5AG3B.js`
(home lookup near 251979, policy schema near 362742, loader near 362992), and
`gemini-HMY2YBVR.js` (hooks setting near 8631). These config/policy semantics
are source inspection findings, **not additional CLI help claims**.

## What counts as a pass

Use a fresh server log and one sequential harness run. For **each client**:

1. Match the log's start time/run order with server requests. See `MCP initialize`
   and `MCP notifications/initialized`; initialization returns the fixed version,
   server info and tools capability. An optional GET returning 405 is expected.
2. See `MCP tools/list` and exactly three successful `MCP tools/call` entries in
   order: `ping_tool`, `echo_tool`, `timeline_stub`. Tool retries/additional calls
   are findings, not silently treated as a pass. The server should show nine
   calls total for all three clients. Note any extra initialization attempts.
3. Check actual client tool result events plus final output for `pong`, `hello`,
   and the JSON below. Exit 0 or a model claiming success is insufficient. If a
   client omits tool-result payloads from its stream, document that evidence gap.
4. Require clean termination with no timeout, auth error, policy refusal,
   unintended tool use, or orphan process. A skipped/blocked client is not a pass.

`timeline_stub` returns a text content block containing exactly:

```json
{"id":"timeline-stub","duration":3,"tracks":[{"id":"main","clips":[{"id":"clip-1","start":0,"duration":3,"source":"fixture.mov"}]}]}
```

### Confinement checklist (separate release gate)

- [ ] Inspect startup tool inventory and tool-use events: only the three
  `clipbuilder` tools should be usable. Does any client also attempt built-in
  shell, filesystem read/write, web, agent/subagent, or discovery tools?
- [ ] In separate negative-test runs, ask for shell execution, reading a harmless
  canary file, writing a scratch file, fetching a URL, and calling an unrelated
  MCP server. Use disposable fixtures, never the Library or secrets. Record both
  attempted and executed tools. Refusal prose alone is not enforcement evidence.
- [ ] Specifically test Codex file reads: a read-only sandbox still permits reads.
  Its listed flags do not establish native tool removal. Keep production Codex
  disabled until an effective confinement configuration is proven.
- [ ] Check Gemini policy load errors, effective rule precedence, server-qualified
  matching and built-in denial. The happy-path prompt does not prove the deny rule.
- [ ] Inspect inherited instructions, user/system settings, skills, plugins,
  extensions, hooks, custom commands, and unrelated servers. Strict MCP config
  and ignore-rules are not full customization suppression. The working directories
  are beneath this repo, so ancestor instruction discovery remains a test concern.
- [ ] Check logs and temporary files for credentials, confirm cleanup, and inspect
  process groups after interruption/timeout. The server log cannot reveal tools
  executed internally by clients, so inspect client events and effects too.
- [ ] Stop the server during a client run: the client must fail cleanly. Restart
  with a new token and verify the old token no longer works.

### HTTP checks before a separate client run

Run these against a scratch server; restart/clear the server log before counting
client calls. For requests below, no model invocation is involved:

```sh
# Missing auth: 401. Authorized GET: 405 and Allow: POST.
curl -i "http://127.0.0.1:$PORT/mcp"
curl -i -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/mcp"
# Unexpected browser Origin: 403, including for GET.
curl -i -H "Authorization: Bearer $TOKEN" -H 'Origin: https://unexpected.example' \
  "http://127.0.0.1:$PORT/mcp"
# Initialize: 200 JSON, protocolVersion exactly 2025-06-18 even if proposing newer.
curl -i -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual","version":"1"}}}' \
  "http://127.0.0.1:$PORT/mcp"
# Initialized notification: 202, Content-Length: 0, no JSON-RPC body.
curl -i -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -H 'MCP-Protocol-Version: 2025-06-18' \
  --data '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  "http://127.0.0.1:$PORT/mcp"
```

Also inspect wrong bearer (401), wrong Host (421), wrong path (404), unsupported
or missing post-initialization protocol header (400), malformed JSON (400), unknown
tool/invalid echo arguments (JSON-RPC error), and `ping` (`result: {}`). These HTTP
checks complement the real clients; they cannot establish client confinement.
