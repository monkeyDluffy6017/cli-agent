# cli-agent

A Claude Code skill that routes tasks from the current coding agent to configured child CLI agents (cs, csc, Claude Code, Codex, etc.) via a PowerShell bridge script.

## Overview

`cli-agent` lets you delegate subtasks to other AI CLI tools without leaving your current session. You can say things like "让 cs 检查这个文件" or "ask codex to fix this bug", and the skill will invoke the appropriate child CLI, capture its response, and report back.

## File Structure

```
cli-agent/
├── SKILL.md            # Skill definition and behavior rules
├── cli-agents.json     # Agent configuration and aliases
├── scripts/
│   └── ask_cli.ps1    # Bridge script that invokes child CLIs
└── .runtime/           # Auto-created: session state and output files
    └── sessions.json   # Persisted session IDs per agent/workspace
```

## Preconfigured Agents

| Alias | Agent | Invocation |
|-------|-------|------------|
| `cs` | cs | `cs run --dir {workspace} --format json {prompt}` |
| `csc` | csc | `csc -p --output-format json {prompt}` |
| `claude`, `claude-code` | claude-code | `claude -p --output-format json {prompt}` |
| `codex` | codex | `codex exec --json` (prompt via stdin) |

## Usage (via Skill)

Trigger phrases (Chinese or English):

```
让 cs 检查这个文件
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
```

### Script Output

On success, the script prints:

```
session_id=<id>       # when the child CLI exposes a session id
output_path=<file>    # path to the response markdown in .runtime/
```

### Options

| Option | Alias | Description |
|--------|-------|-------------|
| `-Agent` | `-a` | Child CLI name or alias |
| `-Task` | `-t` | Task text (also first positional arg) |
| `-Workspace` | `-w` | Working directory (default: current dir) |
| `-File` | `-f` | Priority file paths (repeatable) |
| `-Session` | | Resume a specific session ID |
| `-NewSession` | `-Fresh` | Ignore saved session, start fresh |
| `-NoSession` | `-Stateless` | Run without saving session state |
| `-Model` | | Model override |
| `-Reasoning` | | Reasoning effort: `low`, `medium`, `high` |
| `-Config` | `-c` | Path to a custom JSON config |
| `-Output` | `-o` | Output file path |
| `-ReadOnly` | | Read-only sandbox mode |
| `-FullAuto` | | Full-auto mode |

## Configuration (`cli-agents.json`)

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
| `outputMode` | `text`, `generic-json`, or `codex-json` |
| `sessionIdRegex` | Regex to extract session ID from output |

### Placeholder Variables

Placeholders in arg templates are expanded at runtime:

```
{agent}        {workspace}     {task}
{prompt}       {prompt_file}   {session}
{model}        {reasoning}     {sandbox}
{output}
```

## Session Persistence

Sessions are stored in `.runtime/sessions.json`, keyed by a hash of `(agent, workspace)`. The bridge auto-resumes the last session for the same agent and workspace unless `-NewSession` or `-NoSession` is specified.
