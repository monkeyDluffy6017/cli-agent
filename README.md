# cli-agent

A Claude Code skill that routes tasks from the current coding agent to configured child CLI agents (cs, csc, Claude Code, OpenCode, Codex, etc.) via the bundled bridge scripts.

## Overview

`cli-agent` lets you delegate subtasks to other AI CLI tools without leaving your current session. You can say things like "让 cs 检查这个文件" or "ask codex to fix this bug", and the skill will invoke the appropriate child CLI, capture its response, and report back.

## File Structure

```
cli-agent/
├── SKILL.md            # Skill definition and behavior rules
├── cli-agents.json     # Agent configuration and aliases
├── config/
│   └── opencode-full-permissions.json
├── scripts/
│   ├── ask_cli.ps1    # Windows PowerShell bridge
│   └── ask_cli.sh     # Linux/macOS bash bridge
└── .runtime/           # Auto-created: session state and output files
    └── sessions.json   # Persisted session IDs per agent/workspace
```

## Preconfigured Agents

| Alias | Agent | Invocation |
|-------|-------|------------|
| `cs` | cs | `cs run --dir {workspace} --format json {prompt}` with bundled OpenCode permissions |
| `csc` | csc | `csc -p --permission-mode bypassPermissions --output-format json {prompt}` |
| `claude`, `claude-code` | claude-code | `claude -p --permission-mode bypassPermissions --output-format json {prompt}` |
| `opencode` | opencode | `opencode run --dir {workspace} --format json --dangerously-skip-permissions {prompt}` |
| `codex` | codex | `codex --sandbox danger-full-access --ask-for-approval never exec --json` (prompt via stdin) |

The bundled configuration defaults these agents to full-auto/high-permission mode. For CS/OpenCode, the bridge sets `OPENCODE_CONFIG` and inlines the same file through `OPENCODE_CONFIG_CONTENT` so the runtime permission override comes from `config/opencode-full-permissions.json`.

## Usage (via Skill)

Trigger phrases (Chinese or English):

```
让 cs 检查这个文件
让 opencode 检查这个文件
让 codex 修复这个 bug
ask claude code to review this repo
让 csc 说 hello
```

To start a fresh session instead of resuming the last one:

```
新会话，让 cs 做 X
```

To run without saving session state:

```
一次性，让 codex 做 X
```

## Bridge Script

The bridge script can also be called directly:

```powershell
# Basic usage
& ./scripts/ask_cli.ps1 -Agent cs "say hi"
& ./scripts/ask_cli.ps1 -Agent codex "fix the test failures"

# Run in a specific workspace
& ./scripts/ask_cli.ps1 -Agent cs "review the code" -Workspace C:\MyProject

# Attach priority files
& ./scripts/ask_cli.ps1 -Agent csc "check this" -File src\main.py

# Force a fresh session
& ./scripts/ask_cli.ps1 -Agent codex "start fresh" -NewSession

# One-off run (no session saved)
& ./scripts/ask_cli.ps1 -Agent cs "quick check" -NoSession

# Use a specific model
& ./scripts/ask_cli.ps1 -Agent claude-code "refactor this" -Model claude-opus-4-7

# Read prompt from a UTF-8 file (recommended for long or non-ASCII prompts)
& ./scripts/ask_cli.ps1 -Agent codex -PromptFile C:\Temp\review-prompt.txt

# Pipe prompt in
Get-Content prompt.txt -Raw -Encoding UTF8 | & ./scripts/ask_cli.ps1 -Agent codex
```

### Non-ASCII prompts on Windows

The bridge forces the child CLI's stdin to UTF-8 (no BOM) and reads `-PromptFile` as UTF-8. For Chinese/emoji prompts:

- **Prefer `-PromptFile`** — caller writes the prompt to a UTF-8 file and passes the path. Avoids every encoding pitfall along the way.
- **Use the PowerShell tool, not the Bash tool**, when invoking from another agent. The Claude Code Bash tool on Windows can transcode stdin through the system code page (GBK) before it reaches PowerShell, corrupting bytes before the bridge ever sees them.

### Script Output

On success, the script prints:

