#!/usr/bin/env bash
# shellcheck disable=SC2154

# Run a command and capture its combined output into the named variable, without waiting for any
# surviving child to close its descriptors.
#
# `amq wake` daemonizes stdin/stdout/stderr to /dev/null but can keep other inherited descriptors
# open for the life of the session. Command substitution reads its pipe until end-of-file, which
# only arrives once every writer closes, so `output="$(cmd)"` hangs forever once such a daemon is
# registered. Capturing through a regular file removes the ordinary output pipe. Explicitly close
# diagnostics fd 3 as well: callers can map it to their own captured stderr pipe, and a wake daemon
# retaining that writer would make an outer `subprocess.run(capture_output=True)` hang after this
# launcher has otherwise finished. Returns the command's exit status.
capture_command_output() {
  local __capture_var="$1"
  shift
  local __capture_file __capture_status
  __capture_file="$(mktemp "${TMPDIR:-/tmp}/cmux-project-capture.XXXXXX")" || return 1
  if "$@" 3>&- >"$__capture_file" 2>&1; then
    __capture_status=0
  else
    __capture_status=$?
  fi
  printf -v "$__capture_var" '%s' "$(cat "$__capture_file")"
  rm -f "$__capture_file"
  return "$__capture_status"
}

expand_path() {
  local value="$1"
  /usr/bin/python3 - "$value" <<'PY'
import os
import sys

print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
}

validate_launcher_word() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "$label must be a shell function name or executable path without spaces: $value" >&2
    exit 2
  fi
}

# Agent descriptor: every agent-specific value the launch pipeline needs. Adding an
# agent means adding arms here, not a new branch at each call site. bash 3.2 has no
# associative arrays, hence the case table.
#   agent_field <agent> <field>   prints the value; an unknown pair returns 1, no output.
# Two orders exist and both are contracts. The roster order is what `amq init
# --agents` and the naming summaries use. The pipeline order is the pane order and
# the order of every readiness, attach, rename and start step.
known_agents_roster=(claude codex grok gemini cursorcodex)
known_agents_pipeline=(codex claude grok gemini cursorcodex)

# startup is "launcher" or "helper":
#   launcher  the pane starts the agent with its wake off; the launcher waits for
#             its banner, attaches the wake, names it and sends its start command.
#   helper    the pane runs the coop helper exactly as typed (coopgrok <session>);
#             the helper's bootstrap names the agent and attaches the wake on its
#             own pane. The launcher only waits for that wake (Ohad, 2026-10-04).
# Pane names are single tokens because surface_refs_for_name matches one token:
# "Cursor Codex" would also match the Codex pane.
agent_field() {
  case "$1:$2" in
    codex:surface_name) printf '%s' 'Codex' ;;
    codex:startup) printf '%s' 'launcher' ;;
    # post-boot: renamed with /rename <agent>-<session> once the TUI is up.
    codex:rename_mode) printf '%s' 'post-boot' ;;
    codex:start_command) printf '%s' "\$start" ;;
    codex:process_regex) printf '%s' '(^|[[:space:]/])(codex|codex-pretty)([[:space:]]|$)' ;;
    codex:activity_regex) printf '%s' 'Working|Explored|Ran |Read |Using the ' ;;
    claude:surface_name) printf '%s' 'Claude' ;;
    claude:startup) printf '%s' 'launcher' ;;
    # boot-flag: named by `-- --name <agent>-<session>` in the pane command.
    claude:rename_mode) printf '%s' 'boot-flag' ;;
    claude:start_command) printf '%s' '/start' ;;
    claude:process_regex) printf '%s' '(^|[[:space:]/])claude([[:space:]]|$)' ;;
    claude:activity_regex) printf '%s' 'Running [0-9]+ shell command|Brewed for|thought for|Read |Wrote|Updated' ;;
    # Grok and Codex on Cursor both run the Cursor CLI, which execs node under
    # the name it was started by: `agent` or `cursor-agent`.
    grok:surface_name) printf '%s' 'Grok' ;;
    grok:startup) printf '%s' 'helper' ;;
    grok:rename_mode) printf '%s' 'helper' ;;
    grok:process_regex) printf '%s' '(^|[[:space:]/])(agent|cursor-agent)([[:space:]]|$)' ;;
    gemini:surface_name) printf '%s' 'Gemini' ;;
    gemini:startup) printf '%s' 'helper' ;;
    gemini:rename_mode) printf '%s' 'helper' ;;
    gemini:process_regex) printf '%s' '(^|[[:space:]/])gemini([[:space:]]|$)' ;;
    cursorcodex:surface_name) printf '%s' 'CursorCodex' ;;
    cursorcodex:startup) printf '%s' 'helper' ;;
    cursorcodex:rename_mode) printf '%s' 'helper' ;;
    cursorcodex:process_regex) printf '%s' '(^|[[:space:]/])(agent|cursor-agent)([[:space:]]|$)' ;;
    *) return 1 ;;
  esac
}

# Per-agent state without associative arrays: `agent_var_set codex surface X` stores
# $codex_surface, the same names the pipeline used when the pair was hardcoded.
agent_var_set() {
  printf -v "${1}_${2}" '%s' "$3"
}

agent_var_get() {
  local agent_var_name="${1}_${2}"
  printf '%s' "${!agent_var_name:-}"
}

# parse_agent_roster <csv> validates the chosen agents and sets:
#   launch_agents         the chosen agents in pipeline order
#   launch_agents_roster  the same set in roster order
#   launch_roster_csv     roster order, comma-separated, for `amq init --agents`
#   launch_retire_csv     pipeline order, comma-separated, for retire-session --agents
# The order the caller wrote is irrelevant. Returns 1 with the reason in
# agent_roster_error; agent_roster_reason prints it.
agent_roster_error=""
agent_roster_reason() {
  printf '%s' "$agent_roster_error"
}

