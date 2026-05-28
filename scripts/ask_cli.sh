#!/usr/bin/env bash
# Linux/macOS bash bridge — feature parity with scripts/ask_cli.ps1.
# Requires: bash 4+, jq, coreutils.
set -uo pipefail

# ---------- defaults ----------
TASK=""
TASK_TEXT=""
PROMPT_FILE_IN=""
AGENT=""
CONFIG=""
WORKSPACE="$(pwd)"
FILES=()
SESSION=""
NEW_SESSION=0
NO_SESSION=0
MODEL=""
REASONING="medium"
SANDBOX=""
READ_ONLY=0
FULL_AUTO=0
OUTPUT=""
NO_SUMMARY=0

usage() {
    cat <<'EOF'
Usage:
  ask_cli.sh <task> [options]
  ask_cli.sh -a <agent> -t <task> [options]

Task input:
  <task>                      First positional argument is the task text
  -t, --task <text>           Alias for positional task
  --pf, --prompt-file <path>  Read prompt body from a UTF-8 file
  (task can also be piped in via stdin)

Agent selection:
  -a, --agent <name>          Configured child CLI name or alias
  -c, --config <path>         JSON config path (default: ../cli-agents.json)

File context:
  -f, --file <path>           Priority file (repeatable, or comma-separated)

Multi-turn:
  --session <id>              Resume a previous session
  --new-session               Ignore saved session and start fresh
  --no-session                Do not resume or save any session

Options:
  -w, --workspace <path>      Workspace dir (default: cwd)
  --model <name>              Model override
  --reasoning <low|medium|high>  (default: medium)
  --sandbox <mode>            Sandbox mode override
  --read-only                 Read-only mode
  --full-auto                 Full-auto mode
  -o, --output <path>         Output file path
  --no-summary                Suppress <summary> block on stdout
  -h, --help                  Show this help
EOF
}