```
session_id=<id>          # when the child CLI exposes a session id
output_path=<file>       # path to the response markdown in .runtime/
transcript_path=<file>   # path to normalized JSONL transcript ({ts,type,text})
<summary>
...final response text...
</summary>
```

The `<summary>` block lets parent CLIs (opencode, codex, etc.) that only capture stdout see the child's final answer without reading any file. Pass `-NoSummary` to suppress it. The JSONL transcript preserves the full child stream for auditing or replay.

`transcript_path` is only printed if the JSONL was successfully written — callers must not assume it always appears.

On failure (`exit != 0`): the script writes captured STDOUT/STDERR to `output_path` and still emits `transcript_path` if the JSONL was written. It does **not** emit `session_id` or `<summary>` in this case.

### Runtime Cleanup

The bridge keeps runtime output files for 3 days by default. On each run it removes old `*.md`, `*.jsonl`, and `*.txt` files directly under `.runtime/`, while preserving `sessions.json` for session resume.

> **Note:** prompts, responses, and transcript JSONL are all written under `.runtime/` in plaintext. Don't pass secrets you wouldn't want on disk — the bridge does no redaction.

### Options

| Option | Alias | Description |
|--------|-------|-------------|
| `-Agent` | `-a` | Child CLI name or alias |
| `-Task` | `-t` | Task text (also first positional arg, or via pipeline) |
| `-PromptFile` | `-pf` | Read prompt body from a UTF-8 file (recommended on Windows for non-ASCII prompts) |
| `-Workspace` | `-w` | Working directory (default: current dir) |
| `-File` | `-f` | Priority file paths (repeatable) |
| `-Session` | | Resume a specific session ID |
| `-NewSession` | `-Fresh` | Ignore saved session, start fresh |
| `-NoSession` | `-Stateless` | Run without saving session state |
| `-Model` | | Model override |
| `-Reasoning` | | Reasoning effort: `low`, `medium`, `high` |
| `-Config` | `-c` | Path to a custom JSON config |
| `-Output` | `-o` | Output file path |
| `-NoSummary` | | Suppress the `<summary>` block on stdout |
| `-ReadOnly` | | Read-only sandbox mode |
| `-FullAuto` | | Full-auto mode for custom configs; enabled by default in the bundled agent config |

## Configuration (`cli-agents.json`)

Top-level fields:

| Field | Description |
|-------|-------------|
| `defaultAgent` | Agent used when `-Agent` is omitted |
| `runtimeDir` | Directory for response files, transcripts, and session state |
| `runtimeRetentionDays` | Days to keep runtime `*.md`, `*.jsonl`, and `*.txt` files; defaults to `3` |

Each agent entry supports:

| Field | Description |
|-------|-------------|
| `command` | Executable name or absolute path |
| `windowsNativePackage` | Optional npm package to scan for a Windows native binary |
| `windowsNativeBinary` | Native binary filename used with `windowsNativePackage` |
| `invocation` | `direct` or `shell` |
| `promptMode` | `stdin`, `argument`, or `file` |
| `newArgs` | Arguments for a new session |
| `resumeArgs` | Arguments for resuming a session |
| `promptArgs` | Prompt-specific arguments |
| `modelArgs` | Model override arguments |
| `defaultFullAuto` | Apply `fullAutoArgs` without requiring `-FullAuto` |
| `fullAutoArgs` | Permission/autonomy arguments for full-auto runs |
| `permissionArgsPosition` | Use `beforeBase` when permission args must precede `newArgs`/`resumeArgs` |
| `environment` | Environment variables to set on the child process; values support placeholders |
| `environmentFiles` | Environment variables whose values are loaded from UTF-8 files; paths support placeholders |
| `outputMode` | `text`, `generic-json`, or `codex-json` |
| `sessionIdRegex` | Regex to extract session ID from output |

### Placeholder Variables

Placeholders in arg templates are expanded at runtime:

```
{agent}        {skill_root}    {workspace}
{task}         {prompt}        {prompt_file}
{session}      {model}         {reasoning}
{sandbox}      {output}
```

## Session Persistence

Sessions are stored in `.runtime/sessions.json`, keyed by a hash of `(agent, workspace)`. The bridge auto-resumes the last session for the same agent and workspace unless `-NewSession` or `-NoSession` is specified.