parse_agent_roster() {
  local csv="$1"
  local agent
  local chosen=","
  local old_ifs
  local -a requested_agents
  requested_agents=()
  launch_agents=()
  launch_agents_roster=()
  launch_roster_csv=""
  launch_retire_csv=""
  agent_roster_error=""

  if [[ -z "$csv" ]]; then
    agent_roster_error="it is empty"
    return 1
  fi
  if [[ ! "$csv" =~ ^[a-z]+(,[a-z]+)*$ ]]; then
    agent_roster_error="it is not a comma-separated list of agent names: $csv"
    return 1
  fi
  old_ifs="$IFS"
  IFS=','
  # Intentional splitting of the validated comma-separated list.
  # shellcheck disable=SC2206
  requested_agents=($csv)
  IFS="$old_ifs"
  for agent in "${requested_agents[@]}"; do
    if ! agent_field "$agent" surface_name >/dev/null; then
      agent_roster_error="unknown agent: $agent"
      return 1
    fi
    if [[ "$chosen" == *",$agent,"* ]]; then
      agent_roster_error="agent listed twice: $agent"
      return 1
    fi
    chosen="$chosen$agent,"
  done
  for agent in "${known_agents_pipeline[@]}"; do
    if [[ "$chosen" == *",$agent,"* ]]; then
      launch_agents+=("$agent")
      launch_retire_csv="${launch_retire_csv:+$launch_retire_csv,}$agent"
    fi
  done
  for agent in "${known_agents_roster[@]}"; do
    if [[ "$chosen" == *",$agent,"* ]]; then
      launch_agents_roster+=("$agent")
      launch_roster_csv="${launch_roster_csv:+$launch_roster_csv,}$agent"
    fi
  done
}

# room_agent_handles <config.json> prints an AMQ room's agent handles, one per line
# and in the room's order, without the human "user" handle. Returns 1 when the
# config cannot be read as a list of handles.
room_agent_handles() {
  /usr/bin/python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        agents = json.load(fh)["agents"]
except Exception:
    sys.exit(1)
if not isinstance(agents, list) or not all(isinstance(agent, str) for agent in agents):
    sys.exit(1)
for agent in agents:
    if agent != "user":
        print(agent)
PY
}

