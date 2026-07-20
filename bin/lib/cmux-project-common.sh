#!/usr/bin/env bash
# shellcheck disable=SC2154

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

amq_candidate_paths() {
  local hints="${CMUX_PROJECT_LAUNCHER_AMQ_PATH_HINTS:-}"
  local old_ifs="$IFS"
  local hint
  IFS=:
  for hint in $hints; do
    [[ -z "$hint" ]] && continue
    if [[ -d "$hint" ]]; then
      printf '%s\n' "$hint/amq"
    else
      printf '%s\n' "$hint"
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
  if [[ -z "${amq_bin:-}" ]]; then
    amq_bin="amq"
  fi
  if [[ "$amq_bin" == */* ]]; then
    [[ -x "$amq_bin" ]]
    return $?
  fi

  while IFS= read -r candidate; do
    if [[ -x "$candidate" ]]; then
      amq_bin="$candidate"
      return 0
    fi
  done < <(amq_candidate_paths)

  found="$(command -v "$amq_bin" 2>/dev/null || true)"
  if [[ -n "$found" && -x "$found" ]]; then
    amq_bin="$found"
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
  local lock
  local pid
  local pid_status
  local command_line
  [[ -z "${amq_base_root:-}" ]] && return 1
  for agent in codex claude; do
    lock="$amq_base_root/$session/agents/$agent/.wake.lock"
    [[ -f "$lock" ]] || continue
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
  done
  return 1
}

session_in_use() {
  local session="$1"
  if wake_lock_active "$session"; then
    return 0
  fi
  session_active_in_who "$session" "$amq_who_state"
}

workspace_ref_for_title() {
  local title="$1"
  CMUX_BIN="$cmux_bin" /usr/bin/python3 - "$title" <<'PY'
import json
import os
import re
import subprocess
import sys

title = sys.argv[1]
cmux = os.environ["CMUX_BIN"]
candidates = []
seen_refs = set()
order = 0

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
        if workspace.get("title") != title:
            continue
        ref = workspace.get("ref")
        if not ref or ref in seen_refs:
            continue
        seen_refs.add(ref)
        index = workspace.get("index")
        if not isinstance(index, int):
            index = 999999
        selected = bool(workspace.get("selected"))
        candidates.append((0 if selected else 1, index, order, ref))
        order += 1

collect(run(["workspace", "list", "--json"]))
for line in run(["list-windows"]).splitlines():
    match = re.match(r"\*?\s*(\d+):", line)
    if match:
        collect(run(["workspace", "list", "--json", "--window", match.group(1)]))

if candidates:
    print(sorted(candidates)[0][3])
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
  local pane
  local surfaces
  for pane in "${panes[@]}"; do
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
  if [[ "$agent" == "codex" ]]; then
    printf '%s\n' 'Working|Explored|Ran |Read |Using the '
  else
    printf '%s\n' 'Running [0-9]+ shell command|Brewed for|thought for|Read |Wrote|Updated'
  fi
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

prompt_visible_in_input() {
  local surface="$1"
  local prompt="$2"
  local text
  if ! text="$(visible_input_region "$surface")"; then
    return 2
  fi
  if grep -Fq -- "$prompt" <<<"$text"; then
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
# Codex's `/rename` opens a "Type a name and press Enter" dialog. This state
# machine verifies that dialog before typing and requires Codex's success message
# after the final Enter. A disappearing composer alone is not rename proof.
rename_thread() {
  local surface="$1"
  local name="$2"
  local agent="$3"
  if ! submit_prompt "$surface" "/rename" "$agent"; then
    echo "Could not open the $agent rename prompt; leaving the session name unchanged." >&2
    return 1
  fi
  if ! wait_for_surface_literals "$surface" "Type a name and press Enter"; then
    echo "The $agent /rename command did not open its naming dialog; refusing to type '$name'." >&2
    return 1
  fi
  sleep "$enter_delay_seconds"
  "$cmux_bin" send --workspace "$workspace_ref" --surface "$surface" "$name" >/dev/null
  if ! wait_for_prompt_visible "$surface" "$name"; then
    echo "Opened the $agent rename prompt but could not type the name '$name'." >&2
    return 1
  fi
  sleep "$enter_delay_seconds"
  "$cmux_bin" send-key --workspace "$workspace_ref" --surface "$surface" enter >/dev/null
  if ! wait_for_surface_literals "$surface" "Session renamed to" "$name"; then
    echo "The $agent rename dialog closed without confirming the session name '$name'." >&2
    return 1
  fi
}
