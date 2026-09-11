#!/usr/bin/env python3
"""Human-run sessions only. Standard library, no persistent CLI configuration."""

import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
PROMPT = "Call ping_tool, then echo_tool with text 'hello', then timeline_stub, and reply with the three results verbatim."
BINARIES = {
    "claude": "/Users/abghandour/.local/bin/claude",
    "codex": "/opt/homebrew/bin/codex",
    "gemini": "/usr/local/bin/gemini",
}
MAX_LOG = 16 * 1024 * 1024
TIMEOUT = 180


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def kill_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def capture(argv, cwd, env):
    """Drain stdout+stderr together, bound bytes/time, kill descendants on exit."""
    process = subprocess.Popen(
        argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
    )
    output = bytearray()
    diagnostic = ""
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + TIMEOUT
            while selector.get_map():
                if time.monotonic() >= deadline:
                    diagnostic = "TIMEOUT: process group killed"
                    break
                for key, _ in selector.select(timeout=0.2):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    space = MAX_LOG - len(output)
                    output.extend(chunk[:space])
                    if len(chunk) > space:
                        diagnostic = "OUTPUT LIMIT: process group killed"
                        break
                if diagnostic:
                    break
            if diagnostic:
                kill_group(process)
            try:
                code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                diagnostic = "TIMEOUT: process group killed"
                kill_group(process)
                code = process.wait()
    finally:
        kill_group(process)
        process.wait()
        process.stdout.close()
    return code, output.decode("utf-8", errors="replace"), diagnostic


def main():
    if len(sys.argv) != 3:
        sys.exit("Usage: run-clients.sh PORT TOKEN")
    port_text, token = sys.argv[1:]
    if not port_text.isascii() or not port_text.isdecimal() or not 1 <= int(port_text) <= 65535:
        sys.exit("PORT must be in 1...65535")
    if not token or any(ord(c) < 33 or ord(c) > 126 for c in token):
        sys.exit("TOKEN must contain only visible ASCII characters")
    port = int(port_text)
    os.umask(0o077)
    out = ROOT / "out"
    out.mkdir(exist_ok=True)
    temp_parent = ROOT / ".tmp"
    temp_parent.mkdir(exist_ok=True)
    url = f"http://127.0.0.1:{port}/mcp"
    auth = {"Authorization": f"Bearer {token}"}
    failed = False
    # Inherit authentication for Claude/Codex; deliberately do not copy OAuth
    # files. Gemini's temporary home uses GEMINI_API_KEY (see README).
    with tempfile.TemporaryDirectory(prefix="clients-", dir=temp_parent) as temp:
        temp = Path(temp)
        for client, binary in BINARIES.items():
            log_path = out / f"{client}.log"
            if not os.access(binary, os.X_OK):
                log_path.write_text(f"SKIP: executable not installed: {binary}\n")
                print(f"{client}: skipped (not installed)")
                failed = True
                continue
            client_root = temp / client
            work = client_root / "work"
            work.mkdir(parents=True)
            env = os.environ.copy()
            # Keep user HOME/CODEX_HOME untouched; credentials may depend on them.
            # Relocate scratch writes without changing provider authentication.
            scratch = client_root / "tmp"
            scratch.mkdir()
            env["TMPDIR"] = str(scratch)
            env.pop("CLIPBUILDER_MCP_TOKEN", None)
            if client == "claude":
                config = client_root / "mcp.json"
                write_json(config, {"mcpServers": {"clipbuilder": {
                    "type": "http", "url": url, "headers": auth,
                }}})
                argv = [binary, "-p", PROMPT, "--output-format", "stream-json", "--verbose",
                        "--tools", "", "--allowedTools", "mcp__clipbuilder__*",
                        "--mcp-config", str(config), "--strict-mcp-config",
                        "--permission-mode", "dontAsk"]
            elif client == "codex":
                # JSON-quoted strings are also valid TOML basic strings here.
                # These are argv values, never interpolated into a shell command.
                overrides = [
                    f"mcp_servers.clipbuilder.url={json.dumps(url)}",
                    'mcp_servers.clipbuilder.bearer_token_env_var="CLIPBUILDER_MCP_TOKEN"',
                ]
                (client_root / "overrides.toml").write_text("\n".join(overrides) + "\n")
                env["CLIPBUILDER_MCP_TOKEN"] = token
                argv = [binary, "-a", "never", "exec", "--json", "--ephemeral",
                        "--ignore-user-config", "--ignore-rules", "--sandbox", "read-only",
                        "--skip-git-repo-check"]
                for value in overrides:
                    argv += ["-c", value]
                argv += [PROMPT]
            else:
                gemini_root = client_root / "home"
                policy = client_root / "policy.toml"
                shutil.copyfile(ROOT / "gemini-policy.toml", policy)
                write_json(gemini_root / ".gemini" / "settings.json", {
                    "mcpServers": {"clipbuilder": {"httpUrl": url, "headers": auth}},
                    "hooksConfig": {"enabled": False},
                    "security": {"auth": {"selectedType": "gemini-api-key"}},
                })
                env["GEMINI_CLI_HOME"] = str(gemini_root)
                argv = [binary, "-p", PROMPT, "--output-format", "stream-json",
                        "--allowed-mcp-server-names", "clipbuilder",
                        "--approval-mode", "default", "--policy", str(policy)]
                if not env.get("GEMINI_API_KEY"):
                    log_path.write_text("BLOCKED: set GEMINI_API_KEY; the temporary Gemini home has no OAuth credentials.\n")
                    print("gemini: blocked (GEMINI_API_KEY missing)")
                    failed = True
                    continue
            print(f"{client}: starting; output -> {log_path}", flush=True)
            started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            try:
                code, text, diagnostic = capture(argv, work, env)
            except OSError as error:
                code, text, diagnostic = 1, "", str(error)
            # Never write the bearer token or inherited API credentials to logs.
            for secret in [token, env.get("GEMINI_API_KEY"), env.get("ANTHROPIC_API_KEY"), env.get("OPENAI_API_KEY")]:
                if secret:
                    text = text.replace(secret, "[REDACTED]")
                    diagnostic = diagnostic.replace(secret, "[REDACTED]")
            log_path.write_text(f"# {client} started={started}\n{text}\n# exit={code} {diagnostic}\n")
            print(f"{client}: exit={code}; inspect tool events and server log (exit 0 alone is not a pass)")
            failed |= code != 0 or bool(diagnostic)
    return int(failed)


if __name__ == "__main__":
    # Convert SIGTERM into orderly Python unwinding so child groups/configs clean up.
    def terminated(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminated)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