# "Codex", "Codex and Claude", "Codex, Claude and Grok": the chosen agents' pane
# names in pipeline order, joined for messages. $1 overrides the last joiner.
launch_agent_names() {
  local last_joiner="${1:- and }"
  local agent
  local name
  local joined=""
  local index=0
  local last=$(( ${#launch_agents[@]} - 1 ))
  for agent in "${launch_agents[@]}"; do
    name="$(agent_field "$agent" surface_name)"
    if [[ "$index" -eq 0 ]]; then
      joined="$name"
    elif [[ "$index" -eq "$last" ]]; then
      joined="$joined$last_joiner$name"
    else
      joined="$joined, $name"
    fi
    index=$((index + 1))
  done
  printf '%s' "$joined"
}

extract_cmux_refs() {
  local prefix="$1"
  grep -Eo "${prefix}:[^[:space:]]+" || true
}

surface_refs_for_name() {
  local wanted="$1"
  awk -v wanted="$wanted" '
    {
      surface = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^surface:/) {
          surface = $i
        }
      }
      if (surface == "") {
        next
      }
      for (i = 1; i <= NF; i++) {
        token = $i
        sub(/^\*/, "", token)
        if (token == wanted) {
          print surface
        }
      }
    }
  '
}

surface_ids_for_name() {
  local wanted="$1"
  awk -v wanted="$wanted" '
    {
      surface_id = ""
      found_name = 0
      for (i = 1; i <= NF; i++) {
        token = $i
        sub(/^\*/, "", token)
        if (length(token) == 36 && token ~ /^[[:xdigit:]-]+$/) {
          surface_id = token
        }
        if (token == wanted) {
          found_name = 1
        }
      }
      if (surface_id != "" && found_name == 1) {
        print surface_id
      }
    }
  '
}

surface_debug_block() {
  local surface="$1"
  "$cmux_bin" debug-terminals 2>/dev/null | awk -v surface="$surface" '
    /^\[[0-9]+\] / {
      in_block = index($0, " " surface " ") > 0
    }
    in_block {
      print
    }
  ' || true
}

surface_has_live_runtime() {
  local surface="$1"
  local block
  block="$(surface_debug_block "$surface")"
  grep -Eq 'runtime=[1-9][0-9]*' <<<"$block" \
    && grep -Eq '(^|[[:space:]])tty=[^[:space:]]+' <<<"$block" \
    && ! grep -Eq '(^|[[:space:]])tty=nil' <<<"$block"
}

surface_tty() {
  local surface="$1"
  local terminals
  if ! terminals="$("$cmux_bin" debug-terminals 2>/dev/null)"; then
    return 2
  fi
  SURFACE_REF="$surface" TERMINALS="$terminals" /usr/bin/python3 <<'PY'
import os
import re
import sys

surface = os.environ["SURFACE_REF"]
blocks = re.split(r"(?=^\[[0-9]+\] )", os.environ["TERMINALS"], flags=re.M)
for block in blocks:
    if f" {surface} " not in f" {block} ":
        continue
    if not re.search(r"runtime=[1-9][0-9]*", block):
        sys.exit(1)
    match = re.search(r"(?<![A-Za-z])tty=([^ \n]+)", block)
    if not match or match.group(1) == "nil":
        sys.exit(1)
    print(match.group(1))
    sys.exit(0)
sys.exit(1)
PY
}

surface_has_agent_process() {
  local surface="$1"
  local agent="$2"
  local tty
  local processes
  local process_regex
  tty="$(surface_tty "$surface")" || return $?
  if ! processes="$("${ps_bin:-/bin/ps}" -ww -t "$tty" -o args= 2>/dev/null)"; then
    return 2
  fi
  process_regex="$(agent_field "$agent" process_regex)" || return 2
  grep -Eq "$process_regex" <<<"$processes"
}

workspace_surface_rows() {
  local target_workspace_ref="$1"
  local id_format="${2:-refs}"
  local pane_output
  local surface_output
  local row
  local pane
  local -a pane_refs
  pane_refs=()

  if ! pane_output="$("$cmux_bin" list-panes --workspace "$target_workspace_ref" 2>&1)"; then
    echo "cmux list-panes failed for $target_workspace_ref: $pane_output" >&2
    return 2
  fi
  while IFS= read -r row || [[ -n "$row" ]]; do
    [[ -n "$row" ]] && pane_refs+=("$row")
  done < <(printf '%s\n' "$pane_output" | extract_cmux_refs pane | head -n "${#known_agents_pipeline[@]}")

  if [[ "${#pane_refs[@]}" -gt 0 ]]; then
    for pane in "${pane_refs[@]}"; do
      if [[ "$id_format" == "both" ]]; then
        if ! surface_output="$("$cmux_bin" --id-format both list-pane-surfaces --workspace "$target_workspace_ref" --pane "$pane" 2>&1)"; then
          echo "cmux list-pane-surfaces failed for $target_workspace_ref/$pane: $surface_output" >&2
          return 2
        fi
      elif ! surface_output="$("$cmux_bin" list-pane-surfaces --workspace "$target_workspace_ref" --pane "$pane" 2>&1)"; then
        echo "cmux list-pane-surfaces failed for $target_workspace_ref/$pane: $surface_output" >&2
        return 2
      fi
      [[ -n "$surface_output" ]] && printf '%s\n' "$surface_output"
    done
    return 0
  fi

  if [[ "$id_format" == "both" ]]; then
    if ! surface_output="$("$cmux_bin" --id-format both list-pane-surfaces --workspace "$target_workspace_ref" 2>&1)"; then
      echo "cmux list-pane-surfaces failed for $target_workspace_ref: $surface_output" >&2
      return 2
    fi
  elif ! surface_output="$("$cmux_bin" list-pane-surfaces --workspace "$target_workspace_ref" 2>&1)"; then
    echo "cmux list-pane-surfaces failed for $target_workspace_ref: $surface_output" >&2
    return 2
  fi
  [[ -n "$surface_output" ]] && printf '%s\n' "$surface_output"
}

amq_candidate_paths() {
  local hints="${CMUX_PROJECT_LAUNCHER_AMQ_PATH_HINTS:-}"
  local old_ifs="$IFS"
  local hint
  local expanded_hint
  IFS=:
  for hint in $hints; do
    [[ -z "$hint" ]] && continue
    expanded_hint="$(expand_path "$hint")" || continue
    if [[ -d "$expanded_hint" ]]; then
      printf '%s\n' "$expanded_hint/amq"
    else
      printf '%s\n' "$expanded_hint"
    fi
  done
  IFS="$old_ifs"

  cat <<'PATHS'
/opt/homebrew/bin/amq
/usr/local/bin/amq
PATHS
  if [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "$HOME/.local/bin/amq" "$HOME/.claude/bin/amq"
  fi
}

resolve_amq_bin() {
  local found
  local candidate
  local normalized
  if [[ -z "${amq_bin:-}" ]]; then
    amq_bin="amq"
  fi
  if [[ "$amq_bin" == */* ]]; then
    normalized="$(expand_path "$amq_bin")" || return 1
    [[ "$normalized" == /* && -x "$normalized" ]] || return 1
    amq_bin="$normalized"
    return 0
  fi

  while IFS= read -r candidate; do
    normalized="$(expand_path "$candidate")" || continue
    if [[ "$normalized" == /* && -x "$normalized" ]]; then
      amq_bin="$normalized"
      return 0
    fi
  done < <(amq_candidate_paths)

  found="$(command -v "$amq_bin" 2>/dev/null || true)"
  if [[ -n "$found" && "$found" == */* ]]; then
    normalized="$(expand_path "$found")" || return 1
  else
    normalized=""
  fi
  if [[ "$normalized" == /* && -x "$normalized" ]]; then
    amq_bin="$normalized"
    return 0
  fi

  return 1
}

claude_candidate_paths() {
  cat <<'PATHS'
/opt/homebrew/bin/claude
/usr/local/bin/claude
PATHS
  if [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "$HOME/.local/bin/claude" "$HOME/.claude/local/claude"
  fi
}

resolve_claude_bin() {
  local found
  local candidate
  if [[ -z "${claude_bin:-}" ]]; then
    claude_bin="claude"
  fi
  if [[ "$claude_bin" == */* ]]; then
    [[ -x "$claude_bin" ]]
    return $?
  fi

  while IFS= read -r candidate; do
    if [[ -x "$candidate" ]]; then
      claude_bin="$candidate"
      return 0
    fi
  done < <(claude_candidate_paths)

  found="$(command -v "$claude_bin" 2>/dev/null || true)"
  if [[ -n "$found" && -x "$found" ]]; then
    claude_bin="$found"
    return 0
  fi

  return 1
}

resolve_amq_base_root() {
  local env_json
  if [[ -n "${CMUX_PROJECT_LAUNCHER_AMQ_ROOT:-}" ]]; then
    printf '%s\n' "$CMUX_PROJECT_LAUNCHER_AMQ_ROOT"
    return 0
  fi
  resolve_amq_bin || return 1
  env_json="$(
    cd "${workspace_root:-$HOME/git}" || exit 1
    "$amq_bin" env --json 2>/dev/null
  )" || return 1
  AMQ_ENV_JSON="$env_json" /usr/bin/python3 - "${workspace_root:-$HOME/git}" <<'PY'
import json
import os
import sys

workspace_root = sys.argv[1]
try:
    data = json.loads(os.environ["AMQ_ENV_JSON"])
except Exception:
    sys.exit(1)

root = data.get("base_root") or data.get("root")
if not root:
    sys.exit(1)
if not os.path.isabs(root):
    root = os.path.abspath(os.path.join(workspace_root, root))
print(root)
PY
}

amq_who_json() {
  local root="$1"
  [[ -z "$root" ]] && return 1
  resolve_amq_bin || return 1
  "$amq_bin" who -root "$root" --json 2>/dev/null || return 1
}

session_active_in_who() {
  local session="$1"
  local who_json="$2"
  [[ -z "$who_json" ]] && return 1
  WHO_JSON="$who_json" /usr/bin/python3 - "$session" <<'PY'
import json
import os
import sys

session = sys.argv[1]
try:
    rooms = json.loads(os.environ["WHO_JSON"])
except Exception:
    sys.exit(1)
if not isinstance(rooms, list):
    sys.exit(1)

for room in rooms:
    if room.get("name") != session:
        continue
    for agent in room.get("agents", []):
        if agent.get("active"):
            sys.exit(0)
    sys.exit(1)
sys.exit(1)
PY
}

wake_lock_active() {
  local session="$1"
  local agent
  for agent in "${known_agents_pipeline[@]}"; do
    if agent_wake_lock_live "$session" "$agent"; then
      return 0
    fi
  done
  return 1
}

# agent_wake_lock_live <session> <agent>: 0 when the agent's .wake.lock names a
# live `amq wake` process, and also when the lock cannot be read (the safe
# answer); 1 when there is no lock or its process is gone.
agent_wake_lock_live() {
  local session="$1"
  local agent="$2"
  local lock
  local pid
  local pid_status
  local command_line
  [[ -z "${amq_base_root:-}" ]] && return 1
  lock="$amq_base_root/$session/agents/$agent/.wake.lock"
  [[ -f "$lock" ]] || return 1
  pid_status=0
  pid="$(/usr/bin/python3 - "$lock" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(2)
pid = data.get("pid")
if isinstance(pid, int) and pid > 0:
    print(pid)
    sys.exit(0)
sys.exit(2)
PY
)" || pid_status=$?
  case "$pid_status" in
    0)
      if kill -0 "$pid" 2>/dev/null; then
        command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if grep -Eq '(^|[ /])amq([^[:alnum:]_.-]|.*[[:space:]])wake([[:space:]]|$)' <<<"$command_line"; then
          return 0
        fi
      fi
      ;;
    2)
      return 0
      ;;
  esac
  return 1
}

