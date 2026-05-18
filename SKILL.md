---
name: cli-agent
description: Route explicit requests from the current coding agent to configured child CLIs. Use when the user asks Codex or Claude Code to have cs, csc, Claude Code, claude-code, claude, or codex do something, for example "让 cs say hi", "让 csc 检查这个文件", "让 claude code 检查这个文件", "让 codex 修复这个 bug", or "ask codex to review this repo". The skill extracts the requested child CLI and task, runs the configured bridge script, then reports the child CLI output.
---

## Behavior

- Use the bundled `scripts/ask_cli.ps1` bridge. Do not call `cs`, `csc`, `claude`, or `codex` directly unless the bridge itself is broken.
- When the user says `让 cs ...`, `ask cs to ...`, or similar, call agent `cs`.
- When the user says `让 csc ...`, `ask csc to ...`, or similar, call agent `csc`.
- When the user says `让 claude code ...`, `ask claude-code to ...`, `让 claude ...`, or similar, call agent `claude-code`.
- When the user says `让 codex ...`, `ask codex to ...`, or similar, call agent `codex`.
- Pass only the child task to the child CLI. For `让 cs say hi`, send `say hi`, not the full routing phrase.
- By default, let the bridge auto-resume the last saved session for the same agent and workspace.
- If the user says `新会话`, `不要续聊`, `不接着上次`, or similar, pass `-NewSession`.
- If the user says `一次性`, `不要保存 session`, `不要作为后续上下文`, or similar, pass `-NoSession`.
- After the script succeeds, read `output_path` and report the child CLI response to the user.
- If the requested CLI is not installed or not authenticated, report the command error and the configured command name.

## Command

Resolve the script path relative to this skill directory:

```powershell
& ./scripts/ask_cli.ps1 -Agent cs "say hi"
& ./scripts/ask_cli.ps1 -Agent csc "say hi"
& ./scripts/ask_cli.ps1 -Agent claude-code "say hi"
& ./scripts/ask_cli.ps1 -Agent codex "say hi"

# Force a fresh session and save it as the new active session
& ./scripts/ask_cli.ps1 -Agent codex "say hi" -NewSession

# One-off run: do not resume and do not save the resulting session
& ./scripts/ask_cli.ps1 -Agent codex "say hi" -NoSession
```

Useful options:

- `-Workspace <path>`: run the child CLI in a target workspace.
- `-File <path>`: add priority file hints to the prompt; repeat for multiple files.
- `-Model <name>`: pass a model override when the configured agent supports it.
- `-Session <id>`: resume when the configured child CLI supports it.
- `-NewSession`: ignore the saved session and start a fresh one; save the new session if the child CLI returns an id.
- `-NoSession`: run without resuming or saving session state.
- `-Config <path>`: use a different JSON config.

The script prints:

```text
session_id=<id>
output_path=<path>
```

`session_id` is printed when the child CLI exposes one. The bridge stores it in `.runtime/sessions.json` and auto-resumes it on later calls for the same agent and workspace.

## Configuration

The bridge reads `cli-agents.json` next to this `SKILL.md`.

Preconfigured agents:

- `cs`: runs `cs run --dir {workspace} --format json {prompt}`.
- `csc`: runs `csc -p --output-format json {prompt}`.
- `claude-code`: runs `claude -p --output-format json {prompt}`.
- `codex`: runs `codex exec --cd {workspace} --skip-git-repo-check --json` and sends the prompt on stdin.

Aliases:

- `cs` routes to `cs`.
- `csc` routes to `csc`.
- `claude`, `claude code`, and `claude-code` route to `claude-code`.
- `codex` routes to `codex`.

Each agent can define:

- `command`: executable name or absolute path.
- `invocation`: `direct` or `shell`.
- `promptMode`: `stdin`, `argument`, or `file`.
- `newArgs`: arguments for a new task.
- `resumeArgs`: arguments for continuing a previous session.
- `promptArgs`: prompt-related arguments.
- `modelArgs`: optional model override arguments.
- `outputMode`: `text` for plain stdout or `codex-json` for Codex-style JSON event streams.
- `sessionIdRegex`: optional regex where capture group 1 is the session id.

Supported placeholders:

```text
{agent}
{workspace}
{task}
{prompt}
{prompt_file}
{session}
{model}
{reasoning}
{sandbox}
{output}
```