# ---------- arg parsing ----------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help|-Help) usage; exit 0 ;;
        -t|--task|-Task)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for $1" >&2; exit 1; }
            TASK_TEXT="$2"; shift 2 ;;
        -pf|--pf|--prompt-file|-PromptFile)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for $1" >&2; exit 1; }
            PROMPT_FILE_IN="$2"; shift 2 ;;
        -a|--agent|-Agent)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for $1" >&2; exit 1; }
            AGENT="$2"; shift 2 ;;
        -c|--config|-Config)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for $1" >&2; exit 1; }
            CONFIG="$2"; shift 2 ;;
        -w|--workspace|-Workspace)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for $1" >&2; exit 1; }
            WORKSPACE="$2"; shift 2 ;;
        -f|--file|-File)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for $1" >&2; exit 1; }
            IFS=',' read -ra _files <<< "$2"
            for f in "${_files[@]}"; do FILES+=("$f"); done
            shift 2 ;;
        --session|-Session)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for $1" >&2; exit 1; }
            SESSION="$2"; shift 2 ;;
        --new-session|-NewSession|-Fresh) NEW_SESSION=1; shift ;;
        --no-session|-NoSession|-Stateless) NO_SESSION=1; shift ;;
        --model|-Model)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for $1" >&2; exit 1; }
            MODEL="$2"; shift 2 ;;
        --reasoning|-Reasoning)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for $1" >&2; exit 1; }
            REASONING="$2"; shift 2 ;;
        --sandbox|-Sandbox)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for $1" >&2; exit 1; }
            SANDBOX="$2"; shift 2 ;;
        --read-only|-ReadOnly) READ_ONLY=1; shift ;;
        --full-auto|-FullAuto) FULL_AUTO=1; shift ;;
        -o|--output|-Output)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for $1" >&2; exit 1; }
            OUTPUT="$2"; shift 2 ;;
        --no-summary|-NoSummary) NO_SUMMARY=1; shift ;;
        --) shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
        -*) echo "[ERROR] Unrecognized argument: $1" >&2; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if (( ${#POSITIONAL[@]} > 1 )); then
    echo "[ERROR] Unrecognized argument: ${POSITIONAL[1]}" >&2
    exit 1
fi
if [[ -z "$TASK" && ${#POSITIONAL[@]} -gt 0 ]]; then
    TASK="${POSITIONAL[0]}"
fi
if [[ -z "$TASK" && -n "$TASK_TEXT" ]]; then
    TASK="$TASK_TEXT"
fi

# Read task from prompt file if requested
if [[ -z "$TASK" && -n "$PROMPT_FILE_IN" ]]; then
    if [[ ! -f "$PROMPT_FILE_IN" ]]; then
        echo "[ERROR] PromptFile does not exist: $PROMPT_FILE_IN" >&2
        exit 1
    fi
    TASK="$(cat "$PROMPT_FILE_IN")"
fi

# Read from stdin if no task and stdin is piped
if [[ -z "$TASK" && ! -t 0 ]]; then
    TASK="$(cat)"
fi

# ---------- validation ----------
if (( NEW_SESSION && NO_SESSION )); then
    echo "[ERROR] --new-session/-NewSession and --no-session/-NoSession cannot be used together." >&2
    exit 1
fi
if [[ -n "$SESSION" ]] && (( NEW_SESSION || NO_SESSION )); then
    echo "[ERROR] --session/-Session cannot be combined with --new-session/-NewSession or --no-session/-NoSession." >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "[ERROR] 'jq' is required but not installed." >&2; exit 1; }

# ---------- resolve script root / config ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "$CONFIG" ]]; then
    CONFIG="$SKILL_ROOT/cli-agents.json"
fi
if [[ ! -f "$CONFIG" ]]; then
    echo "[ERROR] Config file does not exist: $CONFIG" >&2
    exit 1
fi
CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"

# ---------- agent resolution ----------
if [[ -z "$AGENT" ]]; then
    AGENT="$(jq -r '.defaultAgent // ""' "$CONFIG")"
fi
if [[ -z "$AGENT" ]]; then
    echo "[ERROR] No agent specified and config.defaultAgent is empty." >&2
    exit 1
fi

# Apply alias
ALIASED="$(jq -r --arg k "$AGENT" '.aliases[$k] // ""' "$CONFIG")"
if [[ -n "$ALIASED" ]]; then
    AGENT="$ALIASED"
fi

if ! jq -e --arg k "$AGENT" '.agents[$k]' "$CONFIG" >/dev/null; then
    NAMES="$(jq -r '.agents | keys | join(", ")' "$CONFIG")"
    echo "[ERROR] Unknown agent '$AGENT'. Available agents: $NAMES" >&2
    exit 1
fi

# ---------- workspace / task validation ----------
if [[ ! -d "$WORKSPACE" ]]; then
    echo "[ERROR] Workspace does not exist: $WORKSPACE" >&2
    exit 1
fi
WORKSPACE="$(cd "$WORKSPACE" && pwd)"

# Trim + collapse whitespace
TASK="$(printf '%s' "$TASK" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [[ -z "$TASK" ]]; then
    echo "[ERROR] Request text is empty. Pass a positional arg, --task, --prompt-file, or pipe text in." >&2
    exit 1
fi

# ---------- build prompt with optional file block ----------
resolve_file_ref() {
    local raw="$1"
    local cleaned
    cleaned="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$cleaned" ]] && return
    cleaned="${cleaned%#L[0-9]*}"
    cleaned="$(printf '%s' "$cleaned" | sed -E 's/:[0-9]+(-[0-9]+)?$//')"
    case "$cleaned" in
        /*) ;;
        *) cleaned="$WORKSPACE/$cleaned" ;;
    esac
    if [[ -e "$cleaned" ]]; then
        ( cd "$(dirname "$cleaned")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$cleaned")" ) || printf '%s\n' "$cleaned"
    else
        printf '%s\n' "$cleaned"
    fi
}

PROMPT="$TASK"
if (( ${#FILES[@]} > 0 )); then
    PROMPT+=$'\n''Priority files (read these first before making changes):'
    for ref in "${FILES[@]}"; do
        resolved="$(resolve_file_ref "$ref")"
        [[ -z "$resolved" ]] && continue
        if [[ -e "$resolved" ]]; then
            PROMPT+=$'\n''- '"$resolved"' (exists)'
        else
            PROMPT+=$'\n''- '"$resolved"' (missing)'
        fi
    done
fi

# ---------- runtime / output paths ----------
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
RUNTIME_DIR_NAME="$(jq -r '.runtimeDir // ".runtime"' "$CONFIG")"
case "$RUNTIME_DIR_NAME" in
    /*) RUNTIME_DIR="$RUNTIME_DIR_NAME" ;;
    *)  RUNTIME_DIR="$SKILL_ROOT/$RUNTIME_DIR_NAME" ;;
esac
mkdir -p "$RUNTIME_DIR"

RUNTIME_RETENTION_DAYS="$(jq -r '.runtimeRetentionDays // 3' "$CONFIG")"
case "$RUNTIME_RETENTION_DAYS" in
    ''|*[!0-9-]*) RUNTIME_RETENTION_DAYS=3 ;;
esac

cleanup_runtime_dir() {
    local dir="$1" days="$2"
    [[ "$days" == -* ]] && return 0
    [[ ! -d "$dir" ]] && return 0
    find "$dir" -maxdepth 1 -type f \( -name '*.md' -o -name '*.jsonl' -o -name '*.txt' \) \
        ! -name 'sessions.json' -mtime +"$days" -exec rm -f {} + 2>/dev/null || true
}

cleanup_runtime_dir "$RUNTIME_DIR" "$RUNTIME_RETENTION_DAYS"

RUN_GUID="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%08x' $RANDOM$RANDOM)"
if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$RUNTIME_DIR/$TIMESTAMP-$AGENT-$RUN_GUID.md"
fi
_output_dir="$(dirname "$OUTPUT")"
_output_base="$(basename "$OUTPUT")"
if [[ "$_output_base" == *.* ]]; then
    TRANSCRIPT_PATH="$_output_dir/${_output_base%.*}.jsonl"
else
    TRANSCRIPT_PATH="$_output_dir/$_output_base.jsonl"
fi

sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        echo "[ERROR] Need sha256sum or shasum." >&2
        exit 1
    fi
}

SESSION_STATE_PATH="$RUNTIME_DIR/sessions.json"

key_input="$(printf '%s|%s' "$AGENT" "$WORKSPACE" | tr '[:upper:]' '[:lower:]')"
key_hash="$(printf '%s' "$key_input" | sha256_hex | cut -c1-16)"
SESSION_KEY="$AGENT-$key_hash"

EXPLICIT_SESSION=0
[[ -n "$SESSION" ]] && EXPLICIT_SESSION=1

# Auto-resume
if (( !EXPLICIT_SESSION && !NEW_SESSION && !NO_SESSION )); then
    if [[ -f "$SESSION_STATE_PATH" ]]; then
        saved="$(jq -r --arg k "$SESSION_KEY" '.sessions[$k].session_id // ""' "$SESSION_STATE_PATH" 2>/dev/null || true)"
        if [[ -n "$saved" && "$saved" != "null" ]]; then
            SESSION="$saved"
        fi
    fi
fi

# ---------- prompt temp file (for stdin & {prompt_file}) ----------
TMP_PROMPT_FILE="$(mktemp -t cli_agent_prompt.XXXXXXXX)"
TMP_STDOUT_FILE="$(mktemp -t cli_agent_stdout.XXXXXXXX)"
TMP_STDERR_FILE="$(mktemp -t cli_agent_stderr.XXXXXXXX)"
cleanup() {
    rm -f "$TMP_PROMPT_FILE" "$TMP_STDOUT_FILE" "$TMP_STDERR_FILE"
}
trap cleanup EXIT
printf '%s' "$PROMPT" > "$TMP_PROMPT_FILE"

# ---------- template expansion ----------
# Replace {var} tokens in a string with corresponding values.
expand_template() {
    local s="$1"
    s="${s//\{agent\}/$AGENT}"
    s="${s//\{skill_root\}/$SKILL_ROOT}"
    s="${s//\{workspace\}/$WORKSPACE}"
    s="${s//\{task\}/$TASK}"
    s="${s//\{prompt\}/$PROMPT}"
    s="${s//\{prompt_file\}/$TMP_PROMPT_FILE}"
    s="${s//\{session\}/$SESSION}"
    s="${s//\{model\}/$MODEL}"
    s="${s//\{reasoning\}/$REASONING}"
    s="${s//\{sandbox\}/$SANDBOX}"
    s="${s//\{output\}/$OUTPUT}"
    printf '%s' "$s"
}

# Read a string array from agent config at a given key, expand templates into ARGS_OUT global.
expand_args_from_config() {
    local key="$1"
    ARGS_OUT=()
    local count
    count="$(jq -r --arg a "$AGENT" --arg k "$key" '.agents[$a][$k] | if . == null then 0 elif type=="array" then length else 1 end' "$CONFIG")"
    [[ "$count" -eq 0 || -z "$count" ]] && return 0
    local i
    if [[ "$(jq -r --arg a "$AGENT" --arg k "$key" '.agents[$a][$k] | type' "$CONFIG")" == "array" ]]; then
        for ((i=0; i<count; i++)); do
            local raw
            raw="$(jq -r --arg a "$AGENT" --arg k "$key" --argjson i "$i" '.agents[$a][$k][$i]' "$CONFIG")"
            ARGS_OUT+=("$(expand_template "$raw")")
        done
    else
        local raw
        raw="$(jq -r --arg a "$AGENT" --arg k "$key" '.agents[$a][$k]' "$CONFIG")"
        ARGS_OUT+=("$(expand_template "$raw")")
    fi
}

agent_get() {
    jq -r --arg a "$AGENT" --arg k "$1" '.agents[$a][$k] // ""' "$CONFIG"
}

agent_bool() {
    local raw
    raw="$(jq -r --arg a "$AGENT" --arg k "$1" '.agents[$a][$k] // false | if type == "boolean" then tostring else tostring end' "$CONFIG")"
    case "${raw,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

load_environment_from_config() {
    ENV_OUT=()
    local row key raw
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        key="${row%%	*}"
        raw="${row#*	}"
        ENV_OUT+=("$key=$(expand_template "$raw")")
    done < <(jq -r --arg a "$AGENT" '.agents[$a].environment // {} | to_entries[] | [.key, (.value | tostring)] | @tsv' "$CONFIG")
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        key="${row%%	*}"
        raw="${row#*	}"
        local env_file
        env_file="$(expand_template "$raw")"
        if [[ ! -f "$env_file" ]]; then
            echo "[ERROR] Environment file for '$key' does not exist: $env_file" >&2
            exit 1
        fi
        ENV_OUT+=("$key=$(cat "$env_file")")
    done < <(jq -r --arg a "$AGENT" '.agents[$a].environmentFiles // {} | to_entries[] | [.key, (.value | tostring)] | @tsv' "$CONFIG")
}

extract_session_id_from_regex() {
    local text="$1" pattern="$2"
    local ere="${pattern//'(?:'/'('}"
    ere="${ere//'\s'/[[:space:]]}"
    ere="${ere//'\S'/[^[:space:]]}"
    ere="${ere//'\d'/[0-9]}"

    # Count non-capturing groups that appear BEFORE the first ordinary capturing group
    # in the ORIGINAL pattern. That count equals how many extra capture groups appear
    # before our target group after the (?:...)-to-(...) rewrite.
    local n=0
    local before_target="$pattern"
    local first_capture_idx="${#pattern}"
    local i=0
    local len=${#pattern}
    while (( i < len )); do
        local two="${pattern:i:2}"
        local one="${pattern:i:1}"
        if [[ "$two" == '(?' ]]; then
            i=$(( i + 2 ))
            continue
        fi
        if [[ "$one" == '(' && "$i" -gt 0 && "${pattern:i-1:1}" == '\' ]]; then
            i=$(( i + 1 ))
            continue
        fi
        if [[ "$one" == '(' ]]; then
            first_capture_idx=$i
            break
        fi
        i=$(( i + 1 ))
    done
    before_target="${pattern:0:first_capture_idx}"
    # Count "(?:" occurrences in the prefix
    local prefix="$before_target"
    while [[ "$prefix" == *'(?:'* ]]; do
        n=$(( n + 1 ))
        prefix="${prefix#*'(?:'}"
    done

    if [[ "$text" =~ $ere ]]; then
        printf '%s' "${BASH_REMATCH[$((1+n))]-}"
    fi
}

COMMAND="$(expand_template "$(agent_get command)")"
INVOCATION="$(agent_get invocation)"
[[ -z "$INVOCATION" ]] && INVOCATION="direct"
PROMPT_MODE="$(agent_get promptMode)"
[[ -z "$PROMPT_MODE" ]] && PROMPT_MODE="stdin"
OUTPUT_MODE="$(agent_get outputMode)"
[[ -z "$OUTPUT_MODE" ]] && OUTPUT_MODE="text"
PROGRESS_PREFIX="$(agent_get progressPrefix)"
[[ -z "$PROGRESS_PREFIX" ]] && PROGRESS_PREFIX="[$AGENT]"
WORKING_DIRECTORY="$(expand_template "$(agent_get workingDirectory)")"
[[ -z "$WORKING_DIRECTORY" ]] && WORKING_DIRECTORY="$WORKSPACE"
SESSION_ID_REGEX="$(agent_get sessionIdRegex)"

if [[ -z "$COMMAND" ]]; then
    echo "[ERROR] Agent config is missing command." >&2
    exit 1
fi
if ! command -v "$COMMAND" >/dev/null 2>&1 && [[ ! -x "$COMMAND" ]]; then
    echo "[ERROR] Missing configured command: $COMMAND" >&2
    exit 1
fi

load_environment_from_config

# ---------- build child args ----------
CHILD_ARGS=()
BASE_ARGS=()
IS_RESUME=0
if [[ -n "$SESSION" ]]; then
    IS_RESUME=1
    if ! jq -e --arg a "$AGENT" '.agents[$a].resumeArgs' "$CONFIG" >/dev/null; then
        echo "[ERROR] Agent '$AGENT' does not define resumeArgs." >&2
        exit 1
    fi
    expand_args_from_config resumeArgs
    BASE_ARGS+=("${ARGS_OUT[@]}")
else
    expand_args_from_config newArgs
    BASE_ARGS+=("${ARGS_OUT[@]}")
fi

PERMISSION_ARGS=()
if (( READ_ONLY )); then
    expand_args_from_config readOnlyArgs
    PERMISSION_ARGS+=("${ARGS_OUT[@]}")
elif [[ -n "$SANDBOX" ]]; then
    expand_args_from_config sandboxArgs
    PERMISSION_ARGS+=("${ARGS_OUT[@]}")
elif (( FULL_AUTO )) || agent_bool defaultFullAuto; then
    expand_args_from_config fullAutoArgs
    PERMISSION_ARGS+=("${ARGS_OUT[@]}")
fi

PERMISSION_ARGS_POSITION="$(agent_get permissionArgsPosition)"
if [[ "$PERMISSION_ARGS_POSITION" == "beforeBase" && ${#PERMISSION_ARGS[@]} -gt 0 ]]; then
    CHILD_ARGS+=("${PERMISSION_ARGS[@]}" "${BASE_ARGS[@]}")
else
    CHILD_ARGS+=("${BASE_ARGS[@]}" "${PERMISSION_ARGS[@]}")
fi

if (( ! IS_RESUME )) && [[ -n "$MODEL" ]]; then
    expand_args_from_config modelArgs
    CHILD_ARGS+=("${ARGS_OUT[@]}")
fi

# Prompt mode injection
case "$PROMPT_MODE" in
    argument)
        if jq -e --arg a "$AGENT" '.agents[$a].promptArgs' "$CONFIG" >/dev/null; then
            expand_args_from_config promptArgs
            CHILD_ARGS+=("${ARGS_OUT[@]}")
        else
            CHILD_ARGS+=("$PROMPT")
        fi
        ;;
    file)
        if jq -e --arg a "$AGENT" '.agents[$a].promptArgs' "$CONFIG" >/dev/null; then
            expand_args_from_config promptArgs
            CHILD_ARGS+=("${ARGS_OUT[@]}")
        else
            CHILD_ARGS+=("$TMP_PROMPT_FILE")
        fi
        ;;
    stdin) ;;
esac

# ---------- progress filters ----------
# stdout progress writer: receives raw lines on stdin and prints prefix progress to terminal stderr.
# Full raw bytes are captured by tee to TMP_STDOUT_FILE upstream.
print_stdout_progress() {
    local mode="$1" prefix="$2"
    local line preview cmd text
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$mode" in
            codex-json)
                if [[ "$line" == \{* ]]; then
                    if [[ "$line" == *'"item.started"'* && "$line" == *'"command_execution"'* ]]; then
                        cmd="$(printf '%s' "$line" | jq -r '.item.command // empty' 2>/dev/null || true)"
                        if [[ -n "$cmd" ]]; then
                            cmd="$(printf '%s' "$cmd" | sed -E 's#^/bin/(zsh|bash) (-lc|-c) ##')"
                            [[ ${#cmd} -gt 100 ]] && cmd="${cmd:0:100}"
                            printf '%s > %s\n' "$prefix" "$cmd" >&2
                        fi
                    elif [[ "$line" == *'"item.completed"'* && "$line" == *'"agent_message"'* ]]; then
                        text="$(printf '%s' "$line" | jq -r '.item.text // empty' 2>/dev/null || true)"
                        if [[ -n "$text" ]]; then
                            preview="${text%%$'\n'*}"
                            [[ ${#preview} -gt 120 ]] && preview="${preview:0:120}"
                            printf '%s %s\n' "$prefix" "$preview" >&2
                        fi
                    fi
                fi
                ;;
            generic-json|json)
                local trimmed="${line#"${line%%[![:space:]]*}"}"
                if [[ "$trimmed" != \{* && "$trimmed" != \[* ]]; then
                    preview="$line"
                    [[ ${#preview} -gt 120 ]] && preview="${preview:0:120}"
                    printf '%s %s\n' "$prefix" "$preview" >&2
                fi
                ;;
            *)
                preview="$line"
                [[ ${#preview} -gt 120 ]] && preview="${preview:0:120}"
                printf '%s %s\n' "$prefix" "$preview" >&2
                ;;
        esac
    done
}

print_stderr_progress() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line" >&2
    done
}

# ---------- run child ----------
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

run_child() {
    if [[ "$INVOCATION" == "shell" ]]; then
        # Build single shell command line with POSIX quoting.
        local q="" arg
        posix_quote() { local a="$1"; printf "'%s'" "${a//\'/\'\\\'\'}"; }
        q="$(posix_quote "$COMMAND")"
        for arg in "${CHILD_ARGS[@]}"; do
            q+=" $(posix_quote "$arg")"
        done
        if [[ "$PROMPT_MODE" == "stdin" ]]; then
            ( cd "$WORKING_DIRECTORY" && env "${ENV_OUT[@]}" /bin/sh -lc "$q" < "$TMP_PROMPT_FILE" )
        else
            ( cd "$WORKING_DIRECTORY" && env "${ENV_OUT[@]}" /bin/sh -lc "$q" < /dev/null )
        fi
    else
        if [[ "$PROMPT_MODE" == "stdin" ]]; then
            ( cd "$WORKING_DIRECTORY" && env "${ENV_OUT[@]}" "$COMMAND" "${CHILD_ARGS[@]}" < "$TMP_PROMPT_FILE" )
        else
            ( cd "$WORKING_DIRECTORY" && env "${ENV_OUT[@]}" "$COMMAND" "${CHILD_ARGS[@]}" < /dev/null )
        fi
    fi
}

# Run child capturing stdout/stderr to files while streaming progress.
run_child \
    > >(tee "$TMP_STDOUT_FILE" | print_stdout_progress "$OUTPUT_MODE" "$PROGRESS_PREFIX") \
    2> >(tee "$TMP_STDERR_FILE" | print_stderr_progress)
EXIT_CODE=$?
wait 2>/dev/null

STDOUT_TEXT="$(cat "$TMP_STDOUT_FILE")"
STDERR_TEXT="$(cat "$TMP_STDERR_FILE")"

# ---------- transcript ----------
write_transcript() {
    local path="$1" out="$2" err="$3" mode="$4"
    local dir
    dir="$(dirname "$path")"
    mkdir -p "$dir" 2>/dev/null || return 1
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out" | while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%$'\r'}"
                local entry_type="stdout"
                if [[ "$mode" == "codex-json" ]]; then
                    local trimmed="${line#"${line%%[![:space:]]*}"}"
                    if [[ "$trimmed" == \{* ]]; then
                        local t
                        t="$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null || true)"
                        [[ -n "$t" ]] && entry_type="$t"
                    fi
                fi
                jq -nc --arg ts "$ts" --arg type "$entry_type" --arg text "$line" '{ts:$ts,type:$type,text:$text}'
            done
        fi
        if [[ -n "$err" ]]; then
            printf '%s\n' "$err" | while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%$'\r'}"
                jq -nc --arg ts "$ts" --arg type "stderr" --arg text "$line" '{ts:$ts,type:$type,text:$text}'
            done
        fi
    } > "$path" 2>/dev/null || return 1
    if [[ ! -s "$path" ]]; then
        rm -f "$path"
        return 1
    fi
    return 0
}

ensure_parent_dir() {
    local p="$1" d
    d="$(dirname "$p")"
    [[ -n "$d" ]] && mkdir -p "$d"
}

# ---------- failure path ----------
if [[ "$EXIT_CODE" -ne 0 ]]; then
    ensure_parent_dir "$OUTPUT"
    {
        if [[ -n "${STDOUT_TEXT// }" ]]; then
            printf 'STDOUT:\n%s\n\n' "${STDOUT_TEXT%$'\n'}"
        fi
        if [[ -n "${STDERR_TEXT// }" ]]; then
            printf 'STDERR:\n%s\n' "${STDERR_TEXT%$'\n'}"
        fi
        if [[ -z "${STDOUT_TEXT// }" && -z "${STDERR_TEXT// }" ]]; then
            printf '(no output from %s)\n' "$AGENT"
        fi
    } > "$OUTPUT"
    if write_transcript "$TRANSCRIPT_PATH" "$STDOUT_TEXT" "$STDERR_TEXT" "$OUTPUT_MODE" 2>/dev/null; then
        printf 'output_path=%s\n' "$OUTPUT"
        printf 'transcript_path=%s\n' "$TRANSCRIPT_PATH"
    else
        printf 'output_path=%s\n' "$OUTPUT"
    fi
    echo "[ERROR] Agent '$AGENT' exited with code $EXIT_CODE. Captured output: $OUTPUT" >&2
    exit 1
fi

# ---------- summarize output ----------
THREAD_ID=""
SUMMARY_CONTENT=""
declare -a _SEEN_SUMMARY=()

append_summary() {
    local v="$1"
    [[ -z "$v" ]] && return
    local s
    for s in "${_SEEN_SUMMARY[@]}"; do
        [[ "$s" == "$v" ]] && return
    done
    _SEEN_SUMMARY+=("$v")
    if [[ -n "$SUMMARY_CONTENT" ]]; then
        SUMMARY_CONTENT+=$'\n'"$v"
    else
        SUMMARY_CONTENT="$v"
    fi
}

case "$OUTPUT_MODE" in
    codex-json)
        # Extract thread_id (first occurrence)
        tid="$(printf '%s' "$STDOUT_TEXT" | grep -m1 -oE '"thread_id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed -E 's/.*"thread_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
        [[ -n "$tid" ]] && THREAD_ID="$tid"
        # Walk each JSON line and pull agent_message texts + shell command/output previews
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "${line// }" ]] && continue
            trimmed="${line#"${line%%[![:space:]]*}"}"
            [[ "$trimmed" != \{* ]] && continue
            obj_type="$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)"
            [[ "$obj_type" != "item.completed" ]] && continue
            item_type="$(printf '%s' "$line" | jq -r '.item.type // empty' 2>/dev/null)"
            case "$item_type" in
                agent_message)
                    txt="$(printf '%s' "$line" | jq -r '.item.text // empty' 2>/dev/null)"
                    append_summary "$txt"
                    ;;
                command_execution)
                    cmd="$(printf '%s' "$line" | jq -r '.item.command // empty' 2>/dev/null)"
                    out="$(printf '%s' "$line" | jq -r '.item.aggregated_output // empty' 2>/dev/null)"
                    cmd="$(printf '%s' "$cmd" | sed -E 's#^/bin/(zsh|bash) (-lc|-c) ##')"
                    [[ ${#cmd} -gt 200 ]] && cmd="${cmd:0:200}"
                    [[ ${#out} -gt 500 ]] && out="${out:0:500}"
                    append_summary "### Shell: \`$cmd\`"$'\n'"$out"
                    ;;
                tool_call)
                    name="$(printf '%s' "$line" | jq -r '.item.name // empty' 2>/dev/null)"
                    if [[ "$name" == "shell" ]]; then
                        cmd="$(printf '%s' "$line" | jq -r '.item.arguments | fromjson? | .command // empty' 2>/dev/null)"
                        out="$(printf '%s' "$line" | jq -r '.item.output // empty' 2>/dev/null)"
                        [[ ${#cmd} -gt 200 ]] && cmd="${cmd:0:200}"
                        [[ ${#out} -gt 500 ]] && out="${out:0:500}"
                        [[ -n "$cmd" ]] && append_summary "### Shell: \`$cmd\`"$'\n'"$out"
                    fi
                    ;;
            esac
        done <<< "$STDOUT_TEXT"
        if (( IS_RESUME )) && [[ -z "$THREAD_ID" ]]; then THREAD_ID="$SESSION"; fi
        ;;
    generic-json|json)
        _whole_session_ok=0
        if printf '%s' "$STDOUT_TEXT" | jq -e . >/dev/null 2>&1; then
            _whole_session_ok=1
        fi
        for fname in session_id sessionId sessionID thread_id threadId; do
            v="$(printf '%s' "$STDOUT_TEXT" | jq -r --arg n "$fname" '.. | objects | .[$n]? // empty' 2>/dev/null | head -n1)"
            if [[ -n "$v" && "$v" != "null" ]]; then THREAD_ID="$v"; break; fi
        done
        if (( ! _whole_session_ok )) && [[ -z "$THREAD_ID" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                trimmed="${line#"${line%%[![:space:]]*}"}"
                [[ "$trimmed" != \{* && "$trimmed" != \[* ]] && continue
                for fname in session_id sessionId sessionID thread_id threadId; do
                    v="$(printf '%s' "$line" | jq -r --arg n "$fname" '.. | objects | .[$n]? // empty' 2>/dev/null | head -n1)"
                    if [[ -n "$v" && "$v" != "null" ]]; then THREAD_ID="$v"; break 2; fi
                done
            done <<< "$STDOUT_TEXT"
        fi
        text_values="$(printf '%s' "$STDOUT_TEXT" | jq -e -r '.. | objects | (.result?, .text?, .content?, .output?, .response?, .message?) | select(type=="string" and length > 0)' 2>/dev/null)" || text_values=""
        if [[ -z "$text_values" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                trimmed="${line#"${line%%[![:space:]]*}"}"
                [[ "$trimmed" != \{* && "$trimmed" != \[* ]] && continue
                v="$(printf '%s' "$line" | jq -r '.. | objects | (.result?, .text?, .content?, .output?, .response?, .message?) | select(type=="string" and length > 0)' 2>/dev/null || true)"
                [[ -n "$v" ]] && text_values+=$'\n'"$v"
            done <<< "$STDOUT_TEXT"
        fi
        if [[ -n "$text_values" ]]; then
            while IFS= read -r v || [[ -n "$v" ]]; do
                append_summary "$v"
            done <<< "$text_values"
        fi
        # Fallback regex from config
        if [[ -z "$THREAD_ID" && -n "$SESSION_ID_REGEX" ]]; then
            THREAD_ID="$(extract_session_id_from_regex "$STDOUT_TEXT" "$SESSION_ID_REGEX")"
        fi
        if (( IS_RESUME )) && [[ -z "$THREAD_ID" ]]; then THREAD_ID="$SESSION"; fi
        ;;
    *)
        trimmed="$(printf '%s' "$STDOUT_TEXT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -n "$trimmed" ]] && SUMMARY_CONTENT="$trimmed"
        if [[ -n "$SESSION_ID_REGEX" ]]; then
            THREAD_ID="$(extract_session_id_from_regex "$STDOUT_TEXT" "$SESSION_ID_REGEX")"
        fi
        if [[ -z "$THREAD_ID" ]] && (( IS_RESUME )); then
            THREAD_ID="$SESSION"
        fi
        ;;
esac

# ---------- save session ----------
save_session() {
    local path="$1" key="$2" agent="$3" workspace="$4" sid="$5"
    [[ -z "$sid" ]] && return
    local dir
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -f "$path" ]]; then
        jq --arg k "$key" --arg a "$agent" --arg w "$workspace" --arg s "$sid" --arg ts "$ts" \
            '.version = 1 | .sessions[$k] = {agent:$a, workspace:$w, session_id:$s, updated_utc:$ts}' \
            "$path" > "$path.tmp" && mv "$path.tmp" "$path"
    else
        jq -n --arg k "$key" --arg a "$agent" --arg w "$workspace" --arg s "$sid" --arg ts "$ts" \
            '{version:1, sessions: { ($k): {agent:$a, workspace:$w, session_id:$s, updated_utc:$ts} }}' \
            > "$path"
    fi
}

if (( !NO_SESSION )) && [[ -n "$THREAD_ID" ]]; then
    save_session "$SESSION_STATE_PATH" "$SESSION_KEY" "$AGENT" "$WORKSPACE" "$THREAD_ID"
fi

# ---------- write outputs ----------
ensure_parent_dir "$OUTPUT"
if [[ -n "$SUMMARY_CONTENT" ]]; then
    printf '%s\n' "$SUMMARY_CONTENT" > "$OUTPUT"
else
    printf '(no response from %s)\n' "$AGENT" > "$OUTPUT"
fi

TRANSCRIPT_OK=0
if write_transcript "$TRANSCRIPT_PATH" "$STDOUT_TEXT" "$STDERR_TEXT" "$OUTPUT_MODE" 2>/dev/null; then
    TRANSCRIPT_OK=1
fi

[[ -n "$THREAD_ID" ]] && printf 'session_id=%s\n' "$THREAD_ID"
printf 'output_path=%s\n' "$OUTPUT"
(( TRANSCRIPT_OK )) && printf 'transcript_path=%s\n' "$TRANSCRIPT_PATH"

if (( !NO_SUMMARY )); then
    body="$SUMMARY_CONTENT"
    [[ -z "$body" ]] && body="$(printf '%s' "$STDOUT_TEXT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ ${#body} -gt 4000 ]]; then
        body="${body:0:4000}"$'\n''...(truncated)'
    fi
    printf '<summary>\n%s\n</summary>\n' "$body"
fi