wake_targets_surface() {
  local session="$1"
  local agent="$2"
  local surface_id="$3"
  local lock="$amq_base_root/$session/agents/$agent/.wake.lock"
  local pid
  local command_line
  [[ -f "$lock" ]] || return 1
  pid="$(/usr/bin/python3 - "$lock" "$amq_base_root/$session" "$agent" <<'PY'
import json
import os
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
pid = data.get("pid")
root = data.get("root")
agent = data.get("agent")
expected_root = os.path.abspath(os.path.expanduser(sys.argv[2]))
if (
    isinstance(pid, int)
    and pid > 0
    and isinstance(root, str)
    and os.path.abspath(os.path.expanduser(root)) == expected_root
    and agent == sys.argv[3]
):
    print(pid)
    sys.exit(0)
sys.exit(1)
PY
)" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$("${ps_bin:-/bin/ps}" -ww -p "$pid" -o command= 2>/dev/null)" || return 1
  /usr/bin/python3 - "$command_line" "$amq_base_root/$session" "$agent" "cmux:surface:$surface_id" <<'PY'
import os
import shlex
import sys

try:
    argv = shlex.split(sys.argv[1])
except ValueError:
    sys.exit(1)
expected_root = os.path.abspath(os.path.expanduser(sys.argv[2]))
expected_agent = sys.argv[3]
expected_target = sys.argv[4]

wake_index = None
for index in range(len(argv) - 1):
    if os.path.basename(argv[index]) == "amq" and argv[index + 1] == "wake":
        wake_index = index + 2
        break
if wake_index is None:
    sys.exit(1)

root = None
agent = None
inject_args = []
index = wake_index
while index < len(argv):
    token = argv[index]
    if token in ("-root", "--root") and index + 1 < len(argv):
        root = argv[index + 1]
        index += 2
        continue
    if token.startswith("-root=") or token.startswith("--root="):
        root = token.split("=", 1)[1]
    elif token in ("-me", "--me") and index + 1 < len(argv):
        agent = argv[index + 1]
        index += 2
        continue
    elif token.startswith("-me=") or token.startswith("--me="):
        agent = token.split("=", 1)[1]
    elif token in ("-inject-arg", "--inject-arg") and index + 1 < len(argv):
        inject_args.append(argv[index + 1])
        index += 2
        continue
    elif token.startswith("-inject-arg=") or token.startswith("--inject-arg="):
        inject_args.append(token.split("=", 1)[1])
    index += 1

if root is None or os.path.abspath(os.path.expanduser(root)) != expected_root:
    sys.exit(1)
if agent != expected_agent or expected_target not in inject_args:
    sys.exit(1)
sys.exit(0)
PY
}

session_in_use() {
  local session="$1"
  if wake_lock_active "$session"; then
    return 0
  fi
  session_active_in_who "$session" "$amq_who_state"
}

workspace_records_for_project() {
  local project="$1"
  CMUX_BIN="$cmux_bin" /usr/bin/python3 - "$project" <<'PY'
import json
import os
import re
import subprocess
import sys

project = sys.argv[1]
cmux = os.environ["CMUX_BIN"]
candidates = []
seen_refs = set()
order = 0
launcher_description = re.compile(
    r"^Project launcher: ([A-Za-z0-9][A-Za-z0-9._-]*) "
    r"\(AMQ session: ([A-Za-z0-9][A-Za-z0-9._-]*)\)$"
)

def run(args):
    result = subprocess.run(
        [cmux] + args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip()
        suffix = f": {detail}" if detail else ""
        print("cmux query failed: " + " ".join(args) + suffix, file=sys.stderr)
        sys.exit(2)
    return result.stdout

def collect(output):
    global order
    if not output.strip():
        return
    try:
        data = json.loads(output)
    except Exception:
        print("cmux workspace list returned invalid JSON", file=sys.stderr)
        sys.exit(2)

    if isinstance(data, dict):
        workspaces = data.get("workspaces", [])
    elif isinstance(data, list):
        workspaces = data
    else:
        workspaces = []

    for workspace in workspaces:
        if not isinstance(workspace, dict):
            continue
        title = workspace.get("title")
        description = workspace.get("description")
        metadata_match = (
            launcher_description.fullmatch(description)
            if isinstance(description, str)
            else None
        )
        if (
            isinstance(description, str)
            and description.startswith(f"Project launcher: {project} ")
            and not metadata_match
        ):
            print(
                f"malformed cmux launcher metadata for project {project}",
                file=sys.stderr,
            )
            sys.exit(2)
        launcher_owned = bool(metadata_match and metadata_match.group(1) == project)
        if launcher_owned:
            session = metadata_match.group(2)
            kind = "launcher"
        elif title == project:
            if metadata_match:
                print(
                    f"cmux workspace metadata conflict for project {project}: "
                    f"title belongs to launcher project {metadata_match.group(1)}",
                    file=sys.stderr,
                )
                sys.exit(2)
            session = project
            kind = "title-collision"
        else:
            continue
        ref = workspace.get("ref")
        if (
            not isinstance(ref, str)
            or not ref
            or any(character in ref for character in "\t\r\n")
            or ref in seen_refs
        ):
            continue
        seen_refs.add(ref)
        index = workspace.get("index")
        if not isinstance(index, int):
            index = -1
        selected = bool(workspace.get("selected"))
        latest_submitted_at = workspace.get("latest_submitted_at")
        if not isinstance(latest_submitted_at, str):
            latest_submitted_at = ""
        candidates.append(
            {
                "launcher_owned": launcher_owned,
                "selected": selected,
                "latest_submitted_at": latest_submitted_at,
                "index": index,
                "order": order,
                "ref": ref,
                "session": session,
                "kind": kind,
            }
        )
        order += 1

collect(run(["workspace", "list", "--json"]))
for line in run(["list-windows"]).splitlines():
    match = re.match(r"\*?\s*(\d+):", line)
    if match:
        collect(run(["workspace", "list", "--json", "--window", match.group(1)]))

# Stable sorts encode this priority: launcher metadata, selected, recent activity,
# then newest workspace index (with discovery order only as the final tie-breaker).
candidates.sort(key=lambda item: (item["index"], -item["order"]), reverse=True)
candidates.sort(key=lambda item: item["latest_submitted_at"], reverse=True)
candidates.sort(key=lambda item: item["selected"], reverse=True)
candidates.sort(key=lambda item: item["launcher_owned"], reverse=True)
if candidates:
    for candidate in candidates:
        print(f"{candidate['ref']}\t{candidate['session']}\t{candidate['kind']}")
    sys.exit(0)
sys.exit(1)
PY
}

workspace_has_live_runtime() {
  local target_workspace_ref="$1"
  local terminals
  if ! terminals="$("$cmux_bin" debug-terminals 2>/dev/null)"; then
    return 2
  fi
  if [[ -z "$terminals" ]]; then
    return 1
  fi
  WORKSPACE_REF="$target_workspace_ref" TERMINALS="$terminals" /usr/bin/python3 <<'PY'
import os
import re
import sys

target = os.environ["WORKSPACE_REF"]
terminals = os.environ["TERMINALS"]
blocks = re.split(r"(?=^\[[0-9]+\] )", terminals, flags=re.M)
for block in blocks:
    if f" workspace={target} " not in f" {block} ":
        continue
    if not re.search(r"runtime=[1-9][0-9]*", block):
        continue
    tty = re.search(r"(?<![A-Za-z])tty=([^ \n]+)", block)
    if tty and tty.group(1) != "nil":
        sys.exit(0)
sys.exit(1)
PY
}

activate_cmux_app() {
  local bundle_id="${CMUX_PROJECT_LAUNCHER_CMUX_BUNDLE_ID:-com.cmuxterm.app}"
  local app_path="${CMUX_PROJECT_LAUNCHER_CMUX_APP:-/Applications/cmux.app}"
  "$open_bin" -b "$bundle_id" >/dev/null 2>&1 && return 0
  if [[ -d "$app_path" ]]; then
    "$open_bin" "$app_path" >/dev/null 2>&1 || true
  fi
}

select_existing_workspace() {
  local target_workspace_ref="$1"
  "$cmux_bin" workspace select "$target_workspace_ref" >/dev/null || return 1
  activate_cmux_app || true
  return 0
}

pane_for_surface() {
  local wanted_surface="$1"
  local pane_output
  local row
  local pane
  local surfaces
  local -a pane_refs
  pane_refs=()
  if ! pane_output="$("$cmux_bin" list-panes --workspace "$workspace_ref" 2>/dev/null)"; then
    return 1
  fi
  while IFS= read -r row || [[ -n "$row" ]]; do
    [[ -n "$row" ]] && pane_refs+=("$row")
  done < <(printf '%s\n' "$pane_output" | extract_cmux_refs pane)
  if [[ "${#pane_refs[@]}" -eq 0 ]]; then
    return 1
  fi
  for pane in "${pane_refs[@]}"; do
    if surfaces="$("$cmux_bin" list-pane-surfaces --workspace "$workspace_ref" --pane "$pane" 2>/dev/null)" \
      && grep -Fq -- "$wanted_surface" <<<"$surfaces"; then
      printf '%s\n' "$pane"
      return 0
    fi
  done
  return 1
}

promote_surface_once() {
  local surface="$1"
  local pane
  "$cmux_bin" workspace select "$workspace_ref" >/dev/null 2>&1 || true
  pane="$(pane_for_surface "$surface" || true)"
  if [[ -n "$pane" ]]; then
    "$cmux_bin" focus-pane --workspace "$workspace_ref" --pane "$pane" >/dev/null 2>&1 || true
  fi
  "$cmux_bin" refresh-surfaces >/dev/null 2>&1 || true
}

wait_for_surface_runtime() {
  local surface="$1"
  local deadline=$((SECONDS + promote_wait_seconds))
  while true; do
    if surface_has_live_runtime "$surface"; then
      return 0
    fi
    (( SECONDS >= deadline )) && break
    sleep 1
  done
  return 1
}

wait_for_surface_text() {
  local surface="$1"
  local regex="$2"
  local deadline=$((SECONDS + poll_seconds))
  local screen
  while true; do
    if screen="$("$cmux_bin" read-screen --workspace "$workspace_ref" --surface "$surface" --lines 80 2>/dev/null)" \
      && grep -Eiq "$regex" <<<"$screen"; then
      return 0
    fi
    (( SECONDS >= deadline )) && break
    sleep 1
  done
  return 1
}

wait_for_surface_text_strict() {
  local surface="$1"
  local regex="$2"
  local deadline=$((SECONDS + poll_seconds))
  local screen
  while true; do
    if ! screen="$("$cmux_bin" read-screen --workspace "$workspace_ref" --surface "$surface" --lines 80 2>/dev/null)"; then
      return 2
    fi
    if grep -Eiq "$regex" <<<"$screen"; then
      return 0
    fi
    (( SECONDS >= deadline )) && break
    sleep 1
  done
  return 1
}

read_surface_text() {
  local surface="$1"
  "$cmux_bin" read-screen --workspace "$workspace_ref" --surface "$surface" --scrollback --lines 120 2>/dev/null
}

read_surface_visible_text() {
  local surface="$1"
  "$cmux_bin" read-screen --workspace "$workspace_ref" --surface "$surface" --lines 80 2>/dev/null
}

wait_for_surface_literals() {
  local surface="$1"
  shift
  local deadline=$((SECONDS + submit_confirm_wait_seconds))
  local text
  local literal
  local found
  while true; do
    if ! text="$(read_surface_visible_text "$surface")"; then
      return 2
    fi
    found=1
    for literal in "$@"; do
      if ! grep -Fq -- "$literal" <<<"$text"; then
        found=0
        break
      fi
    done
    if [[ "$found" -eq 1 ]]; then
      return 0
    fi
    (( SECONDS >= deadline )) && break
    sleep 1
  done
  return 1
}

agent_activity_marker_regex() {
  local agent="$1"
  # An agent without its own markers keeps the historical fallback to Claude's.
  agent_field "$agent" activity_regex || agent_field claude activity_regex
  printf '\n'
}

visible_input_region() {
  local surface="$1"
  local text
  local region
  if ! text="$(read_surface_visible_text "$surface")"; then
    return 2
  fi
  region="$(
    printf '%s\n' "$text" | awk '
      /^[[:space:]]*>[[:space:]]/ || /^[[:space:]]*❯/ {
        found = 1
        buffer = $0 ORS
        next
      }
      found { buffer = buffer $0 ORS }
      END {
        if (found) {
          printf "%s", buffer
        }
      }
    '
  )"
  if [[ -n "$region" ]]; then
    printf '%s\n' "$region" | tail -n "$input_probe_lines"
  else
    printf '%s\n' "$text" | tail -n "$input_probe_lines"
  fi
}

# True when <text> shows <literal>, also when the terminal wrapped it. cmux
# read-screen returns a soft wrap as a newline, and a narrow pane (one of three
# columns) wraps a long name mid-word onto an indented row:
# "› codex-accept-launcher-20261005-" then "  091935" (Gate 4, 2026-10-05).
# So compare again with spaces, tabs and line breaks removed from both sides.
text_shows_literal() {
  local text="$1"
  local literal="$2"
  local squeezed_text
  local squeezed_literal
  if grep -Fq -- "$literal" <<<"$text"; then
    return 0
  fi
  squeezed_literal="$(printf '%s' "$literal" | LC_ALL=C tr -d ' \t\r\n')"
  [[ -n "$squeezed_literal" ]] || return 1
  squeezed_text="$(printf '%s' "$text" | LC_ALL=C tr -d ' \t\r\n')"
  grep -Fq -- "$squeezed_literal" <<<"$squeezed_text"
}

prompt_visible_in_input() {
  local surface="$1"
  local prompt="$2"
  local text
  if ! text="$(visible_input_region "$surface")"; then
    return 2
  fi
  if text_shows_literal "$text" "$prompt"; then
    return 0
  fi
  return 1
}

wait_for_prompt_visible() {
  local surface="$1"
  local prompt="$2"
  local deadline=$((SECONDS + submit_confirm_wait_seconds))
  wait_for_prompt_visible_until "$surface" "$prompt" "$deadline"
}

wait_for_prompt_visible_until() {
  local surface="$1"
  local prompt="$2"
  local deadline="$3"
  local status
  while true; do
    status=0
    prompt_visible_in_input "$surface" "$prompt" || status=$?
    case "$status" in
      0)
        return 0
        ;;
      2)
        return 2
        ;;
    esac
    (( SECONDS >= deadline )) && break
    sleep 1
  done
  return 1
}

prompt_submitted() {
  local surface="$1"
  local agent="$2"
  local prompt="$3"
  local text
  local status
  status=0
  prompt_visible_in_input "$surface" "$prompt" || status=$?
  case "$status" in
    0)
      ;;
    1)
      return 0
      ;;
    *)
      return 2
      ;;
  esac
  if ! text="$(read_surface_visible_text "$surface")"; then
    return 2
  fi
  grep -Eq "$(agent_activity_marker_regex "$agent")" <<<"$text"
}

confirm_or_retry_enter() {
  local surface="$1"
  local agent="$2"
  local prompt="$3"
  local visible_probe="${4:-$prompt}"
  local attempt
  local deadline
  for ((attempt = 1; attempt <= enter_retries; attempt++)); do
    "$cmux_bin" send-key --workspace "$workspace_ref" --surface "$surface" enter >/dev/null
    deadline=$((SECONDS + submit_confirm_wait_seconds))
    while true; do
      if prompt_submitted "$surface" "$agent" "$visible_probe"; then
        return 0
      fi
      (( SECONDS >= deadline )) && break
      sleep 1
    done
  done
  return 1
}

submit_prompt() {
  local surface="$1"
  local prompt="$2"
  local agent="$3"
  local visible_probe="${4:-$prompt}"
  "$cmux_bin" send --workspace "$workspace_ref" --surface "$surface" "$prompt" >/dev/null
  if ! wait_for_prompt_visible "$surface" "$visible_probe"; then
    return 1
  fi
  sleep "$enter_delay_seconds"
  confirm_or_retry_enter "$surface" "$agent" "$prompt" "$visible_probe"
}

submit_prompt_when_input_ready() {
  local surface="$1"
  local prompt="$2"
  local agent="$3"
  local visible_probe="$4"
  local deadline="$5"
  "$cmux_bin" send --workspace "$workspace_ref" --surface "$surface" "$prompt" >/dev/null
  if ! wait_for_prompt_visible_until "$surface" "$visible_probe" "$deadline"; then
    return 1
  fi
  sleep "$enter_delay_seconds"
  confirm_or_retry_enter "$surface" "$agent" "$prompt" "$visible_probe"
}

# Rename an agent's own conversation/thread via its interactive `/rename` command.
#
# Claude is named at boot with `claude --name <name>` (see the layout builders), so
# this post-boot path is used for Codex, whose CLI has no session-name launch flag.
# Codex's `/rename` opens a "Type a name and press Enter" dialog whose footer
# already says "Press enter to confirm" (since Codex 0.160.0, "enter submit · esc
# back"). The Enter that submits the name also
# confirms the rename. Require a new matching success marker after that Enter;
# retry only while the same naming dialog, exact name, and active confirmation
# footer remain at the bottom of the visible input region. Codex replaces the
# initial "Type a name" placeholder after text is entered, so it is not part of
# the post-name active-state check.
# A disappearing composer alone is not rename proof.
#
# Do not open this dialog through submit_prompt. That helper keeps pressing Enter
# until the typed text leaves the composer or an agent activity marker appears.
# /rename produces a modal, not an activity marker, and the slash text can remain
# visible in the last input-probe lines after the dialog is already open. Extra
# Enters then land in the modal; a later failure walks away and leaves Codex
# stuck on "Type a name and press Enter" (2026-09-08 Gate 4, 1 run in 3).
rename_dialog_prompt_visible() {
  local text="$1"
  grep -Fq -- "Type a name and press Enter" <<<"$text"
}

open_rename_dialog() {
  local surface="$1"
  local agent="$2"
  local deadline
  local text
  "$cmux_bin" send --workspace "$workspace_ref" --surface "$surface" "/rename" >/dev/null
  deadline=$((SECONDS + submit_confirm_wait_seconds))
  while true; do
    if ! text="$(read_surface_visible_text "$surface")"; then
      echo "Could not inspect the $agent surface while opening /rename." >&2
      return 1
    fi
    if rename_dialog_prompt_visible "$text"; then
      return 0
    fi
    if prompt_visible_in_input "$surface" "/rename"; then
      break
    fi
    (( SECONDS >= deadline )) && break
    sleep 1
  done
  if ! prompt_visible_in_input "$surface" "/rename"; then
    echo "Could not type /rename on the $agent surface." >&2
    return 1
  fi
  sleep "$enter_delay_seconds"
  "$cmux_bin" send-key --workspace "$workspace_ref" --surface "$surface" enter >/dev/null
  deadline=$((SECONDS + submit_confirm_wait_seconds))
  while true; do
    if ! text="$(read_surface_visible_text "$surface")"; then
      echo "Could not inspect the $agent rename dialog after submitting /rename." >&2
      return 1
    fi
    if rename_dialog_prompt_visible "$text"; then
      return 0
    fi
    (( SECONDS >= deadline )) && break
    sleep 1
  done
  echo "The $agent /rename command did not open its naming dialog." >&2
  return 1
}

rename_modal_visible() {
  local text="$1"
  local name="$2"
  if rename_dialog_prompt_visible "$text"; then
    return 0
  fi
  if [[ -n "$name" ]] && rename_dialog_is_active "$text" "$name"; then
    return 0
  fi
  return 1
}

dismiss_rename_dialog() {
  local surface="$1"
  local agent="$2"
  local name="${3:-}"
  local attempt
  local text
  local settle_deadline
  # A single modal-free read is NOT proof there is nothing to dismiss. The dialog
  # can render AFTER open_rename_dialog gives up, so an immediate check returns 0,
  # no Escape is ever sent, and the pane is left stuck on "Type a name and press
  # Enter" — where it cannot receive an AMQ doorbell. Observed live 2026-09-08 as
  # Gate 4 run C. Watch for a bounded window before calling the pane clean.
  settle_deadline=$((SECONDS + submit_confirm_wait_seconds))
  while true; do
    if ! text="$(read_surface_visible_text "$surface")"; then
      echo "Could not inspect the $agent surface before dismissing the rename dialog." >&2
      return 1
    fi
    if rename_modal_visible "$text" "$name"; then
      break
    fi
    if (( SECONDS >= settle_deadline )); then
      return 0
    fi
    sleep 1
  done
  for ((attempt = 1; attempt <= enter_retries; attempt++)); do
    "$cmux_bin" send-key --workspace "$workspace_ref" --surface "$surface" escape >/dev/null
    sleep "$enter_delay_seconds"
    if ! text="$(read_surface_visible_text "$surface")"; then
      echo "Could not inspect the $agent surface while dismissing the rename dialog." >&2
      return 1
    fi
    if ! rename_modal_visible "$text" "$name"; then
      echo "Dismissed the $agent rename dialog after a failed rename." >&2
      return 0
    fi
  done
  echo "Could not dismiss the $agent rename dialog; $agent may still be in Type a name and press Enter." >&2
  return 1
}

# True when the last visible line looks like a returned-to-idle composer, not
# the confirm footer or the name still sitting in the modal. A warning or
# sqlite3 line under the footer is not idle — r4 interleaved that class of
# text onto the composer, and the same class one line lower used to make
# dismiss_rename_dialog return 0 without sending Escape.
rename_dialog_returned_to_composer() {
  local last="$1"
  local name="$2"
  case "$last" in
    *"Press enter to confirm"*|*"enter submit"*) return 1 ;;
  esac
  if [[ -n "$name" && "$last" == *"$name"* ]]; then
    return 1
  fi
  case "$last" in
    '>'|'> '*|'›'|'› '*) return 0 ;;
  esac
  return 1
}

rename_dialog_is_active() {
  local text="$1"
  local name="$2"
  local input_region
  local last_nonblank
  input_region="$(printf '%s\n' "$text" | tail -n "$input_probe_lines")"
  last_nonblank="$(awk 'NF { line = $0 } END { print line }' <<<"$input_region")"
  # Codex 0.160.0 replaced the "Press enter to confirm" footer with
  # "enter submit · esc back" (Gate 4, 2026-10-05); accept either.
  grep -Eq -- '(^|[[:space:]])(Name|Rename) thread([[:space:]]|$)' <<<"$input_region" \
    && text_shows_literal "$input_region" "$name" \
    && grep -Eq -- 'Press enter to confirm|(^|[[:space:]])enter submit([[:space:]]|$)' <<<"$input_region" \
    && ! rename_dialog_returned_to_composer "$last_nonblank" "$name"
}

count_rename_success_markers() {
  local text="$1"
  local name="$2"
  # cmux read-screen returns terminal soft wraps as newlines. Long generated
  # names can therefore split the otherwise exact Codex success marker across
  # rows (for example, "codex-project-\n20260725"). Collapse display rows only
  # for this literal marker count; the stronger before/after count below still
  # prevents stale success text from proving a new rename.
  printf '%s\n' "$text" |
    tr -d '\r\n' |
    { grep -Fo -- "Session renamed to $name" || true; } |
    wc -l |
    tr -d '[:space:]'
}

# Codex 0.155.1 closes the naming dialog without printing "Session renamed to"
# (Gate 4, 2026-09-23). It does append {"id":...,"thread_name":<name>,...} to
# $CODEX_HOME/session_index.jsonl at rename time. Count rows for the exact name;
# like the screen marker, only an increase after the confirming Enter is proof,
# so an older row for a reused name proves nothing.
count_rename_index_rows() {
  local name="$1"
  local index_file="${CODEX_HOME:-$HOME/.codex}/session_index.jsonl"
  [[ -r "$index_file" ]] || { printf '0'; return 0; }
  { grep -Fc -- "\"thread_name\":\"$name\"" "$index_file" || true; } | tr -d '[:space:]'
}

rename_thread() {
  local surface="$1"
  local name="$2"
  local agent="$3"
  local attempt
  local baseline_successes
  local baseline_index_rows
  local deadline
  local text
  local successes
  if ! open_rename_dialog "$surface" "$agent"; then
    dismiss_rename_dialog "$surface" "$agent" || true
    echo "Could not open the $agent rename prompt; leaving the session name unchanged." >&2
    return 1
  fi
  sleep "$enter_delay_seconds"
  "$cmux_bin" send --workspace "$workspace_ref" --surface "$surface" "$name" >/dev/null
  if ! wait_for_prompt_visible "$surface" "$name"; then
    dismiss_rename_dialog "$surface" "$agent" "$name" || true
    echo "Opened the $agent rename prompt but could not type the name '$name'." >&2
    return 1
  fi
  if ! text="$(read_surface_visible_text "$surface")"; then
    dismiss_rename_dialog "$surface" "$agent" "$name" || true
    echo "Could not inspect the $agent rename dialog before confirming '$name'." >&2
    return 1
  fi
  baseline_successes="$(count_rename_success_markers "$text" "$name" || true)"
  baseline_index_rows="$(count_rename_index_rows "$name")"
  sleep "$enter_delay_seconds"
  for ((attempt = 1; attempt <= enter_retries; attempt++)); do
    "$cmux_bin" send-key --workspace "$workspace_ref" --surface "$surface" enter >/dev/null
    deadline=$((SECONDS + submit_confirm_wait_seconds))
    while true; do
      if ! text="$(read_surface_visible_text "$surface")"; then
        dismiss_rename_dialog "$surface" "$agent" "$name" || true
        echo "Could not inspect the $agent rename result for '$name'." >&2
        return 1
      fi
      successes="$(count_rename_success_markers "$text" "$name" || true)"
      if [[ "$successes" -gt "$baseline_successes" ]]; then
        return 0
      fi
      if [[ "$(count_rename_index_rows "$name")" -gt "$baseline_index_rows" ]]; then
        return 0
      fi
      (( SECONDS >= deadline )) && break
      sleep 1
    done
    if ! rename_dialog_is_active "$text" "$name"; then
      break
    fi
  done
  dismiss_rename_dialog "$surface" "$agent" "$name" || true
  echo "The $agent rename dialog did not confirm the session name '$name'." >&2
  return 1
}
