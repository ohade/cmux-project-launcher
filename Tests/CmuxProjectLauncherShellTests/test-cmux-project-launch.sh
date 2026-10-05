#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Optional interpreter for the script-under-test. Empty = honor the script's own
# `#!/usr/bin/env bash` shebang (developer shell, usually Homebrew bash 5). Set
# CMUX_TEST_SCRIPT_BASH=/bin/bash to exercise the bash-3.2 path the GUI .app hits.
launch_bash="${CMUX_TEST_SCRIPT_BASH:-}"
tmp_dir="$(mktemp -d)"

fake_cmux="$tmp_dir/cmux"
fake_amq="$tmp_dir/amq"
fake_open="$tmp_dir/open"
fake_keepalive="$tmp_dir/amq-keepalive"
fake_ps="$tmp_dir/ps"
fake_amq_root="$tmp_dir/amq-root"
send_log="$tmp_dir/send.log"
key_log="$tmp_dir/key.log"
create_log="$tmp_dir/create.log"
layout_log="$tmp_dir/layout.log"
select_log="$tmp_dir/select.log"
open_log="$tmp_dir/open.log"
close_log="$tmp_dir/close.log"
keepalive_log="$tmp_dir/keepalive.log"
event_log="$tmp_dir/event.log"
stdout_log="$tmp_dir/stdout.log"
diagnostics_log="$tmp_dir/launcher.log"
descriptor_pid_log="$tmp_dir/descriptor-daemon.pids"
fake_helper_wake="$tmp_dir/fake-helper-wake"
helper_wakes="$tmp_dir/helper-wakes.tsv"
added_panes="$tmp_dir/added-panes"
background_pids=()
mkdir -p "$fake_amq_root"
export CMUX_PROJECT_LAUNCHER_LOG="$diagnostics_log"
export CMUX_FAKE_EVENT_LOG="$event_log"
export CMUX_FAKE_AMQ_ROOT="$fake_amq_root"
export CMUX_FAKE_HELPER_WAKE_SCRIPT="$fake_helper_wake"
export CMUX_FAKE_HELPER_WAKES="$helper_wakes"
export CMUX_FAKE_ADDED_PANES="$added_panes"
# The launcher reads Codex's session index as rename proof. Keep it hermetic:
# the real ~/.codex index can already hold a codex-demo-project row.
export CODEX_HOME="$tmp_dir/codex-home"
mkdir -p "$CODEX_HOME"
cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    printf 'fixture failed; last stdout/stderr follow\n' >&2
    [[ -f "$stdout_log" ]] && sed -n '1,240p' "$stdout_log" >&2
    [[ -f "$tmp_dir/stderr.log" ]] && sed -n '1,240p' "$tmp_dir/stderr.log" >&2
  fi
  if [[ "${#background_pids[@]}" -gt 0 ]]; then
    kill "${background_pids[@]}" 2>/dev/null || true
  fi
  if [[ -f "$descriptor_pid_log" ]]; then
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
    done <"$descriptor_pid_log"
  fi
  if [[ -f "$helper_wakes" ]]; then
    while IFS=$'\t' read -r pid _; do
      [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
    done <"$helper_wakes"
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

# Stands in for a coop helper (coopgrok, coopgemini, coopcursorcodex). The real
# amq-coop-agent-bootstrap registers the agent's AMQ wake on its own exact cmux
# surface once the agent is up; this writes the same .wake.lock and records the
# wake's command line for the fake ps. Usage: <session> <agent> <surface-id>.
cat >"$fake_helper_wake" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
session="${1:?missing session}"
agent="${2:?missing agent}"
surface_id="${3:?missing surface id}"
root="${CMUX_FAKE_AMQ_ROOT:?}/$session"
mkdir -p "$root/agents/$agent"
sleep 120 </dev/null >/dev/null 2>&1 &
pid=$!
printf '%s\t%s\t%s\tcmux:surface:%s\n' "$pid" "$agent" "$root" "$surface_id" >>"${CMUX_FAKE_HELPER_WAKES:?}"
printf '{"pid":%s,"root":"%s","agent":"%s"}\n' "$pid" "$root" "$agent" >"$root/agents/$agent/.wake.lock"
printf 'helper-wake\t%s\tcmux:surface:%s\n' "$agent" "$surface_id" >>"${CMUX_FAKE_EVENT_LOG:?}"
SH
chmod +x "$fake_helper_wake"

# An outer process can capture the launcher's stderr while the launcher duplicates
# that pipe to diagnostics fd 3. A long-lived wake descendant must not inherit fd 3,
# or the outer process waits forever for EOF even after the launcher exits.
descriptor_helper="$tmp_dir/descriptor-helper"
descriptor_probe="$tmp_dir/descriptor-probe"
cat >"$descriptor_helper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sleep 45 &
printf '%s\n' "$!" >>"${CMUX_FAKE_DESCRIPTOR_PID_LOG:?}"
printf 'wake-attached\n'
SH
chmod +x "$descriptor_helper"
cat >"$descriptor_probe" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$repo_root/bin/lib/cmux-project-common.sh"
exec 3>&2
capture_command_output result "$descriptor_helper"
printf '%s\n' "\$result"
SH
chmod +x "$descriptor_probe"
CMUX_FAKE_DESCRIPTOR_PID_LOG="$descriptor_pid_log" \
  /usr/bin/python3 - "$descriptor_probe" <<'PY'
import subprocess
import sys

completed = subprocess.run(
    [sys.argv[1]],
    capture_output=True,
    text=True,
    timeout=5,
    check=True,
)
assert completed.stdout.strip() == "wake-attached", completed
PY

cat >"$fake_cmux" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

id_format=refs
if [[ "${1:-}" == "--id-format" ]]; then
  id_format="${2:?missing id format}"
  shift 2
fi
cmd="${1:?missing command}"
shift

# One fixed pane per agent: pane, surface ref, surface id, tty, pane name.
fake_slot() {
  case "$1" in
    codex) printf 'pane:11 surface:26 11111111-1111-4111-8111-111111111111 ttys026 Codex' ;;
    claude) printf 'pane:12 surface:27 22222222-2222-4222-8222-222222222222 ttys027 Claude' ;;
    grok) printf 'pane:13 surface:28 33333333-3333-4333-8333-333333333333 ttys028 Grok' ;;
    gemini) printf 'pane:14 surface:29 44444444-4444-4444-8444-444444444444 ttys029 Gemini' ;;
    cursorcodex) printf 'pane:15 surface:30 55555555-5555-4555-8555-555555555555 ttys030 CursorCodex' ;;
    *) return 1 ;;
  esac
}
helper_agents=(grok gemini cursorcodex)

# The workspace's agents now: CMUX_FAKE_AGENT_ROSTER plus any pane new-pane added.
fake_roster_now() {
  local roster="${CMUX_FAKE_AGENT_ROSTER:-codex,claude}"
  local added
  if [[ -n "${CMUX_FAKE_ADDED_PANES:-}" && -s "$CMUX_FAKE_ADDED_PANES" ]]; then
    while IFS= read -r added; do
      [[ -n "$added" ]] && roster="$roster,$added"
    done <"$CMUX_FAKE_ADDED_PANES"
  fi
  printf '%s' "$roster"
}

# Play a helper agent's bootstrap: register its wake on its exact pane.
# CMUX_FAKE_HELPER_WAKE_SKIP lists helpers that never attach, _TARGET=wrong
# attaches them to another surface, and _DELAY attaches them late.
fake_attach_helper() {
  local agent="$1"
  local session="$2"
  local helper_surface_id
  [[ " ${helper_agents[*]} " == *" $agent "* ]] || return 0
  [[ ",${CMUX_FAKE_HELPER_WAKE_SKIP:-}," == *",$agent,"* ]] && return 0
  read -r _ _ helper_surface_id _ _ <<<"$(fake_slot "$agent")"
  if [[ "${CMUX_FAKE_HELPER_WAKE_TARGET:-exact}" == "wrong" ]]; then
    helper_surface_id=99999999-9999-4999-8999-999999999999
  fi
  if [[ -n "${CMUX_FAKE_HELPER_WAKE_DELAY:-}" ]]; then
    (
      sleep "$CMUX_FAKE_HELPER_WAKE_DELAY"
      "${CMUX_FAKE_HELPER_WAKE_SCRIPT:?}" "$session" "$agent" "$helper_surface_id"
    ) </dev/null >/dev/null 2>&1 &
  else
    "${CMUX_FAKE_HELPER_WAKE_SCRIPT:?}" "$session" "$agent" "$helper_surface_id"
  fi
}

case "$cmd" in
  workspace)
    subcmd="${1:?missing workspace subcommand}"
    shift
    case "$subcmd" in
      create)
        layout=""
        workspace_name=""
        description=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --name)
              workspace_name="${2:?missing name}"
              shift 2
              ;;
            --description)
              description="${2:?missing description}"
              shift 2
              ;;
            --layout)
              layout="${2:?missing layout}"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        expected_session="${CMUX_FAKE_EXPECT_SESSION:-demo-project}"
        expected_project="${CMUX_FAKE_EXPECT_PROJECT:-demo-project}"
        [[ "$workspace_name" == "$expected_project" ]]
        [[ "$description" == "Project launcher: $expected_project (AMQ session: $expected_session)" ]]
        # CMUX_FAKE_AGENT_ROSTER names the agents this fake workspace holds; the
        # default is the Codex + Claude pair every pre-roster case launches.
        fake_roster=",${CMUX_FAKE_AGENT_ROSTER:-codex,claude},"
        if [[ "$fake_roster" == *",codex,"* ]]; then
          [[ "$layout" == *"amq_codex $expected_session"* ]]
          # Codex has no boot flag, so its command must NOT carry a --name.
          [[ "$layout" != *"amq_codex $expected_session --name"* ]]
        else
          [[ "$layout" != *"amq_codex"* ]]
        fi
        if [[ "$fake_roster" == *",claude,"* ]]; then
          [[ "$layout" == *"amq_claude $expected_session"* ]]
          # Claude is named at boot via `--name claude-<session>` forwarded through amq_claude.
          [[ "$layout" == *"amq_claude $expected_session -- --name claude-$expected_session"* ]]
        else
          [[ "$layout" != *"amq_claude"* ]]
        fi
        # Only Codex and Claude start with the launcher's wake-off prefix.
        if [[ "$fake_roster" == *",codex,"* || "$fake_roster" == *",claude,"* ]]; then
          [[ "$layout" == *"AMQ_COOP_WAKE_FLAG=--no-wake"* ]]
          [[ "$layout" == *"AMQ_KEEPALIVE_DISABLED=1"* ]]
        fi
        # A helper agent starts exactly as typed, so its own bootstrap attaches its wake.
        for agent in "${helper_agents[@]}"; do
          if [[ "$fake_roster" == *",$agent,"* ]]; then
            [[ "$layout" == *"zsh -ic 'coop$agent $expected_session'"* ]]
          else
            [[ "$layout" != *"coop$agent"* ]]
          fi
        done
        [[ "$layout" != *"AMQ_COOP_WAKE_FLAG=--defer-wake"* ]]
        [[ "$layout" != *"AMQ_KEEPALIVE_BIN="* ]]
        [[ "$layout" != *"coopcodex $expected_session"* ]]
        [[ "$layout" != *"coopcc $expected_session"* ]]
        [[ "$layout" != *"amq coop exec"* ]]
        [[ "$layout" != *"--require-wake"* ]]
        if [[ -n "${CMUX_FAKE_LAYOUT_LOG:-}" ]]; then
          printf '%s\n%s\n' "$description" "$layout" >>"$CMUX_FAKE_LAYOUT_LOG"
        fi
        printf 'workspace-create\t%s\n' "$expected_session" >>"${CMUX_FAKE_EVENT_LOG:?}"
        printf '%s\n' "$expected_session" >>"${CMUX_FAKE_CREATE_LOG:?}"
        for agent in "${helper_agents[@]}"; do
          [[ "$fake_roster" == *",$agent,"* ]] && fake_attach_helper "$agent" "$expected_session"
        done
        printf 'OK workspace:10\n'
        ;;
      list)
        case "${CMUX_FAKE_WORKSPACE_LIST_MODE:-empty}" in
          demo-project)
            cat <<'JSON'
{
  "window_ref": "window:1",
  "workspaces": [
    {"ref":"workspace:1","title":"other","selected":false},
    {"ref":"workspace:7","title":"demo-project","description":"Project launcher: demo-project (AMQ session: demo-project)","selected":false}
  ]
}
JSON
            ;;
          multi)
            cat <<'JSON'
{
  "window_ref": "window:1",
  "workspaces": [
    {"ref":"workspace:4","title":"demo-project","description":"Project launcher: demo-project (AMQ session: demo-project)","selected":false,"index":4},
    {"ref":"workspace:7","title":"demo-project","description":"Project launcher: demo-project (AMQ session: demo-project)","selected":true,"index":7}
  ]
}
JSON
            ;;
          title-collision)
            cat <<'JSON'
{
  "window_ref": "window:1",
  "workspaces": [
    {"ref":"workspace:7","title":"demo-project","description":"Manually named workspace","selected":false,"index":7}
  ]
}
JSON
            ;;
          suffixed-project)
            cat <<'JSON'
{
  "window_ref": "window:1",
  "workspaces": [
    {"ref":"workspace:8","title":"demo-project-2","description":"Project launcher: demo-project (AMQ session: demo-project-2)","selected":false,"index":8,"latest_submitted_at":"2026-07-21T08:40:00Z"}
  ]
}
JSON
            ;;
          suffixed-duplicates)
            cat <<'JSON'
{
  "window_ref": "window:1",
  "workspaces": [
    {"ref":"workspace:7","title":"demo-project-2","description":"Project launcher: demo-project (AMQ session: demo-project-2)","selected":false,"index":7,"latest_submitted_at":null},
    {"ref":"workspace:8","title":"demo-project-2","description":"Project launcher: demo-project (AMQ session: demo-project-2)","selected":false,"index":8,"latest_submitted_at":"2026-07-21T08:41:00Z"}
  ]
}
JSON
            ;;
          expected-project)
            printf '{"window_ref":"window:1","workspaces":[{"ref":"workspace:7","title":"%s","description":"Project launcher: %s (AMQ session: %s)","selected":false}]}\n' \
              "${CMUX_FAKE_EXPECT_PROJECT:?}" "$CMUX_FAKE_EXPECT_PROJECT" "${CMUX_FAKE_EXPECT_SESSION:?}"
            ;;
          error)
            printf 'workspace list failed\n' >&2
            exit 70
            ;;
          *)
            cat <<'JSON'
{"window_ref":"window:1","workspaces":[]}
JSON
            ;;
        esac
        ;;
      close)
        printf '%s\n' "${1:?missing workspace}" >>"${CMUX_FAKE_CLOSE_LOG:?}"
        printf 'OK %s\n' "$1"
        ;;
      select)
        if [[ "${CMUX_FAKE_SELECT_FAIL:-0}" == "1" ]]; then
          printf 'select failed\n' >&2
          exit 70
        fi
        printf '%s\n' "${1:?missing workspace}" >>"${CMUX_FAKE_SELECT_LOG:?}"
        printf 'OK %s\n' "${1:?missing workspace}"
        ;;
      *)
        printf 'unexpected workspace subcommand: %s\n' "$subcmd" >&2
        exit 64
        ;;
    esac
    ;;
  list-windows)
    printf '* 0: window:1 [selected]\n'
    printf '1: window:2\n'
    ;;
  list-panes)
    roster_now="$(fake_roster_now)"
    case "$roster_now" in
      codex)
        printf '* pane:11 [1 surface] [focused]\n'
        ;;
      claude)
        printf '* pane:12 [1 surface] [focused]\n'
        ;;
      *grok*|*gemini*|*cursorcodex*)
        for agent in ${roster_now//,/ }; do
          read -r slot_pane _ <<<"$(fake_slot "$agent")"
          printf '%s [1 surface]\n' "$slot_pane"
        done
        ;;
      *)
        printf '* pane:12 [1 surface] [focused]\n'
        printf 'pane:11 [1 surface]\n'
        ;;
    esac
    ;;
  list-pane-surfaces)
    pane=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --pane)
          pane="${2:?missing pane}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ "${CMUX_FAKE_SURFACE_LIST_MODE:-ok}" == "partial-error" && "$pane" == "pane:11" ]]; then
      printf 'surface:26 11111111-1111-4111-8111-111111111111 Codex\n'
      printf 'surface enumeration failed\n' >&2
      exit 70
    fi
    case "$pane" in
      pane:12)
        if [[ "$id_format" == "both" ]]; then
          printf '* surface:27 22222222-2222-4222-8222-222222222222 Claude [selected]\n'
        else
          printf '* surface:27 Claude [selected]\n'
        fi
        ;;
      pane:11)
        if [[ "$id_format" == "both" ]]; then
          printf 'surface:26 11111111-1111-4111-8111-111111111111 Codex\n'
        else
          printf 'surface:26 Codex\n'
        fi
        ;;
      pane:13|pane:14|pane:15)
        for agent in "${helper_agents[@]}"; do
          read -r slot_pane slot_surface slot_id _ slot_name <<<"$(fake_slot "$agent")"
          [[ "$slot_pane" == "$pane" ]] || continue
          # A pane new-pane added is a plain "Terminal" until rename-tab names it.
          if [[ ",${CMUX_FAKE_AGENT_ROSTER:-codex,claude}," != *",$agent,"* ]] \
            && ! grep -Fxq $'rename-tab\t'"$slot_surface"$'\t'"$slot_name" "${CMUX_FAKE_EVENT_LOG:?}" 2>/dev/null; then
            slot_name=Terminal
          fi
          if [[ "$id_format" == "both" ]]; then
            printf '%s %s %s\n' "$slot_surface" "$slot_id" "$slot_name"
          else
            printf '%s %s\n' "$slot_surface" "$slot_name"
          fi
        done
        ;;
      "")
        # Real cmux defaults to the focused pane when --pane is omitted.
        if [[ "${CMUX_FAKE_AGENT_ROSTER:-codex,claude}" == "codex" ]]; then
          if [[ "$id_format" == "both" ]]; then
            printf '* surface:26 11111111-1111-4111-8111-111111111111 Codex [selected]\n'
          else
            printf '* surface:26 Codex [selected]\n'
          fi
        elif [[ "$id_format" == "both" ]]; then
          printf '* surface:27 22222222-2222-4222-8222-222222222222 Claude [selected]\n'
        else
          printf '* surface:27 Claude [selected]\n'
        fi
        ;;
      *)
        printf 'unexpected pane: %s\n' "$pane" >&2
        exit 64
        ;;
    esac
    ;;
  read-screen)
    surface=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --surface)
          surface="${2:?missing surface}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ "${CMUX_FAKE_MODE:-ready}" == "shell" ]]; then
      printf 'Last login: Fri Jun 5 on ttys027\n'
      printf '$ ~/git/demo-project\n'
    elif [[ "${CMUX_FAKE_MODE:-ready}" == "commandline" ]]; then
      printf "cd /Users/example/git && zsh -ic 'coopcodex demo-project'\n"
      printf "cd /Users/example/git && zsh -ic 'coopcc demo-project'\n"
    else
      payload="$(awk -F '\t' -v surface="$surface" '$1 == surface { value = $2 } END { print value }' "${CMUX_FAKE_SEND_LOG:?}" 2>/dev/null || true)"
      # Model each send/Enter cycle independently: the most recent send stays visible
      # in the input region until an Enter for that surface submits it. Using send vs
      # Enter counts (rather than a single Enter count) lets one surface run multiple
      # submit cycles in a launch, e.g. the Codex /rename pair followed by $start.
      send_count="$(awk -F '\t' -v surface="$surface" '$1 == surface { count++ } END { print count + 0 }' "${CMUX_FAKE_SEND_LOG:?}" 2>/dev/null || true)"
      key_count="$(awk -F '\t' -v surface="$surface" '$1 == surface { count++ } END { print count + 0 }' "${CMUX_FAKE_KEY_LOG:?}" 2>/dev/null || true)"
      case "$surface" in
        surface:26)
          printf 'OpenAI Codex\n'
          printf 'gpt-5.6-sol xhigh fast - ~/git - Read\n'
          ;;
        surface:27)
          printf 'Welcome to Claude Code\n'
          printf 'Opus 4.8 bypass permissions\n'
          ;;
      esac
      if [[ "$surface" == "surface:26" ]]; then
        rename_mode="${CMUX_FAKE_RENAME_MODE:-success}"
        rename_retry_keys=0
        if [[ "$rename_mode" == "missed-enter" ]]; then
          rename_retry_keys=1
        fi
        rename_name="$(awk -F '\t' -v surface="$surface" '$1 == surface { count++; if (count == 2) print $2 }' "${CMUX_FAKE_SEND_LOG:?}" 2>/dev/null || true)"
        last_key="$(awk -F '\t' -v surface="$surface" '$1 == surface { key = $2 } END { print key }' "${CMUX_FAKE_KEY_LOG:?}" 2>/dev/null || true)"
        if [[ "$last_key" == "escape" ]]; then
          printf '> \n'
        elif [[ "$send_count" -eq 0 ]]; then
          printf '> \n'
        elif [[ "$send_count" -eq 1 && "$key_count" -eq 0 ]]; then
          printf '> /rename\n'
        elif [[ "$send_count" -eq 1 ]]; then
          if [[ "$rename_mode" == "late-modal" ]]; then
            # Observed live 2026-09-08 (Gate 4 run C): /rename is accepted but the
            # modal renders AFTER open_rename_dialog gives up. dismiss_rename_dialog
            # then reads a modal-free screen, concludes there is nothing to dismiss,
            # and returns 0 without sending Escape. The modal appears a moment later
            # and the Codex pane is stuck on "Type a name and press Enter" forever.
            read_count_file="${CMUX_FAKE_SEND_LOG:?}.late-modal-reads"
            read_count="$(cat "$read_count_file" 2>/dev/null || printf 0)"
            read_count=$((read_count + 1))
            printf '%s' "$read_count" >"$read_count_file"
            if [[ "$read_count" -le 6 ]]; then
              printf '> \n'
            else
              printf 'Name thread\nType a name and press Enter\n> \n'
            fi
          elif [[ "$rename_mode" == "no-modal" ]]; then
            printf '> \n'
          elif [[ "$rename_mode" == "slash-still-visible" ]]; then
            # Live Codex can keep "/rename" in the composer after the modal
            # opens. Extra Enters from submit_prompt then land in the dialog.
            printf 'Name thread\nType a name and press Enter\n> /rename\n'
          else
            printf 'Name thread\nType a name and press Enter\n> \n'
          fi
        elif [[ "$send_count" -eq 2 && "$key_count" -eq 1 ]]; then
          printf 'Name thread\n> %s\n' "$rename_name"
        elif [[ "$send_count" -eq 2 && "$key_count" -eq 2 ]]; then
          if [[ "$rename_mode" == "vanished" ]]; then
            printf '> \n'
          elif [[ "$rename_mode" == "index-success" ]]; then
            # Codex 0.155.1 (Gate 4, 2026-09-23): the dialog closes with no
            # "Session renamed to" line; the name lands in session_index.jsonl.
            index_file="${CODEX_HOME:?}/session_index.jsonl"
            if ! grep -Fq "\"thread_name\":\"$rename_name\"" "$index_file" 2>/dev/null; then
              printf '{"id":"fake-thread","thread_name":"%s","updated_at":"2026-09-23T10:54:01Z"}\n' \
                "$rename_name" >>"$index_file"
            fi
            printf '> \n'
          elif [[ "$rename_mode" == "stale-modal" ]]; then
            printf 'Name thread\n> %s\nPress enter to confirm\n> ordinary prompt\n' "$rename_name"
          elif [[ "$rename_mode" == "missed-enter" || "$rename_mode" == "no-success" ]]; then
            printf 'Name thread\n> %s\nPress enter to confirm\n' "$rename_name"
          elif [[ "$rename_mode" == "footer-displaced" ]]; then
            # Live Codex can print a warning under the confirm footer. The
            # footer is then not the last non-blank line.
            printf 'Name thread\n> %s\nPress enter to confirm\nwarning: cannot confirm codex CLI session "%s/codex" (sqlite3 query\n' \
              "$rename_name" "$rename_name"
          elif [[ "$rename_mode" == "wrapped-success" ]]; then
            printf 'Session renamed to %s\n%s. To resume this session run codex resume %s\n> \n' \
              "${rename_name%-*}-" "${rename_name##*-}" "$rename_name"
          else
            printf 'Session renamed to %s. To resume this session run codex resume %s\n> \n' "$rename_name" "$rename_name"
          fi
        elif [[ "$send_count" -eq 2 ]]; then
          if [[ "$rename_mode" == "no-success" ]]; then
            printf 'Name thread\n> %s\nPress enter to confirm\n' "$rename_name"
          elif [[ "$rename_mode" == "footer-displaced" ]]; then
            printf 'Name thread\n> %s\nPress enter to confirm\nwarning: cannot confirm codex CLI session "%s/codex" (sqlite3 query\n' \
              "$rename_name" "$rename_name"
          elif [[ "$rename_mode" == "wrapped-success" ]]; then
            printf 'Session renamed to %s\n%s. To resume this session run codex resume %s\n> \n' \
              "${rename_name%-*}-" "${rename_name##*-}" "$rename_name"
          else
            printf 'Session renamed to %s. To resume this session run codex resume %s\n> \n' "$rename_name" "$rename_name"
          fi
        elif [[ "$send_count" -ge 3 && "$key_count" -eq $((send_count - 1 + rename_retry_keys)) ]]; then
          printf '> %s\n' "$payload"
        else
          printf 'Working on request\n> \n'
        fi
      elif [[ -n "$payload" && "$send_count" -gt "$key_count" ]]; then
        printf '> %s\n' "$payload"
      elif [[ -n "$payload" ]]; then
        printf 'Running 1 shell command\n'
        printf '> \n'
      else
        printf '> \n'
      fi
    fi
    ;;
  debug-terminals)
    if [[ "${CMUX_FAKE_DEBUG_MODE:-ok}" == "error" ]]; then
      printf 'debug failed\n' >&2
      exit 70
    fi
    runtime_workspace="${CMUX_FAKE_RUNTIME_WORKSPACE:-workspace:10}"
    if [[ "${CMUX_FAKE_MODE:-ready}" == "dead" ]]; then
      printf '[0] surface:26 "Codex" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:11\n' "$runtime_workspace"
      printf '    runtime=0 focused=1 selected=1 terminal=0x1 ghostty=nil\n'
      printf '    tty=nil cwd=/Users/example/git\n'
      printf '[1] surface:27 "Claude" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:12\n' "$runtime_workspace"
      printf '    runtime=0 focused=0 selected=1 terminal=0x2 ghostty=nil\n'
      printf '    tty=nil cwd=/Users/example/git\n'
    elif [[ "${CMUX_FAKE_MODE:-ready}" == "ghostty-no-tty" ]]; then
      printf '[0] surface:26 "Codex" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:11\n' "$runtime_workspace"
      printf '    runtime=1 focused=1 selected=1 terminal=0x1 ghostty=0x2\n'
      printf '    tty=nil cwd=/Users/example/git\n'
      printf '[1] surface:27 "Claude" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:12\n' "$runtime_workspace"
      printf '    runtime=1 focused=0 selected=1 terminal=0x3 ghostty=0x4\n'
      printf '    tty=nil cwd=/Users/example/git\n'
    elif [[ "${CMUX_FAKE_MODE:-ready}" == "codex-no-tty" ]]; then
      printf '[0] surface:26 "Codex" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:11\n' "$runtime_workspace"
      printf '    runtime=1 focused=1 selected=1 terminal=0x1 ghostty=0x2\n'
      printf '    tty=nil cwd=/Users/example/git\n'
      printf '[1] surface:27 "Claude" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:12\n' "$runtime_workspace"
      printf '    runtime=1 focused=0 selected=1 terminal=0x3 ghostty=0x4\n'
      printf '    tty=ttys027 cwd=/Users/example/git\n'
    elif [[ "${CMUX_FAKE_MODE:-ready}" == "ghostty-only" ]]; then
      printf '[0] surface:26 "Codex" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:11\n' "$runtime_workspace"
      printf '    runtime=1 focused=1 selected=1 terminal=0x1 ghostty=0x2\n'
      printf '[1] surface:27 "Claude" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:12\n' "$runtime_workspace"
      printf '    runtime=1 focused=0 selected=1 terminal=0x3 ghostty=0x4\n'
    else
      fake_roster=",$(fake_roster_now),"
      if [[ "$fake_roster" == *",codex,"* ]]; then
        printf '[0] surface:26 "Codex" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:11\n' "$runtime_workspace"
        printf '    runtime=1 focused=1 selected=1 terminal=0x1 ghostty=0x2\n'
        printf '    tty=ttys026 cwd=/Users/example/git\n'
      fi
      if [[ "$fake_roster" == *",claude,"* ]]; then
        printf '[1] surface:27 "Claude" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:12\n' "$runtime_workspace"
        printf '    runtime=1 focused=0 selected=1 terminal=0x3 ghostty=0x4\n'
        printf '    tty=ttys027 cwd=/Users/example/git\n'
      fi
      block_index=2
      for agent in "${helper_agents[@]}"; do
        [[ "$fake_roster" == *",$agent,"* ]] || continue
        read -r slot_pane slot_surface _ slot_tty slot_name <<<"$(fake_slot "$agent")"
        printf '[%s] %s "%s" mapped=1 tree=1 window=window:1 workspace=%s pane=%s\n' \
          "$block_index" "$slot_surface" "$slot_name" "$runtime_workspace" "$slot_pane"
        printf '    runtime=1 focused=0 selected=1 terminal=0x5 ghostty=0x6\n'
        printf '    tty=%s cwd=/Users/example/git\n' "$slot_tty"
        block_index=$((block_index + 1))
      done
    fi
    ;;
  new-pane)
    # Real cmux 0.64.25 prints "OK surface:N pane:M workspace:W" (probed 2026-10-05).
    target_workspace=""
    pane_command=""
    pane_focus=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --workspace)
          target_workspace="${2:?missing workspace}"
          shift 2
          ;;
        --command)
          pane_command="${2:?missing command}"
          shift 2
          ;;
        --focus)
          pane_focus="${2:?missing focus}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [[ "$target_workspace" == "${CMUX_FAKE_RUNTIME_WORKSPACE:-workspace:10}" ]]
    [[ "$pane_focus" == "false" ]]
    case "$pane_command" in
      *"amq_codex "*) agent=codex ;;
      *"amq_claude "*) agent=claude ;;
      *"zsh -ic 'coopgrok "*) agent=grok ;;
      *"zsh -ic 'coopgemini "*) agent=gemini ;;
      *"zsh -ic 'coopcursorcodex "*) agent=cursorcodex ;;
      *)
        printf 'unexpected new-pane command: %s\n' "$pane_command" >&2
        exit 64
        ;;
    esac
    printf '%s\n' "$agent" >>"${CMUX_FAKE_ADDED_PANES:?}"
    printf 'new-pane\t%s\t%s\n' "$agent" "$pane_command" >>"${CMUX_FAKE_EVENT_LOG:?}"
    read -r slot_pane slot_surface _ _ _ <<<"$(fake_slot "$agent")"
    fake_attach_helper "$agent" "${CMUX_FAKE_EXPECT_SESSION:-demo-project}"
    printf 'OK %s %s %s\n' "$slot_surface" "$slot_pane" "$target_workspace"
    ;;
  rename-tab)
    surface=""
    title="${!#}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --surface)
          surface="${2:?missing surface}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    printf 'rename-tab\t%s\t%s\n' "$surface" "$title" >>"${CMUX_FAKE_EVENT_LOG:?}"
    printf 'OK action=rename tab=tab:%s\n' "${surface#surface:}"
    ;;
  close-surface)
    surface=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --surface)
          surface="${2:?missing surface}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    printf 'close-surface\t%s\n' "$surface" >>"${CMUX_FAKE_EVENT_LOG:?}"
    printf 'OK\n'
    ;;
  focus-pane|refresh-surfaces)
    printf 'OK\n'
    ;;
  send)
    surface=""
    payload="${!#}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --surface)
          surface="${2:?missing surface}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    printf '%s\t%s\n' "$surface" "$payload" >>"${CMUX_FAKE_SEND_LOG:?}"
    printf 'send\t%s\t%s\n' "$surface" "$payload" >>"${CMUX_FAKE_EVENT_LOG:?}"
    ;;
  send-key)
    surface=""
    key="${!#}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --surface)
          surface="${2:?missing surface}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    printf '%s\t%s\n' "$surface" "$key" >>"${CMUX_FAKE_KEY_LOG:?}"
    printf 'key\t%s\t%s\n' "$surface" "$key" >>"${CMUX_FAKE_EVENT_LOG:?}"
    ;;
  *)
    printf 'unexpected command: %s\n' "$cmd" >&2
    exit 64
    ;;
esac
SH
chmod +x "$fake_cmux"

cat >"$fake_amq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

command="${1:?missing command}"
shift
original_args=("$@")
case "$command" in
  who)
    if [[ "${CMUX_FAKE_AMQ_WHO_MODE:-empty}" == "demo-project-active" ]]; then
      cat <<'JSON'
[
  {"name":"demo-project","agents":[{"handle":"codex","active":true},{"handle":"claude","active":true}]},
  {"name":"demo-project-2","agents":[{"handle":"codex","active":true},{"handle":"claude","active":false}]},
  {"name":"demo-project-3","agents":[{"handle":"codex","active":false},{"handle":"claude","active":false}]}
]
JSON
    elif [[ "${CMUX_FAKE_AMQ_WHO_MODE:-empty}" == "expected-active" ]]; then
      printf '[{"name":"%s","agents":[{"handle":"claude","active":true}]}]\n' "${CMUX_FAKE_EXPECT_SESSION:?}"
    else
      printf '[]\n'
    fi
    ;;
  env)
    cat <<JSON
{"base_root":"$CMUX_FAKE_AMQ_ROOT","root":"$CMUX_FAKE_AMQ_ROOT"}
JSON
    ;;
  init)
    if [[ -n "${CMUX_FAKE_AMQ_INIT_ENTERED:-}" ]]; then
      : >"$CMUX_FAKE_AMQ_INIT_ENTERED"
      while [[ ! -f "${CMUX_FAKE_AMQ_INIT_RELEASE:?}" ]]; do
        sleep 0.01
      done
    fi
    if [[ "${CMUX_FAKE_AMQ_INIT_FAIL:-0}" == "1" ]]; then
      printf 'fixture init failed\n' >&2
      exit 71
    fi
    root=""
    agents=""
    force=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --root)
          root="${2:?missing root}"
          shift 2
          ;;
        --agents)
          agents="${2:?missing agents}"
          shift 2
          ;;
        --force)
          force=$'\tforce'
          shift
          ;;
        *)
          printf 'unexpected init argument: %s\n' "$1" >&2
          exit 64
          ;;
      esac
    done
    [[ -n "$root" ]]
    [[ "$agents" == "${CMUX_FAKE_EXPECT_ROSTER:-claude,codex,user}" ]]
    if [[ -n "${CMUX_PROJECT_LAUNCHER_REAL_AMQ:-}" ]]; then
      "$CMUX_PROJECT_LAUNCHER_REAL_AMQ" init "${original_args[@]}"
    else
      mkdir -p "$root/meta"
      old_ifs="$IFS"
      IFS=','
      # Intentional splitting of the fixture's asserted comma-separated roster.
      for agent in $agents; do
        mkdir -p \
          "$root/agents/$agent/inbox/tmp" \
          "$root/agents/$agent/inbox/new" \
          "$root/agents/$agent/inbox/cur" \
          "$root/agents/$agent/outbox/sent" \
          "$root/agents/$agent/dlq/tmp" \
          "$root/agents/$agent/dlq/new" \
          "$root/agents/$agent/dlq/cur" \
          "$root/agents/$agent/receipts"
      done
      IFS="$old_ifs"
      config_agents="$(printf '%s' "$agents" | sed 's/,/","/g')"
      printf '{"agents":["%s"]}\n' "$config_agents" >"$root/meta/config.json"
    fi
    printf 'init\t%s\t%s%s\n' "$root" "$agents" "$force" >>"${CMUX_FAKE_EVENT_LOG:?}"
    ;;
  doctor)
    root=""
    json=0
    schema=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --root)
          root="${2:?missing root}"
          shift 2
          ;;
        --json)
          json=1
          shift
          ;;
        --json-schema=2)
          schema=2
          shift
          ;;
        *)
          printf 'unexpected doctor argument: %s\n' "$1" >&2
          exit 64
          ;;
      esac
    done
    [[ -n "$root" ]]
    [[ "$json" -eq 1 ]]
    [[ "$schema" -eq 2 ]]
    printf 'doctor\t%s\n' "$root" >>"${CMUX_FAKE_EVENT_LOG:?}"
    if [[ -n "${CMUX_FAKE_AMQ_DOCTOR_EXIT:-}" ]]; then
      exit "$CMUX_FAKE_AMQ_DOCTOR_EXIT"
    fi
    if [[ -n "${CMUX_PROJECT_LAUNCHER_REAL_AMQ:-}" ]]; then
      exec "$CMUX_PROJECT_LAUNCHER_REAL_AMQ" doctor "${original_args[@]}"
    fi
    case "${CMUX_FAKE_AMQ_DOCTOR_MODE:-healthy}" in
      healthy)
        # A helper agent the room's config lists has a healthy mailbox too.
        helper_mailboxes=""
        for agent in grok gemini cursorcodex; do
          if grep -Fq "\"$agent\"" "$root/meta/config.json" 2>/dev/null; then
            helper_mailboxes="$helper_mailboxes,{\"handle\":\"$agent\",\"provenance\":\"configured_and_discovered\",\"status\":\"ok\",\"issues\":[]}"
          fi
        done
        printf '%s%s]}\n' \
          '{"checks":[{"name":"Config","status":"ok"},{"name":"Mailboxes","status":"ok"}],"mailboxes":[{"handle":"claude","provenance":"configured_and_discovered","status":"ok","issues":[]},{"handle":"codex","provenance":"configured_and_discovered","status":"ok","issues":[]},{"handle":"user","provenance":"configured_and_discovered","status":"ok","issues":[]}' \
          "$helper_mailboxes"
        ;;
      config-error)
        cat <<'JSON'
{"checks":[{"name":"Config","status":"error","message":"invalid config fixture"},{"name":"Mailboxes","status":"error","message":"invalid config fixture"}],"mailboxes":[]}
JSON
        ;;
      mailboxes-error)
        cat <<'JSON'
{"checks":[{"name":"Config","status":"ok"},{"name":"Mailboxes","status":"error","message":"missing mailbox paths"}],"mailboxes":[{"handle":"claude","provenance":"configured_and_discovered","status":"error","issues":["missing:inbox/tmp"]}]}
JSON
        ;;
      wrong-agent)
        cat <<'JSON'
{"checks":[{"name":"Config","status":"ok"},{"name":"Mailboxes","status":"ok"}],"mailboxes":[{"handle":"claude","provenance":"configured_and_discovered","status":"ok","issues":[]},{"handle":"user","provenance":"configured_and_discovered","status":"ok","issues":[]}]}
JSON
        ;;
      *)
        printf 'unknown fake doctor mode\n' >&2
        exit 64
        ;;
    esac
    ;;
  list)
    if [[ "${CMUX_FAKE_AMQ_LIST_MODE:-success}" != "success" ]]; then
      printf 'list failed\n' >&2
      exit 70
    fi
    agent=""
    limit=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --me)
          agent="${2:?missing agent}"
          shift 2
          ;;
        --limit)
          limit="${2:?missing limit}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [[ "$limit" == "1" ]]
    printf 'list\t%s\n' "$agent" >>"${CMUX_FAKE_EVENT_LOG:?}"
    case "$agent" in
      codex) unread="${CMUX_FAKE_UNREAD_CODEX:-0}" ;;
      claude) unread="${CMUX_FAKE_UNREAD_CLAUDE:-0}" ;;
      *) exit 64 ;;
    esac
    if [[ "$unread" -eq 0 ]]; then
      printf '[]\n'
    else
      printf '[{"id":"fixture-unread"}]\n'
    fi
    ;;
  wake)
    sleep 120
    ;;
  *)
    printf 'unexpected amq command: %s\n' "$command" >&2
    exit 64
    ;;
esac
SH
chmod +x "$fake_amq"

cat >"$fake_ps" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

pid=""
tty=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      pid="${2:?missing pid}"
      shift 2
      ;;
    -t)
      tty="${2:?missing tty}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -n "$pid" ]]; then
  if [[ "$pid" == "${CMUX_FAKE_CODEX_WAKE_PID:-}" ]]; then
    agent=codex
    target="cmux:surface:${CMUX_FAKE_CODEX_SURFACE_ID:-11111111-1111-4111-8111-111111111111}"
  elif [[ "$pid" == "${CMUX_FAKE_CLAUDE_WAKE_PID:-}" ]]; then
    agent=claude
    target="cmux:surface:${CMUX_FAKE_CLAUDE_SURFACE_ID:-22222222-2222-4222-8222-222222222222}"
  else
    # A wake the fake coop helper registered: pid, agent, root, target.
    helper_row="$(awk -F '\t' -v pid="$pid" '$1 == pid { print; exit }' "${CMUX_FAKE_HELPER_WAKES:?}" 2>/dev/null || true)"
    [[ -n "$helper_row" ]] || exit 1
    IFS=$'\t' read -r _ agent helper_root target <<<"$helper_row"
    printf '/tmp/amq wake -root %s -me %s -inject-via /tmp/amq-keepalive -inject-arg inject -inject-arg cmux -inject-arg %s\n' \
      "$helper_root" "$agent" "$target"
    exit 0
  fi
  root="${CMUX_FAKE_WAKE_COMMAND_ROOT:-${CMUX_FAKE_AMQ_ROOT:?}/${CMUX_FAKE_WAKE_SESSION:?}}"
  printf '/tmp/amq wake -root %s -me %s -inject-via /tmp/amq-keepalive -inject-arg inject -inject-arg cmux -inject-arg %s\n' \
    "$root" "$agent" "$target"
  exit 0
fi

# CMUX_FAKE_SHELL_TTYS lists ttys whose agent has exited back to the shell.
if [[ ",${CMUX_FAKE_SHELL_TTYS:-}," == *",$tty,"* ]]; then
  printf '/bin/zsh -l\n'
  exit 0
fi

case "${CMUX_FAKE_AGENT_PROCESS_MODE:-ready}:$tty" in
  ready:ttys026)
    printf '/Users/example/.local/bin/codex-pretty --enable hooks\n'
    ;;
  ready:ttys027)
    printf '/opt/homebrew/bin/claude --session-id fixture\n'
    ;;
  # The Cursor CLI renames its node process to the name it was started by.
  ready:ttys028)
    printf '/Users/example/.local/bin/agent --model grok-4.7-xhigh\n'
    ;;
  ready:ttys029)
    printf 'node /opt/homebrew/bin/gemini\n'
    ;;
  ready:ttys030)
    printf 'cursor-agent --model gpt-5.6-sol-xhigh\n'
    ;;
  shell:*)
    printf '/bin/zsh -l\n'
    ;;
  error:*)
    printf 'ps failed\n' >&2
    exit 70
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$fake_ps"
export CMUX_PROJECT_LAUNCHER_PS="$fake_ps"

# setup_fake_wakes <session> [agent...]: launcher-attached wakes for Codex and/or
# Claude (default: both), bound to their fixed surfaces. Pass only the agents the
# room has: a wake creates the agent's folder, and real `amq doctor` flags a
# mailbox folder for an agent the room's config does not list.
setup_fake_wakes() {
  local session="$1"
  local session_root="$fake_amq_root/$session"
  local agent
  local wake_pid
  shift
  [[ "$#" -gt 0 ]] || set -- codex claude
  unset CMUX_FAKE_CODEX_WAKE_PID CMUX_FAKE_CLAUDE_WAKE_PID
  for agent in "$@"; do
    mkdir -p "$session_root/agents/$agent"
    sleep 120 &
    wake_pid=$!
    background_pids+=("$wake_pid")
    printf '{"pid":%s,"root":"%s","agent":"%s"}\n' "$wake_pid" "$session_root" "$agent" \
      >"$session_root/agents/$agent/.wake.lock"
    case "$agent" in
      codex) export CMUX_FAKE_CODEX_WAKE_PID="$wake_pid" ;;
      claude) export CMUX_FAKE_CLAUDE_WAKE_PID="$wake_pid" ;;
    esac
  done
  export CMUX_FAKE_WAKE_SESSION="$session"
  unset CMUX_FAKE_WAKE_COMMAND_ROOT
}

cat >"$fake_open" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${CMUX_FAKE_OPEN_LOG:?}"
SH
chmod +x "$fake_open"

cat >"$fake_keepalive" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${CMUX_FAKE_KEEPALIVE_LOG:?}"
command="${1:?missing command}"
shift
case "$command" in
  reattach)
    if [[ -n "${AMQ_WAKE_OWNER+x}" ]]; then
      printf 'reattach inherited caller AMQ_WAKE_OWNER\n' >&2
      exit 88
    fi
    if [[ "${AMQ_KEEPALIVE_BASELINE_EXISTING:-}" != "1" ]]; then
      printf 'reattach did not request startup backlog baselining\n' >&2
      exit 89
    fi
    agent=""
    target=""
    amq_path=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --me)
          agent="${2:?missing agent}"
          shift 2
          ;;
        --target)
          target="${2:?missing target}"
          shift 2
          ;;
        --amq)
          amq_path="${2:?missing AMQ path}"
          shift 2
          ;;
        --baseline-file)
          printf 'removed --baseline-file argument was used\n' >&2
          exit 65
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ "$amq_path" != /* || ! -x "$amq_path" ]]; then
      printf 'exec: "%s": executable file not found in $PATH\n' "${amq_path:-amq}" >&2
      exit 1
    fi
    printf 'reattach\t%s\t%s\t%s\t%s\n' \
      "$agent" "$target" "$amq_path" "$AMQ_KEEPALIVE_BASELINE_EXISTING" \
      >>"${CMUX_FAKE_EVENT_LOG:?}"
    case "${CMUX_FAKE_REATTACH_MODE:-success}" in
      success)
        ;;
      refuse)
        printf 'reattach refused\n' >&2
        exit 1
        ;;
      refuse-claude)
        if [[ "$agent" == "claude" ]]; then
          printf 'reattach refused for claude\n' >&2
          exit 1
        fi
        ;;
      refuse-codex)
        if [[ "$agent" == "codex" ]]; then
          printf 'reattach refused for codex\n' >&2
          exit 1
        fi
        ;;
      warn-reuse)
        printf 'warning: reusing existing amq wake; this launch did not re-baseline it\n' >&2
        ;;
      *)
        printf 'unknown fake reattach mode\n' >&2
        exit 64
        ;;
    esac
    printf '{"entry":{"agent":"%s","target":"%s","state":"active"}}\n' "$agent" "$target"
    ;;
  inject)
    adapter="${1:?missing adapter}"
    target="${2:?missing target}"
    payload="${3:?missing payload}"
    printf 'inject\t%s\t%s\t%s\n' "$adapter" "$target" "$payload" >>"${CMUX_FAKE_EVENT_LOG:?}"
    if [[ "${CMUX_FAKE_INJECT_MODE:-success}" != "success" ]]; then
      printf 'inject refused\n' >&2
      exit 1
    fi
    ;;
  retire-session)
    agents=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agents)
          agents="${2:?missing agents}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    printf 'retire\t%s\n' "$agents" >>"${CMUX_FAKE_EVENT_LOG:?}"
    if [[ "${CMUX_FAKE_KEEPALIVE_MODE:-refuse}" != "success" ]]; then
      printf 'target absence not proven\n' >&2
      exit 1
    fi
    printf '{"root":"%s","adapter":"cmux","entries":[]}\n' "${CMUX_PROJECT_LAUNCHER_AMQ_ROOT:?}"
    ;;
  *)
    printf 'unexpected keepalive command: %s\n' "$command" >&2
    exit 64
    ;;
esac
SH
chmod +x "$fake_keepalive"
export CMUX_PROJECT_LAUNCHER_KEEPALIVE="$fake_keepalive"
export CMUX_FAKE_KEEPALIVE_LOG="$keepalive_log"
export AMQ_WAKE_OWNER='launcher-caller-owner-must-not-cross-attach-boundary'
# Fail closed at fixture scope: even a test case that accidentally omits one
# inline override must never reach the production cmux, AMQ, or open binaries.
export CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux"
export CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq"
export CMUX_PROJECT_LAUNCHER_OPEN="$fake_open"
export CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root"

CMUX_FAKE_SEND_LOG="$send_log" \
CMUX_FAKE_KEY_LOG="$key_log" \
CMUX_FAKE_CREATE_LOG="$create_log" \
CMUX_FAKE_LAYOUT_LOG="$layout_log" \
CMUX_FAKE_SELECT_LOG="$select_log" \
CMUX_FAKE_OPEN_LOG="$open_log" \
CMUX_FAKE_CLOSE_LOG="$close_log" \
CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
CMUX_PROJECT_LAUNCHER_WORKSPACE_ROOT=/Users/example/git \
CMUX_PROJECT_LAUNCHER_POLL=1 \
CMUX_PROJECT_LAUNCHER_WAIT=0 \
  $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log"

# Golden capture: the default Codex + Claude launch must stay byte-identical while
# the launch pipeline is generalized from a fixed pair to a chosen set of agents.
# A diff here is a behaviour change, not a fixture to update.
expected_layout_log="$tmp_dir/expected-layout.log"
cat >"$expected_layout_log" <<'GOLDEN'
Project launcher: demo-project (AMQ session: demo-project)
{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"Codex","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_codex demo-project'","focus":true}]}},{"pane":{"surfaces":[{"type":"terminal","name":"Claude","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_claude demo-project -- --name claude-demo-project'"}]}}]}
GOLDEN
if ! cmp -s "$expected_layout_log" "$layout_log"; then
  printf 'default launch description/layout changed:\n' >&2
  diff "$expected_layout_log" "$layout_log" >&2 || true
  exit 1
fi

# Codex is renamed post-boot with the naming dialog's confirmation Enter before
# $start is sent.
grep -Fq $'surface:26\t/rename' "$send_log"
grep -Fq $'surface:26\tcodex-demo-project' "$send_log"
# Claude is named at boot via --name, so it must NOT get a post-boot /rename send.
if grep -Fq $'surface:27\t/rename' "$send_log"; then
  printf 'Claude should not receive a post-boot /rename send\n' >&2
  exit 1
fi
grep -Fq $'surface:26\t$start demo-project' "$send_log"
grep -Fq $'surface:27\t/start demo-project' "$send_log"
grep -Fq $'surface:26\tenter' "$key_log"
grep -Fq $'surface:27\tenter' "$key_log"
grep -Fq 'demo-project' "$create_log"
grep -Fq 'Launched demo-project in workspace:10' "$stdout_log"
[[ ! -s "$close_log" ]]
grep -Fxq $'init\t'"$fake_amq_root/demo-project"$'\tclaude,codex,user' "$event_log"
[[ "$(awk -F '\t' '$1 == "init" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]
[[ -f "$fake_amq_root/demo-project/meta/config.json" ]]
[[ -d "$fake_amq_root/demo-project/agents/user/inbox/new" ]]
init_line="$(awk -F '\t' '$1 == "init" { print NR; exit }' "$event_log")"
doctor_line="$(awk -F '\t' '$1 == "doctor" { print NR; exit }' "$event_log")"
workspace_create_line="$(awk -F '\t' '$1 == "workspace-create" { print NR; exit }' "$event_log")"
[[ "$init_line" -lt "$workspace_create_line" ]]
[[ "$init_line" -lt "$doctor_line" ]]
[[ "$doctor_line" -lt "$workspace_create_line" ]]
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
grep -Fq $'reattach\tcodex\tcmux:surface:11111111-1111-4111-8111-111111111111' "$event_log"
grep -Fq $'reattach\tclaude\tcmux:surface:22222222-2222-4222-8222-222222222222' "$event_log"

# Project launch is one serialized transaction. Without the project lock, the
# second invocation reaches AMQ init/workspace creation while the first is
# paused after the same empty-state observation.
concurrent_entered="$tmp_dir/concurrent-init-entered"
concurrent_release="$tmp_dir/concurrent-init-release"
concurrent_first_stdout="$tmp_dir/concurrent-first.stdout"
concurrent_first_stderr="$tmp_dir/concurrent-first.stderr"
concurrent_second_stdout="$tmp_dir/concurrent-second.stdout"
concurrent_second_stderr="$tmp_dir/concurrent-second.stderr"
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
CMUX_FAKE_AMQ_INIT_ENTERED="$concurrent_entered" \
CMUX_FAKE_AMQ_INIT_RELEASE="$concurrent_release" \
CMUX_FAKE_EXPECT_PROJECT=demo-project-concurrent \
CMUX_FAKE_EXPECT_SESSION=demo-project-concurrent \
CMUX_FAKE_SEND_LOG="$send_log" \
CMUX_FAKE_KEY_LOG="$key_log" \
CMUX_FAKE_CREATE_LOG="$create_log" \
CMUX_FAKE_SELECT_LOG="$select_log" \
CMUX_FAKE_OPEN_LOG="$open_log" \
CMUX_FAKE_CLOSE_LOG="$close_log" \
CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
CMUX_PROJECT_LAUNCHER_POLL=1 \
CMUX_PROJECT_LAUNCHER_WAIT=0 \
  $launch_bash "$repo_root/bin/cmux-project-launch" demo-project-concurrent \
    >"$concurrent_first_stdout" 2>"$concurrent_first_stderr" &
concurrent_pid=$!
background_pids+=("$concurrent_pid")
for _ in {1..200}; do
  [[ -f "$concurrent_entered" ]] && break
  sleep 0.01
done
if [[ ! -f "$concurrent_entered" ]]; then
  printf 'first concurrent launcher did not reach blocked init\n' >&2
  exit 1
fi
if CMUX_FAKE_EXPECT_PROJECT=demo-project-concurrent \
  CMUX_FAKE_EXPECT_SESSION=demo-project-concurrent \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project-concurrent \
      >"$concurrent_second_stdout" 2>"$concurrent_second_stderr"; then
  printf 'second concurrent launcher was not rejected\n' >&2
  exit 1
fi
grep -Fq 'A cmux project launch for demo-project-concurrent is already in progress; created nothing.' "$concurrent_second_stderr"
[[ ! -s "$create_log" ]]
: >"$concurrent_release"
if ! wait "$concurrent_pid"; then
  printf 'first concurrent launcher failed after release\n' >&2
  sed -n '1,240p' "$concurrent_first_stderr" >&2
  exit 1
fi
[[ "$(awk -F '\t' '$1 == "init" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]
[[ "$(awk -F '\t' '$1 == "workspace-create" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]

# Session initialization is a launch gate. A failed init must not create a
# workspace whose agents and wake registration would race an incomplete queue.
: >"$event_log"
: >"$create_log"
rm -rf "$fake_amq_root/demo-project-init-fail"
if CMUX_FAKE_AMQ_INIT_FAIL=1 \
  CMUX_FAKE_EXPECT_PROJECT=demo-project-init-fail \
  CMUX_FAKE_EXPECT_SESSION=demo-project-init-fail \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project-init-fail >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'failed AMQ init unexpectedly created a workspace\n' >&2
  exit 1
fi
grep -Fq 'Could not initialize AMQ session demo-project-init-fail' "$tmp_dir/stderr.log"
grep -Fq '(exit 71)' "$tmp_dir/stderr.log"
[[ ! -s "$create_log" ]]
if grep -Fq $'workspace-create\t' "$event_log"; then
  printf 'failed AMQ init reached cmux workspace creation\n' >&2
  exit 1
fi

# Preserve an AMQ doctor's exact exit status even when it emits no stderr.
doctor_fail_root="$fake_amq_root/demo-project-doctor-fail"
mkdir -p "$doctor_fail_root/meta"
printf '{"agents":["claude","codex","user"]}\n' >"$doctor_fail_root/meta/config.json"
: >"$event_log"
: >"$create_log"
if CMUX_FAKE_EXPECT_PROJECT=demo-project-doctor-fail \
  CMUX_FAKE_EXPECT_SESSION=demo-project-doctor-fail \
  CMUX_FAKE_AMQ_DOCTOR_EXIT=72 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project-doctor-fail \
      >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'failed AMQ doctor unexpectedly launched\n' >&2
  exit 1
fi
grep -Fq 'amq doctor command failed (exit 72)' "$tmp_dir/stderr.log"
[[ ! -s "$create_log" ]]

# A complete configured session is read-only input: launch without invoking
# init again. This pins the configured-session no-op half of the contract.
configured_root="$fake_amq_root/demo-project-configured"
rm -rf "$configured_root"
mkdir -p "$configured_root/meta"
for agent in claude codex user; do
  mkdir -p \
    "$configured_root/agents/$agent/inbox/tmp" \
    "$configured_root/agents/$agent/inbox/new" \
    "$configured_root/agents/$agent/inbox/cur" \
    "$configured_root/agents/$agent/outbox/sent" \
    "$configured_root/agents/$agent/dlq/tmp" \
    "$configured_root/agents/$agent/dlq/new" \
    "$configured_root/agents/$agent/dlq/cur" \
    "$configured_root/agents/$agent/receipts"
done
printf '{"agents":["claude","codex","user"]}\n' >"$configured_root/meta/config.json"
chmod -R 700 "$configured_root"
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
CMUX_FAKE_EXPECT_PROJECT=demo-project-configured \
CMUX_FAKE_EXPECT_SESSION=demo-project-configured \
CMUX_FAKE_SEND_LOG="$send_log" \
CMUX_FAKE_KEY_LOG="$key_log" \
CMUX_FAKE_CREATE_LOG="$create_log" \
CMUX_FAKE_SELECT_LOG="$select_log" \
CMUX_FAKE_OPEN_LOG="$open_log" \
CMUX_FAKE_CLOSE_LOG="$close_log" \
CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
CMUX_PROJECT_LAUNCHER_POLL=1 \
CMUX_PROJECT_LAUNCHER_WAIT=0 \
  $launch_bash "$repo_root/bin/cmux-project-launch" demo-project-configured >"$stdout_log"
[[ "$(awk -F '\t' '$1 == "init" { count++ } END { print count + 0 }' "$event_log")" -eq 0 ]]
grep -Fq $'workspace-create\tdemo-project-configured' "$event_log"
[[ "$(awk -F '\t' '$1 == "doctor" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]

# A configured but partial session must remain untouched and fail before cmux.
partial_root="$fake_amq_root/demo-project-partial"
rm -rf "$partial_root"
mkdir -p "$partial_root/meta" "$partial_root/agents/claude/inbox/new"
printf '{"agents":["claude","codex","user"]}\n' >"$partial_root/meta/config.json"
: >"$event_log"
: >"$create_log"
if CMUX_FAKE_EXPECT_PROJECT=demo-project-partial \
  CMUX_FAKE_EXPECT_SESSION=demo-project-partial \
  CMUX_FAKE_AMQ_DOCTOR_MODE=mailboxes-error \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project-partial >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'partial configured AMQ session unexpectedly launched\n' >&2
  exit 1
fi
grep -Fq 'failed read-only AMQ doctor validation' "$tmp_dir/stderr.log"
grep -Fq 'Mailboxes=error' "$tmp_dir/stderr.log"
[[ "$(awk -F '\t' '$1 == "init" { count++ } END { print count + 0 }' "$event_log")" -eq 0 ]]
[[ ! -s "$create_log" ]]
if grep -Fq $'workspace-create\t' "$event_log"; then
  printf 'partial configured AMQ session reached cmux workspace creation\n' >&2
  exit 1
fi

# A malformed config is present state, not a new room: doctor must reject it
# without init or cmux mutation.
malformed_root="$fake_amq_root/demo-project-malformed"
rm -rf "$malformed_root"
mkdir -p "$malformed_root/meta"
printf '{not-json\n' >"$malformed_root/meta/config.json"
: >"$event_log"
: >"$create_log"
if CMUX_FAKE_EXPECT_PROJECT=demo-project-malformed \
  CMUX_FAKE_EXPECT_SESSION=demo-project-malformed \
  CMUX_FAKE_AMQ_DOCTOR_MODE=config-error \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project-malformed >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'malformed configured AMQ session unexpectedly launched\n' >&2
  exit 1
fi
grep -Fq 'Config=error' "$tmp_dir/stderr.log"
[[ "$(awk -F '\t' '$1 == "init" { count++ } END { print count + 0 }' "$event_log")" -eq 0 ]]
[[ ! -s "$create_log" ]]

# A project without its own agent choice keeps its existing room's agents
# (Ohad, 2026-10-04). Before agent rosters this claude-only room was refused,
# because the launcher could only start the Codex + Claude pair; now it launches
# Claude alone. Doctor still has to confirm the room's own mailboxes.
wrong_agent_root="$fake_amq_root/demo-project-wrong-agent"
rm -rf "$wrong_agent_root"
mkdir -p "$wrong_agent_root/meta"
for agent in claude user; do
  mkdir -p \
    "$wrong_agent_root/agents/$agent/inbox/tmp" \
    "$wrong_agent_root/agents/$agent/inbox/new" \
    "$wrong_agent_root/agents/$agent/inbox/cur" \
    "$wrong_agent_root/agents/$agent/outbox/sent" \
    "$wrong_agent_root/agents/$agent/dlq/tmp" \
    "$wrong_agent_root/agents/$agent/dlq/new" \
    "$wrong_agent_root/agents/$agent/dlq/cur" \
    "$wrong_agent_root/agents/$agent/receipts"
done
printf '{"agents":["claude","user"]}\n' >"$wrong_agent_root/meta/config.json"
chmod -R 700 "$wrong_agent_root"
: >"$event_log"
: >"$create_log"
: >"$send_log"
: >"$key_log"
CMUX_FAKE_EXPECT_PROJECT=demo-project-wrong-agent \
  CMUX_FAKE_EXPECT_SESSION=demo-project-wrong-agent \
  CMUX_FAKE_AGENT_ROSTER=claude \
  CMUX_FAKE_AMQ_DOCTOR_MODE=wrong-agent \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project-wrong-agent >"$stdout_log"
grep -Fq 'Launched demo-project-wrong-agent in workspace:10' "$stdout_log"
[[ "$(awk -F '\t' '$1 == "init" { count++ } END { print count + 0 }' "$event_log")" -eq 0 ]]
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]
grep -Fq $'surface:27\t/start demo-project-wrong-agent' "$send_log"
if grep -Fq 'surface:26' "$send_log"; then
  printf 'claude-only room launch touched a Codex surface\n' >&2
  exit 1
fi

# --no-start (ad-hoc) mode: workspace + rename, but NO $start//start sends.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" --no-start demo-project >"$stdout_log"

grep -Fq $'surface:26\t/rename' "$send_log"
grep -Fq $'surface:26\tcodex-demo-project' "$send_log"
if grep -Fq 'start demo-project' "$send_log"; then
  # shellcheck disable=SC2016
  printf 'no-start mode must not send $start//start\n' >&2
  exit 1
fi
grep -Fq 'Launched ad-hoc workspace demo-project in workspace:10' "$stdout_log"
grep -Fq 'no /start sent' "$stdout_log"
[[ ! -s "$close_log" ]]
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]

# 2026-09-23 Gate 4: cmux never reported a tty for the Codex surface while the
# Claude surface was ready. --no-start skipped BOTH exact wake attaches and still
# exited 0, so the room looked launched with zero wakes. Each ready agent must
# attach on its own, and a missing wake must fail the launch while the ad-hoc
# workspace is preserved.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
codex_no_tty_status=0
CMUX_FAKE_MODE=codex-no-tty \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
  CMUX_PROJECT_LAUNCHER_PROMOTE_WAIT=1 \
    $launch_bash "$repo_root/bin/cmux-project-launch" --no-start demo-project \
    >"$stdout_log" 2>"$tmp_dir/stderr.log" || codex_no_tty_status=$?
if [[ "$codex_no_tty_status" -eq 0 ]]; then
  printf 'codex-no-tty --no-start exited 0 without a Codex AMQ wake\n' >&2
  exit 1
fi
if [[ "$(awk -F '\t' '$1 == "reattach" && $2 == "claude" { count++ } END { print count + 0 }' "$event_log")" -ne 1 ]]; then
  printf 'codex-no-tty --no-start did not attach the ready Claude wake exactly once\n' >&2
  exit 1
fi
if [[ "$(awk -F '\t' '$1 == "reattach" && $2 == "codex" { count++ } END { print count + 0 }' "$event_log")" -ne 0 ]]; then
  printf 'codex-no-tty --no-start attached a Codex wake without a live Codex tty\n' >&2
  exit 1
fi
grep -Fq 'Codex AMQ wake was not attached' "$tmp_dir/stderr.log"
grep -Fq 'no live terminal tty' "$tmp_dir/stderr.log"
[[ ! -s "$close_log" ]]
if grep -Fq 'start demo-project' "$send_log"; then
  printf 'codex-no-tty --no-start unexpectedly sent a start prompt\n' >&2
  exit 1
fi

# The second 2026-09-23 Gate 4 run: neither surface ever reported a tty. A
# --no-start room with zero AMQ wakes must not exit 0.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
zero_wake_status=0
CMUX_FAKE_MODE=ghostty-no-tty \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
  CMUX_PROJECT_LAUNCHER_PROMOTE_WAIT=1 \
    $launch_bash "$repo_root/bin/cmux-project-launch" --no-start demo-project \
    >"$stdout_log" 2>"$tmp_dir/stderr.log" || zero_wake_status=$?
if [[ "$zero_wake_status" -eq 0 ]]; then
  printf 'zero-wake --no-start exited 0\n' >&2
  exit 1
fi
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 0 ]]
grep -Fq 'Codex AMQ wake was not attached' "$tmp_dir/stderr.log"
grep -Fq 'Claude AMQ wake was not attached' "$tmp_dir/stderr.log"
[[ ! -s "$close_log" ]]

# A GUI-launched app has no Homebrew directory on PATH. The launcher must resolve
# AMQ from a relative path hint before the base-root command substitution,
# normalize it, and pass the absolute executable to amq-keepalive.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
resolved_fake_amq="$(cd "$tmp_dir" && /bin/pwd -P)/amq"
if ! (
  cd "$tmp_dir" || exit 1
  # Empty means honor the script shebang.
  # shellcheck disable=SC2086
  /usr/bin/env -u CMUX_PROJECT_LAUNCHER_AMQ -u CMUX_PROJECT_LAUNCHER_AMQ_ROOT \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    CMUX_PROJECT_LAUNCHER_AMQ_PATH_HINTS=. \
    CMUX_FAKE_SEND_LOG="$send_log" \
    CMUX_FAKE_KEY_LOG="$key_log" \
    CMUX_FAKE_CREATE_LOG="$create_log" \
    CMUX_FAKE_SELECT_LOG="$select_log" \
    CMUX_FAKE_OPEN_LOG="$open_log" \
    CMUX_FAKE_CLOSE_LOG="$close_log" \
    CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
    CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
    CMUX_PROJECT_LAUNCHER_KEEPALIVE="$fake_keepalive" \
    CMUX_PROJECT_LAUNCHER_PS="$fake_ps" \
    CMUX_PROJECT_LAUNCHER_POLL=1 \
    CMUX_PROJECT_LAUNCHER_WAIT=0 \
      $launch_bash "$repo_root/bin/cmux-project-launch" --no-start demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"
); then
  printf 'GUI-PATH launch failed to resolve the hinted AMQ executable\n' >&2
  exit 1
fi
grep -Fq $'reattach\tcodex\tcmux:surface:11111111-1111-4111-8111-111111111111\t'"$resolved_fake_amq" "$event_log"
grep -Fq $'reattach\tclaude\tcmux:surface:22222222-2222-4222-8222-222222222222\t'"$resolved_fake_amq" "$event_log"
grep -Fq 'Launched ad-hoc workspace demo-project in workspace:10' "$stdout_log"
[[ ! -s "$close_log" ]]

# The explicit-path branch expands `~` before checking executability and keeps
# the same absolute-path postcondition as hinted discovery.
(
  HOME="$tmp_dir"
  # Intentional literal verifies expand_path handles a config value containing `~`.
  # shellcheck disable=SC2088
  amq_bin='~/amq'
  # shellcheck source=bin/lib/cmux-project-common.sh
  source "$repo_root/bin/lib/cmux-project-common.sh"
  resolve_amq_bin
  [[ "$amq_bin" == "$fake_amq" ]]
)

# A bad explicit path must fail before cmux creates a workspace, and the error
# must preserve the requested value plus the configured search context.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
missing_amq="$tmp_dir/missing-amq"
if /usr/bin/env \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  CMUX_PROJECT_LAUNCHER_AMQ="$missing_amq" \
  CMUX_PROJECT_LAUNCHER_AMQ_PATH_HINTS="$tmp_dir/missing-hint" \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_KEEPALIVE="$fake_keepalive" \
  CMUX_PROJECT_LAUNCHER_PS="$fake_ps" \
    "$repo_root/bin/cmux-project-launch" --no-start demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'missing AMQ unexpectedly reached the launch path\n' >&2
  exit 1
fi
grep -Fq "Requested: $missing_amq" "$tmp_dir/stderr.log"
grep -Fq "hints: $tmp_dir/missing-hint" "$tmp_dir/stderr.log"
grep -Fq 'PATH: /usr/bin:/bin:/usr/sbin:/sbin' "$tmp_dir/stderr.log"
[[ ! -s "$create_log" ]]
[[ ! -s "$event_log" ]]
[[ ! -s "$close_log" ]]

# A long Codex name can soft-wrap inside cmux's read-screen output. The exact
# success marker must still confirm the rename and allow the normal launch.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
CMUX_FAKE_RENAME_MODE=wrapped-success \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log"

grep -Fq $'surface:26\tcodex-demo-project' "$send_log"
grep -Fq $'surface:26\t$start demo-project' "$send_log"
grep -Fq $'surface:27\t/start demo-project' "$send_log"
grep -Fq 'Launched demo-project in workspace:10' "$stdout_log"
[[ ! -s "$close_log" ]]

# Codex 0.155.1 prints no success line: the dialog closes and the new name is
# written to $CODEX_HOME/session_index.jsonl. A new index row for the exact name
# confirms the rename and allows the normal launch.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
: >"$CODEX_HOME/session_index.jsonl"
CMUX_FAKE_RENAME_MODE=index-success \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_SUBMIT_CONFIRM_WAIT=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log"

grep -Fq $'surface:26\tcodex-demo-project' "$send_log"
grep -Fq $'surface:26\t$start demo-project' "$send_log"
grep -Fq $'surface:27\t/start demo-project' "$send_log"
grep -Fq 'Launched demo-project in workspace:10' "$stdout_log"
[[ ! -s "$close_log" ]]

# An index row that already existed before the confirming Enter is stale and
# must not prove this rename (the vanished dialog alone stays unconfirmed).
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
printf '{"id":"old-thread","thread_name":"codex-demo-project","updated_at":"2026-09-01T00:00:00Z"}\n' \
  >"$CODEX_HOME/session_index.jsonl"
if CMUX_FAKE_RENAME_MODE=vanished \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_SUBMIT_CONFIRM_WAIT=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'a stale session_index row unexpectedly confirmed the Codex rename\n' >&2
  exit 1
fi
grep -Fq 'did not confirm the session name' "$tmp_dir/stderr.log"
: >"$CODEX_HOME/session_index.jsonl"

# Exact wake attachment is a launch gate: preserve the live workspace, expose
# queued-message safety, and send neither rename nor start prompts on failure.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_REATTACH_MODE=refuse \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'failed exact wake attachment unexpectedly launched\n' >&2
  exit 1
fi
grep -Fq 'Messages remain queued; no start prompts were sent' "$tmp_dir/stderr.log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$close_log" ]]
# Each ready agent is attached on its own (requirement 7): a refused Codex
# attach must not skip the Claude attempt.
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]

# If only the Codex attachment fails, the ready Claude still gets its exact wake
# and its existing backlog is surfaced; the launch exits non-zero naming Codex.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_REATTACH_MODE=refuse-codex \
  CMUX_FAKE_UNREAD_CLAUDE=1 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'failed Codex wake attachment unexpectedly launched\n' >&2
  exit 1
fi
[[ "$(awk -F '\t' '$1 == "reattach" && $2 == "claude" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]
grep -Fxq $'inject\tcmux\tcmux:surface:22222222-2222-4222-8222-222222222222\t[AMQ] Unread messages are queued. Run: amq drain --include-body' "$event_log"
[[ "$(awk -F '\t' '$1 == "inject" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]
grep -Fq 'exact AMQ wake attachment failed for codex.' "$tmp_dir/stderr.log"
if grep -Fq 'exact AMQ wake attachment failed for claude' "$tmp_dir/stderr.log"; then
  printf 'a successful Claude attach was reported as failed\n' >&2
  exit 1
fi
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$close_log" ]]

# If the second attachment fails, the first wake has already baselined its
# queue. Surface that agent's existing backlog before exiting, without sending
# a rename or start prompt.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_REATTACH_MODE=refuse-claude \
  CMUX_FAKE_UNREAD_CODEX=1 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'partial exact wake attachment unexpectedly launched\n' >&2
  exit 1
fi
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
grep -Fxq $'inject\tcmux\tcmux:surface:11111111-1111-4111-8111-111111111111\t[AMQ] Unread messages are queued. Run: amq drain --include-body' "$event_log"
[[ "$(awk -F '\t' '$1 == "inject" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$close_log" ]]

# If Codex leaves the confirmation footer active after the first name Enter,
# send exactly one additional Enter, observe the success marker, and continue.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
CMUX_FAKE_RENAME_MODE=missed-enter \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_SUBMIT_CONFIRM_WAIT=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" --no-start demo-project >"$stdout_log"

[[ "$(awk -F '\t' '$1 == "surface:26" { count++ } END { print count + 0 }' "$key_log")" -eq 3 ]]
grep -Fq 'Launched ad-hoc workspace demo-project in workspace:10' "$stdout_log"
if grep -Fq 'start demo-project' "$send_log"; then
  printf 'missed-enter rename test unexpectedly sent a start prompt\n' >&2
  exit 1
fi
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
[[ ! -s "$close_log" ]]

# An existing mailbox is reused. After both exact-surface wakes are attached,
# the launcher checks each unread queue without reading message bodies.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$close_log"
: >"$keepalive_log"
mkdir -p "$fake_amq_root/demo-project"
CMUX_FAKE_REATTACH_MODE=warn-reuse \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"

grep -Fxq 'demo-project' "$create_log"
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
[[ "$(awk -F '\t' '$1 == "reattach" && $5 == "1" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
if grep -Fxq -- '--baseline-existing' "$keepalive_log"; then
  printf 'launcher passed unsupported keepalive reattach flag --baseline-existing\n' >&2
  exit 1
fi
[[ "$(awk -F '\t' '$1 == "list" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
[[ "$(awk -F '\t' '$1 == "inject" { count++ } END { print count + 0 }' "$event_log")" -eq 0 ]]
grep -Fq 'AMQ wake attachment warning for codex' "$tmp_dir/stderr.log"
grep -Fq 'this launch did not re-baseline it' "$tmp_dir/stderr.log"
rm -rf "$fake_amq_root/demo-project"

# Existing unread messages produce one fixed, message-independent doorbell per
# agent after both exact wakes attach and the Codex rename handshake, but before
# any start input.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$close_log"
CMUX_FAKE_UNREAD_CODEX=1 \
  CMUX_FAKE_UNREAD_CLAUDE=1 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"

[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
[[ "$(awk -F '\t' '$1 == "list" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
[[ "$(awk -F '\t' '$1 == "inject" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
grep -Fxq $'inject\tcmux\tcmux:surface:11111111-1111-4111-8111-111111111111\t[AMQ] Unread messages are queued. Run: amq drain --include-body' "$event_log"
grep -Fxq $'inject\tcmux\tcmux:surface:22222222-2222-4222-8222-222222222222\t[AMQ] Unread messages are queued. Run: amq drain --include-body' "$event_log"
last_reattach_line="$(awk -F '\t' '$1 == "reattach" { line=NR } END { print line + 0 }' "$event_log")"
first_inject_line="$(awk -F '\t' '$1 == "inject" { print NR; exit }' "$event_log")"
first_send_line="$(awk -F '\t' '$1 == "send" { print NR; exit }' "$event_log")"
first_start_line="$(awk -F '\t' '$1 == "send" && ($3 == "$start demo-project" || $3 == "/start demo-project") { print NR; exit }' "$event_log")"
[[ "$last_reattach_line" -lt "$first_send_line" ]]
[[ "$first_send_line" -lt "$first_inject_line" ]]
[[ "$first_inject_line" -lt "$first_start_line" ]]
rm -rf "$fake_amq_root/demo-project"

# If unread inspection fails, preserve the live workspace for inspection but
# fail after naming and before any start input can hide the queued-work
# uncertainty.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$close_log"
if CMUX_FAKE_AMQ_LIST_MODE=error \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'backlog inspection failure unexpectedly launched successfully\n' >&2
  exit 1
fi
grep -Fq 'AMQ backlog inspection failed for codex after exact wake attachment' "$tmp_dir/stderr.log"
grep -Fq 'queued AMQ messages could not be surfaced. No start prompts were sent.' "$tmp_dir/stderr.log"
grep -Fq $'surface:26\t/rename' "$send_log"
grep -Fq $'surface:26\tcodex-demo-project' "$send_log"
if grep -Fq 'start demo-project' "$send_log"; then
  printf 'backlog inspection failure unexpectedly sent a start prompt\n' >&2
  exit 1
fi
[[ ! -s "$close_log" ]]
rm -rf "$fake_amq_root/demo-project"

# A failed exact-surface backlog injection is equally fail-visible and stops
# after naming and before start.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$close_log"
if CMUX_FAKE_UNREAD_CODEX=1 \
  CMUX_FAKE_INJECT_MODE=refuse \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'backlog injection failure unexpectedly launched successfully\n' >&2
  exit 1
fi
grep -Fq 'AMQ backlog doorbell failed for codex' "$tmp_dir/stderr.log"
grep -Fq $'surface:26\t/rename' "$send_log"
grep -Fq $'surface:26\tcodex-demo-project' "$send_log"
if grep -Fq 'start demo-project' "$send_log"; then
  printf 'backlog injection failure unexpectedly sent a start prompt\n' >&2
  exit 1
fi
[[ ! -s "$close_log" ]]
rm -rf "$fake_amq_root/demo-project"

# If the naming dialog vanishes without a success marker, stop before either
# start prompt and do not send a blind retry Enter. Preserve the workspace.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_RENAME_MODE=vanished \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_SUBMIT_CONFIRM_WAIT=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'unconfirmed Codex rename unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'did not confirm the session name' "$tmp_dir/stderr.log"
[[ "$(awk -F '\t' '$1 == "surface:26" { count++ } END { print count + 0 }' "$key_log")" -eq 2 ]]
if grep -Fq 'start demo-project' "$send_log"; then
  printf 'start prompt was sent without a Codex rename success marker\n' >&2
  exit 1
fi
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
[[ ! -s "$close_log" ]]

# A stale modal transcript must not trigger a blind retry if the active footer
# has already returned to an ordinary prompt.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_RENAME_MODE=stale-modal \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_SUBMIT_CONFIRM_WAIT=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'stale rename modal unexpectedly triggered a successful retry\n' >&2
  exit 1
fi

grep -Fq 'did not confirm the name codex-demo-project' "$tmp_dir/stderr.log"
[[ "$(awk -F '\t' '$1 == "surface:26" { count++ } END { print count + 0 }' "$key_log")" -eq 2 ]]
if grep -Fq 'start demo-project' "$send_log"; then
  printf 'start prompt was sent after a stale rename modal\n' >&2
  exit 1
fi
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
[[ ! -s "$close_log" ]]

# A missing Codex rename-success marker after the confirmation Enter must also
# stop before either start prompt and preserve the live workspace for inspection.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_RENAME_MODE=no-success \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_SUBMIT_CONFIRM_WAIT=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'unconfirmed Codex rename unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'did not confirm the name codex-demo-project' "$tmp_dir/stderr.log"
if grep -Fq 'start demo-project' "$send_log"; then
  printf 'start prompt was sent after an unconfirmed Codex rename\n' >&2
  exit 1
fi
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
[[ ! -s "$close_log" ]]

# /rename that leaves the slash in the composer after the modal opens must
# still name the thread. submit_prompt would keep pressing Enter here.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
CMUX_FAKE_RENAME_MODE=slash-still-visible \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log"

grep -Fq $'surface:26\t/rename' "$send_log"
grep -Fq $'surface:26\tcodex-demo-project' "$send_log"
grep -Fq $'surface:26\t$start demo-project' "$send_log"
grep -Fq 'Launched demo-project in workspace:10' "$stdout_log"
if grep -Fq $'surface:26\tescape' "$key_log"; then
  printf 'successful slash-still-visible rename unexpectedly sent escape\n' >&2
  exit 1
fi
[[ ! -s "$close_log" ]]

# A confirmed-Enter miss that leaves the modal open must Escape out so the
# Codex pane is not stuck on Type a name. --no-start still preserves the
# workspace (exit 0) after the dismiss.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
CMUX_FAKE_RENAME_MODE=no-success \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_SUBMIT_CONFIRM_WAIT=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" --no-start demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"

grep -Fq 'did not confirm the session name' "$tmp_dir/stderr.log"
grep -Fq 'Dismissed the codex rename dialog after a failed rename.' "$tmp_dir/stderr.log"
grep -Fq $'surface:26\tescape' "$key_log"
grep -Fq 'Launched ad-hoc workspace demo-project in workspace:10' "$stdout_log"
if grep -Fq 'start demo-project' "$send_log"; then
  printf 'no-success no-start unexpectedly sent a start prompt\n' >&2
  exit 1
fi
[[ ! -s "$close_log" ]]

# A modal that renders AFTER open_rename_dialog gives up must still be escaped,
# and must not be reported as a clean launch. Observed live 2026-09-08 as Gate 4
# run C: dismiss_rename_dialog read a modal-free screen, returned 0 without
# sending Escape, and the Codex pane was left stuck on "Type a name and press
# Enter" while the launcher printed a naming warning and exited 0. A blocked pane
# cannot receive an AMQ doorbell, so exit 0 there is a silent success that is not one.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
rm -f "$send_log.late-modal-reads"
late_modal_status=0
CMUX_FAKE_RENAME_MODE=late-modal \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_SUBMIT_CONFIRM_WAIT=3 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" --no-start demo-project \
      >"$stdout_log" 2>"$tmp_dir/stderr.log" || late_modal_status=$?

# The pane must be escaped even though the modal was absent on the first look.
if ! grep -Fq $'surface:26\tescape' "$key_log"; then
  printf 'late-modal rename left the Codex pane without an Escape\n' >&2
  exit 1
fi
# The operator must be told the pane was blocked, not just that naming failed.
if ! grep -Fq 'rename dialog' "$tmp_dir/stderr.log"; then
  printf 'late-modal rename did not report the rename dialog state\n' >&2
  exit 1
fi
# Exiting 0 is only acceptable if the pane was provably recovered. Silence plus
# exit 0 is the failure mode this case exists to catch.
if [[ "$late_modal_status" -eq 0 ]] &&
   ! grep -Fq 'Dismissed the codex rename dialog after a failed rename.' "$tmp_dir/stderr.log"; then
  printf 'late-modal rename exited 0 without proving the Codex pane was recovered\n' >&2
  exit 1
fi
[[ ! -s "$close_log" ]]

# Confirm footer still present, but a warning line under it, must still Escape.
# last_nonblank is no longer the footer; that used to skip dismiss entirely.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
CMUX_FAKE_RENAME_MODE=footer-displaced \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_SUBMIT_CONFIRM_WAIT=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" --no-start demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"

grep -Fq 'did not confirm the session name' "$tmp_dir/stderr.log"
grep -Fq 'Dismissed the codex rename dialog after a failed rename.' "$tmp_dir/stderr.log"
grep -Fq $'surface:26\tescape' "$key_log"
grep -Fq 'Launched ad-hoc workspace demo-project in workspace:10' "$stdout_log"
if grep -Fq 'start demo-project' "$send_log"; then
  printf 'footer-displaced no-start unexpectedly sent a start prompt\n' >&2
  exit 1
fi
[[ ! -s "$close_log" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_MODE=shell \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'shell-mode launch unexpectedly succeeded\n' >&2
  exit 1
fi

[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
grep -Fq 'demo-project' "$create_log"
grep -Fq 'workspace:10' "$close_log"
grep -Fq 'Refusing to send' "$tmp_dir/stderr.log"
grep -Fq -- '--no-wake boot command' "$tmp_dir/stderr.log"
grep -Fq 'Refusing to send' "$diagnostics_log"
grep -Fq -- '--no-wake boot command' "$diagnostics_log"
[[ "$(stat -f '%Lp' "$diagnostics_log")" == "600" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_MODE=commandline \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'commandline-mode launch unexpectedly succeeded\n' >&2
  exit 1
fi

[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
grep -Fq 'demo-project' "$create_log"
grep -Fq 'workspace:10' "$close_log"
grep -Fq 'Refusing to send' "$tmp_dir/stderr.log"

# A pane-surface query that emits a partial row and then fails must not be
# mistaken for a successful enumeration.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_SURFACE_LIST_MODE=partial-error \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'partial surface enumeration unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'cmux list-pane-surfaces failed for workspace:10/pane:11' "$tmp_dir/stderr.log"
grep -Fxq 'workspace:10' "$close_log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
grep -Fxq $'retire\tcodex,claude' "$event_log"
if grep -Fq $'reattach\t' "$event_log"; then
  printf 'surface-enumeration failure performed an obsolete manual wake reattach\n' >&2
  exit 1
fi

# Existing-workspace reuse is proven cumulatively: exact wake ownership plus
# live Codex/Claude processes on each surface TTY.
setup_fake_wakes demo-project

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
CMUX_FAKE_WORKSPACE_LIST_MODE=demo-project \
CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7 \
CMUX_FAKE_SEND_LOG="$send_log" \
CMUX_FAKE_KEY_LOG="$key_log" \
CMUX_FAKE_CREATE_LOG="$create_log" \
CMUX_FAKE_SELECT_LOG="$select_log" \
CMUX_FAKE_OPEN_LOG="$open_log" \
CMUX_FAKE_CLOSE_LOG="$close_log" \
CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
CMUX_PROJECT_LAUNCHER_POLL=1 \
CMUX_PROJECT_LAUNCHER_WAIT=0 \
  $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log"

grep -Fq 'workspace:7' "$select_log"
grep -Fq 'Reattached demo-project in workspace:7 using AMQ session demo-project' "$stdout_log"
grep -Fq -- '-b com.cmuxterm.app' "$open_log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
[[ ! -s "$close_log" ]]

# A sibling AMQ root is not equivalent even when it shares the expected prefix.
# Focus the degraded workspace, but never report it as reattached.
: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_WORKSPACE_LIST_MODE=demo-project \
  CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7 \
  CMUX_FAKE_WAKE_COMMAND_ROOT="$fake_amq_root/demo-project-2" \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'wrong-root wake unexpectedly passed existing-workspace checks\n' >&2
  exit 1
fi

grep -Fq 'Codex AMQ wake is not bound to the exact Codex surface' "$tmp_dir/stderr.log"
grep -Fxq 'workspace:7' "$select_log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
[[ ! -s "$close_log" ]]

# An exact title without launcher metadata is only a collision. Open it for
# inspection, create nothing, and never bind it to the project's AMQ room.
: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_WORKSPACE_LIST_MODE=title-collision \
  CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'title-only collision unexpectedly reattached\n' >&2
  exit 1
fi

grep -Fq 'has no matching launcher metadata' "$tmp_dir/stderr.log"
grep -Fq 'created nothing' "$tmp_dir/stderr.log"
grep -Fxq 'workspace:7' "$select_log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
[[ ! -s "$close_log" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
CMUX_FAKE_WORKSPACE_LIST_MODE=multi \
CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7 \
CMUX_FAKE_SEND_LOG="$send_log" \
CMUX_FAKE_KEY_LOG="$key_log" \
CMUX_FAKE_CREATE_LOG="$create_log" \
CMUX_FAKE_SELECT_LOG="$select_log" \
CMUX_FAKE_OPEN_LOG="$open_log" \
CMUX_FAKE_CLOSE_LOG="$close_log" \
CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
CMUX_PROJECT_LAUNCHER_POLL=1 \
CMUX_PROJECT_LAUNCHER_WAIT=0 \
  $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log"

grep -Fxq 'workspace:7' "$select_log"
grep -Fq 'Reattached demo-project in workspace:7 using AMQ session demo-project' "$stdout_log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
[[ ! -s "$close_log" ]]

# A launcher workspace whose internal AMQ room is suffixed is still the same
# project. Resolve it from the structured description and never create another.
setup_fake_wakes demo-project-2
: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_WORKSPACE_LIST_MODE=suffixed-project \
  CMUX_FAKE_RUNTIME_WORKSPACE=workspace:8 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log"

grep -Fxq 'workspace:8' "$select_log"
grep -Fq 'Reattached demo-project in workspace:8 using AMQ session demo-project-2' "$stdout_log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
[[ ! -s "$close_log" ]]

# Existing duplicates are never deleted implicitly. If the newest candidate is
# stale, keep evaluating same-session siblings and open the healthy one.
: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_WORKSPACE_LIST_MODE=suffixed-duplicates \
  CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"

grep -Fxq 'workspace:7' "$select_log"
grep -Fq 'Found 2 launcher matches or title collisions for project demo-project (workspace:8, workspace:7)' "$tmp_dir/stderr.log"
grep -Fq 'Reattached demo-project in workspace:7 using AMQ session demo-project-2' "$stdout_log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
[[ ! -s "$close_log" ]]

# A restored workspace with terminal runtimes but plain shells is degraded, not
# successfully reattached. The launcher focuses it for inspection and fails closed.
setup_fake_wakes demo-project
: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_WORKSPACE_LIST_MODE=multi \
  CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7 \
  CMUX_FAKE_AGENT_PROCESS_MODE=shell \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'plain-shell reattach unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'has no live Codex process' "$tmp_dir/stderr.log"
grep -Fxq 'workspace:7' "$select_log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
[[ ! -s "$close_log" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_WORKSPACE_LIST_MODE=demo-project \
  CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7 \
  CMUX_FAKE_SELECT_FAIL=1 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'select-failure reattach unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'Could not select existing cmux workspace workspace:7' "$tmp_dir/stderr.log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
[[ ! -s "$select_log" ]]
[[ ! -s "$open_log" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_WORKSPACE_LIST_MODE=error \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'workspace-query failure unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'Could not query cmux workspaces' "$tmp_dir/stderr.log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
[[ ! -s "$select_log" ]]
[[ ! -s "$open_log" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_WORKSPACE_LIST_MODE=demo-project \
  CMUX_FAKE_DEBUG_MODE=error \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'runtime-query failure unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'terminal runtime could not be inspected' "$tmp_dir/stderr.log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
grep -Fxq 'workspace:7' "$select_log"
grep -Fq -- '-b com.cmuxterm.app' "$open_log"

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_WORKSPACE_LIST_MODE=demo-project \
  CMUX_FAKE_MODE=dead \
  CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'active-amq-dead-workspace launch unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'no live terminal runtime' "$tmp_dir/stderr.log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
grep -Fxq 'workspace:7' "$select_log"
grep -Fq -- '-b com.cmuxterm.app' "$open_log"

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_WORKSPACE_LIST_MODE=demo-project \
  CMUX_FAKE_MODE=ghostty-no-tty \
  CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'active-amq-ghostty-without-tty launch unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'no live terminal runtime' "$tmp_dir/stderr.log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
grep -Fxq 'workspace:7' "$select_log"
grep -Fq -- '-b com.cmuxterm.app' "$open_log"

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_WORKSPACE_LIST_MODE=demo-project \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'stale-workspace launch unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'workspace:7' "$select_log"
grep -Fq -- '-b com.cmuxterm.app' "$open_log"
grep -Fq 'not active' "$tmp_dir/stderr.log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
[[ ! -s "$close_log" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
: >"$keepalive_log"
CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_KEEPALIVE_MODE=success \
  CMUX_FAKE_EXPECT_SESSION=demo-project \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"

grep -Fq 'Retired its detached wakes and will reuse the original mailbox' "$tmp_dir/stderr.log"
grep -Fxq 'retire-session' "$keepalive_log"
grep -Fq "$fake_amq_root/demo-project" "$keepalive_log"
grep -Fq 'codex,claude' "$keepalive_log"
grep -Fq "$fake_amq" "$keepalive_log"
grep -Fq 'demo-project' "$create_log"
grep -Fq 'Launched demo-project in workspace:10 using AMQ session demo-project' "$stdout_log"
grep -Fq $'surface:26\t$start demo-project' "$send_log"
grep -Fq $'surface:27\t/start demo-project' "$send_log"
[[ ! -s "$select_log" ]]
[[ ! -s "$open_log" ]]
[[ ! -s "$close_log" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
: >"$keepalive_log"
CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
  CMUX_FAKE_EXPECT_SESSION=demo-project-3 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"

grep -Fq 'Allocating a separate AMQ session instead' "$tmp_dir/stderr.log"
grep -Fq 'Safe AMQ retirement refused' "$tmp_dir/stderr.log"
grep -Fxq 'retire-session' "$keepalive_log"
grep -Fq $'surface:26\t$start demo-project' "$send_log"
grep -Fq $'surface:27\t/start demo-project' "$send_log"
grep -Fq $'surface:26\tenter' "$key_log"
grep -Fq $'surface:27\tenter' "$key_log"
grep -Fq 'demo-project-3' "$create_log"
grep -Fq 'Launched demo-project in workspace:10 using AMQ session demo-project-3' "$stdout_log"
[[ ! -s "$select_log" ]]
[[ ! -s "$open_log" ]]
[[ ! -s "$close_log" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
rm -rf "$fake_amq_root/demo-project" "$fake_amq_root/demo-project-2"
mkdir -p "$fake_amq_root/demo-project/agents/codex"
mkdir -p "$fake_amq_root/demo-project-2/agents/claude"
"$fake_amq" wake --root "$fake_amq_root/demo-project" &
wake_pid_codex=$!
background_pids+=("$wake_pid_codex")
printf '{"pid":%s}\n' "$wake_pid_codex" >"$fake_amq_root/demo-project/agents/codex/.wake.lock"
"$fake_amq" wake --root "$fake_amq_root/demo-project-2" &
wake_pid_claude=$!
background_pids+=("$wake_pid_claude")
printf '{"pid":%s}\n' "$wake_pid_claude" >"$fake_amq_root/demo-project-2/agents/claude/.wake.lock"
CMUX_FAKE_EXPECT_SESSION=demo-project-3 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"

grep -Fq 'Allocating a separate AMQ session instead' "$tmp_dir/stderr.log"
grep -Fq $'surface:26\t$start demo-project' "$send_log"
grep -Fq $'surface:27\t/start demo-project' "$send_log"
grep -Fq $'surface:26\tenter' "$key_log"
grep -Fq $'surface:27\tenter' "$key_log"
grep -Fq 'demo-project-3' "$create_log"
grep -Fq 'Launched demo-project in workspace:10 using AMQ session demo-project-3' "$stdout_log"
[[ ! -s "$select_log" ]]
[[ ! -s "$open_log" ]]
[[ ! -s "$close_log" ]]
rm -rf "$fake_amq_root/demo-project" "$fake_amq_root/demo-project-2"

# Failed-workspace cleanup remains conservative and retires both identities
# without guessing whether any partial attachment occurred.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
: >"$keepalive_log"
if CMUX_FAKE_KEEPALIVE_MODE=success \
  CMUX_FAKE_MODE=shell \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'shell-mode cleanup unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fxq 'workspace:10' "$close_log"
grep -Fxq $'retire\tcodex,claude' "$event_log"
if grep -Fq $'reattach\t' "$event_log"; then
  printf 'launcher performed an obsolete manual wake reattach\n' >&2
  exit 1
fi

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_MODE=ghostty-only \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
  CMUX_PROJECT_LAUNCHER_PROMOTE_WAIT=1 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'ghostty-only launch unexpectedly succeeded\n' >&2
  exit 1
fi

[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$open_log" ]]
grep -Fq 'demo-project' "$create_log"
grep -Fq 'workspace:10' "$close_log"
grep -Fq 'ghostty=0x2' "$tmp_dir/stderr.log"

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$select_log"
: >"$open_log"
: >"$close_log"
if CMUX_FAKE_MODE=dead \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_OPEN="$fake_open" \
  CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
  CMUX_PROJECT_LAUNCHER_PROMOTE_WAIT=1 \
    $launch_bash "$repo_root/bin/cmux-project-launch" demo-project >"$stdout_log" 2>"$tmp_dir/stderr.log"; then
  printf 'dead-runtime launch unexpectedly succeeded\n' >&2
  exit 1
fi

[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$open_log" ]]
grep -Fq 'demo-project' "$create_log"
grep -Fq 'workspace:10' "$close_log"
grep -Fq 'runtime=0' "$tmp_dir/stderr.log"

# Agent roster: CMUX_PROJECT_LAUNCHER_AGENTS picks which agents a project launches
# with. Unset means the Codex + Claude pair pinned by the golden capture above.

# An unusable roster stops before any AMQ or cmux mutation.
for bad_roster in 'claude,nosuchagent' 'claude,claude' ''; do
  : >"$send_log"
  : >"$key_log"
  : >"$event_log"
  : >"$create_log"
  roster_status=0
  CMUX_PROJECT_LAUNCHER_AGENTS="$bad_roster" \
    CMUX_FAKE_EXPECT_SESSION=roster-invalid \
    CMUX_FAKE_EXPECT_PROJECT=roster-invalid \
    CMUX_FAKE_SEND_LOG="$send_log" \
    CMUX_FAKE_KEY_LOG="$key_log" \
    CMUX_FAKE_CREATE_LOG="$create_log" \
    CMUX_FAKE_SELECT_LOG="$select_log" \
    CMUX_FAKE_OPEN_LOG="$open_log" \
    CMUX_FAKE_CLOSE_LOG="$close_log" \
    CMUX_PROJECT_LAUNCHER_POLL=1 \
    CMUX_PROJECT_LAUNCHER_WAIT=0 \
    $launch_bash "$repo_root/bin/cmux-project-launch" roster-invalid >"$stdout_log" 2>"$tmp_dir/stderr.log" || roster_status=$?
  if [[ "$roster_status" -ne 2 ]]; then
    printf 'agent roster "%s" exited %s, expected 2\n' "$bad_roster" "$roster_status" >&2
    exit 1
  fi
  grep -Fq 'CMUX_PROJECT_LAUNCHER_AGENTS' "$tmp_dir/stderr.log"
  [[ ! -s "$event_log" ]]
  [[ ! -s "$create_log" ]]
  [[ ! -s "$send_log" ]]
  [[ ! -e "$fake_amq_root/roster-invalid" ]]
done

# Claude alone: one pane, a claude-only room, one exact wake, /start to Claude only.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$layout_log"
: >"$close_log"
CMUX_PROJECT_LAUNCHER_AGENTS=claude \
  CMUX_FAKE_AGENT_ROSTER=claude \
  CMUX_FAKE_EXPECT_ROSTER=claude,user \
  CMUX_FAKE_EXPECT_SESSION=solo-claude \
  CMUX_FAKE_EXPECT_PROJECT=solo-claude \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_LAYOUT_LOG="$layout_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_WORKSPACE_ROOT=/Users/example/git \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
  $launch_bash "$repo_root/bin/cmux-project-launch" solo-claude >"$stdout_log"

cat >"$expected_layout_log" <<'GOLDEN'
Project launcher: solo-claude (AMQ session: solo-claude)
{"pane":{"surfaces":[{"type":"terminal","name":"Claude","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_claude solo-claude -- --name claude-solo-claude'","focus":true}]}}
GOLDEN
if ! cmp -s "$expected_layout_log" "$layout_log"; then
  printf 'claude-only launch description/layout is wrong:\n' >&2
  diff "$expected_layout_log" "$layout_log" >&2 || true
  exit 1
fi
grep -Fxq $'init\t'"$fake_amq_root/solo-claude"$'\tclaude,user' "$event_log"
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]
grep -Fq $'reattach\tclaude\tcmux:surface:22222222-2222-4222-8222-222222222222' "$event_log"
grep -Fq $'surface:27\t/start solo-claude' "$send_log"
if grep -Fq 'surface:26' "$send_log" "$key_log" || grep -Fq '/rename' "$send_log"; then
  printf 'claude-only launch touched a Codex surface or sent a rename\n' >&2
  exit 1
fi
grep -Fq 'Launched solo-claude in workspace:10' "$stdout_log"
[[ ! -s "$close_log" ]]

# Codex alone: one pane, a codex-only room, the post-boot rename, $start to Codex only.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$layout_log"
: >"$close_log"
CMUX_PROJECT_LAUNCHER_AGENTS=codex \
  CMUX_FAKE_AGENT_ROSTER=codex \
  CMUX_FAKE_EXPECT_ROSTER=codex,user \
  CMUX_FAKE_EXPECT_SESSION=solo-codex \
  CMUX_FAKE_EXPECT_PROJECT=solo-codex \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_LAYOUT_LOG="$layout_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_WORKSPACE_ROOT=/Users/example/git \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
  $launch_bash "$repo_root/bin/cmux-project-launch" solo-codex >"$stdout_log"

cat >"$expected_layout_log" <<'GOLDEN'
Project launcher: solo-codex (AMQ session: solo-codex)
{"pane":{"surfaces":[{"type":"terminal","name":"Codex","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_codex solo-codex'","focus":true}]}}
GOLDEN
if ! cmp -s "$expected_layout_log" "$layout_log"; then
  printf 'codex-only launch description/layout is wrong:\n' >&2
  diff "$expected_layout_log" "$layout_log" >&2 || true
  exit 1
fi
grep -Fxq $'init\t'"$fake_amq_root/solo-codex"$'\tcodex,user' "$event_log"
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]
grep -Fq $'reattach\tcodex\tcmux:surface:11111111-1111-4111-8111-111111111111' "$event_log"
grep -Fq $'surface:26\t/rename' "$send_log"
grep -Fq $'surface:26\tcodex-solo-codex' "$send_log"
# shellcheck disable=SC2016
grep -Fq $'surface:26\t$start solo-codex' "$send_log"
if grep -Fq 'surface:27' "$send_log" "$key_log"; then
  printf 'codex-only launch touched a Claude surface\n' >&2
  exit 1
fi
grep -Fq 'Launched solo-codex in workspace:10' "$stdout_log"
[[ ! -s "$close_log" ]]

# The roster is a set: its written order changes neither the room nor the layout.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$layout_log"
: >"$close_log"
CMUX_PROJECT_LAUNCHER_AGENTS=codex,claude \
  CMUX_FAKE_EXPECT_SESSION=roster-order \
  CMUX_FAKE_EXPECT_PROJECT=roster-order \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_LAYOUT_LOG="$layout_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_WORKSPACE_ROOT=/Users/example/git \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
  $launch_bash "$repo_root/bin/cmux-project-launch" roster-order >"$stdout_log"

cat >"$expected_layout_log" <<'GOLDEN'
Project launcher: roster-order (AMQ session: roster-order)
{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"Codex","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_codex roster-order'","focus":true}]}},{"pane":{"surfaces":[{"type":"terminal","name":"Claude","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_claude roster-order -- --name claude-roster-order'"}]}}]}
GOLDEN
if ! cmp -s "$expected_layout_log" "$layout_log"; then
  printf 'codex,claude launch description/layout is wrong:\n' >&2
  diff "$expected_layout_log" "$layout_log" >&2 || true
  exit 1
fi
grep -Fxq $'init\t'"$fake_amq_root/roster-order"$'\tclaude,codex,user' "$event_log"
grep -Fq 'Launched roster-order in workspace:10' "$stdout_log"

# --no-start names only the agents that were launched.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$close_log"
CMUX_PROJECT_LAUNCHER_AGENTS=claude \
  CMUX_FAKE_AGENT_ROSTER=claude \
  CMUX_FAKE_EXPECT_ROSTER=claude,user \
  CMUX_FAKE_EXPECT_SESSION=solo-claude-adhoc \
  CMUX_FAKE_EXPECT_PROJECT=solo-claude-adhoc \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
  $launch_bash "$repo_root/bin/cmux-project-launch" --no-start solo-claude-adhoc >"$stdout_log"
grep -Fxq 'Launched ad-hoc workspace solo-claude-adhoc in workspace:10 (Claude name requested at boot; no /start sent)' "$stdout_log"
[[ ! -s "$send_log" ]]
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]

# make_fake_room <root> <agent>...: a room with real AMQ mailbox directories, so
# the cases below also hold when CMUX_PROJECT_LAUNCHER_REAL_AMQ runs doctor. Each
# test run has its own temporary AMQ root, so the room is always new.
make_fake_room() {
  local root="$1"
  local agent
  local config_agents=""
  shift
  mkdir -p "$root/meta"
  for agent in "$@"; do
    mkdir -p \
      "$root/agents/$agent/inbox/tmp" \
      "$root/agents/$agent/inbox/new" \
      "$root/agents/$agent/inbox/cur" \
      "$root/agents/$agent/outbox/sent" \
      "$root/agents/$agent/dlq/tmp" \
      "$root/agents/$agent/dlq/new" \
      "$root/agents/$agent/dlq/cur" \
      "$root/agents/$agent/receipts"
    config_agents="${config_agents:+$config_agents,}\"$agent\""
  done
  printf '{"version":1,"created_utc":"2026-10-01T00:00:00Z","agents":[%s]}\n' "$config_agents" >"$root/meta/config.json"
  chmod -R 700 "$root"
}

# room_case <project> [VAR=value]...: launch <project> with the fake binaries and
# the given extra environment, which overrides the defaults below; stdout,
# stderr, the layout and the exit status are kept.
room_case_status=0
room_case() {
  local project="$1"
  shift
  : >"$send_log"
  : >"$key_log"
  : >"$event_log"
  : >"$create_log"
  : >"$layout_log"
  : >"$close_log"
  : >"$added_panes"
  room_case_status=0
  # An empty $launch_bash must vanish, so the script runs under its own shebang.
  # shellcheck disable=SC2086
  env \
    CMUX_FAKE_EXPECT_SESSION="$project" \
    CMUX_FAKE_EXPECT_PROJECT="$project" \
    CMUX_FAKE_SEND_LOG="$send_log" \
    CMUX_FAKE_KEY_LOG="$key_log" \
    CMUX_FAKE_CREATE_LOG="$create_log" \
    CMUX_FAKE_LAYOUT_LOG="$layout_log" \
    CMUX_FAKE_SELECT_LOG="$select_log" \
    CMUX_FAKE_OPEN_LOG="$open_log" \
    CMUX_FAKE_CLOSE_LOG="$close_log" \
    CMUX_PROJECT_LAUNCHER_WORKSPACE_ROOT=/Users/example/git \
    CMUX_PROJECT_LAUNCHER_POLL=1 \
    CMUX_PROJECT_LAUNCHER_WAIT=0 \
    "$@" \
    $launch_bash "$repo_root/bin/cmux-project-launch" "$project" >"$stdout_log" 2>"$tmp_dir/stderr.log" || room_case_status=$?
}

# A new room starts with the app's Settings default.
room_case default-new CMUX_PROJECT_LAUNCHER_DEFAULT_AGENTS=codex CMUX_FAKE_AGENT_ROSTER=codex CMUX_FAKE_EXPECT_ROSTER=codex,user
[[ "$room_case_status" -eq 0 ]]
grep -Fxq $'init\t'"$fake_amq_root/default-new"$'\tcodex,user' "$event_log"
grep -Fq 'Launched default-new in workspace:10' "$stdout_log"

# An unusable default stops a new room before any AMQ or cmux mutation.
room_case default-invalid CMUX_PROJECT_LAUNCHER_DEFAULT_AGENTS=claude,nosuchagent
[[ "$room_case_status" -eq 2 ]]
grep -Fq 'CMUX_PROJECT_LAUNCHER_DEFAULT_AGENTS' "$tmp_dir/stderr.log"
[[ "$(awk -F '\t' '$1 == "init" { count++ } END { print count + 0 }' "$event_log")" -eq 0 ]]
[[ ! -s "$create_log" ]]

# The default is not read for an existing room, so an unusable default does not
# block a project whose room already says which agents it has.
make_fake_room "$fake_amq_root/room-keeps" claude codex user
room_case room-keeps CMUX_PROJECT_LAUNCHER_DEFAULT_AGENTS=claude,nosuchagent
[[ "$room_case_status" -eq 0 ]]
[[ "$(awk -F '\t' '$1 == "init" { count++ } END { print count + 0 }' "$event_log")" -eq 0 ]]
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
grep -Fq 'Launched room-keeps in workspace:10' "$stdout_log"

# A chosen agent the room lacks is added to the room, keeping its mailboxes and
# queued mail, before the workspace is created.
make_fake_room "$fake_amq_root/room-grows" claude user
room_case room-grows CMUX_PROJECT_LAUNCHER_AGENTS=claude,codex CMUX_FAKE_EXPECT_ROSTER=claude,user,codex
[[ "$room_case_status" -eq 0 ]]
grep -Fxq $'init\t'"$fake_amq_root/room-grows"$'\tclaude,user,codex\tforce' "$event_log"
grep -Fq 'Added codex to AMQ room room-grows' "$tmp_dir/stderr.log"
init_line="$(awk -F '\t' '$1 == "init" { print NR; exit }' "$event_log")"
workspace_create_line="$(awk -F '\t' '$1 == "workspace-create" { print NR; exit }' "$event_log")"
[[ "$init_line" -lt "$workspace_create_line" ]]
grep -Fq 'Launched room-grows in workspace:10' "$stdout_log"

# A room whose config holds keys that `amq init --force` would drop is not grown.
make_fake_room "$fake_amq_root/room-extra-keys" claude user
printf '{"version":1,"created_utc":"2026-10-01T00:00:00Z","agents":["claude","user"],"team":"x"}\n' \
  >"$fake_amq_root/room-extra-keys/meta/config.json"
room_case room-extra-keys CMUX_PROJECT_LAUNCHER_AGENTS=claude,codex
[[ "$room_case_status" -eq 1 ]]
grep -Fq 'team' "$tmp_dir/stderr.log"
[[ "$(awk -F '\t' '$1 == "init" { count++ } END { print count + 0 }' "$event_log")" -eq 0 ]]
[[ ! -s "$create_log" ]]

# A failed growth leaves the room as it was and creates no workspace.
make_fake_room "$fake_amq_root/room-grow-fails" claude user
room_case room-grow-fails CMUX_PROJECT_LAUNCHER_AGENTS=claude,codex CMUX_FAKE_AMQ_INIT_FAIL=1
[[ "$room_case_status" -eq 1 ]]
grep -Fq 'Could not add codex to AMQ room room-grow-fails' "$tmp_dir/stderr.log"
[[ ! -s "$create_log" ]]
grep -Fq '"agents":["claude","user"]' "$fake_amq_root/room-grow-fails/meta/config.json"

# Helper agents: Grok, Gemini and Codex on Cursor start through coopgrok,
# coopgemini and coopcursorcodex exactly as typed. Their own bootstrap attaches
# the wake on their exact pane; the launcher only waits for that wake and sends
# them no attach, rename, backlog doorbell or start prompt (Ohad, 2026-10-04).

# event_count <kind>: how many event-log lines start with <kind>.
event_count() {
  awk -F '\t' -v kind="$1" '$1 == kind { count++ } END { print count + 0 }' "$event_log"
}

# check_layout <label>: the captured description/layout must equal stdin.
check_layout() {
  cat >"$expected_layout_log"
  if ! cmp -s "$expected_layout_log" "$layout_log"; then
    printf '%s description/layout is wrong:\n' "$1" >&2
    diff "$expected_layout_log" "$layout_log" >&2 || true
    exit 1
  fi
}

# helper_panes_untouched: no prompt or key reached a Grok, Gemini or Codex on
# Cursor pane, and no backlog check ran for them.
helper_panes_untouched() {
  if grep -Eq '^surface:(28|29|30)'$'\t' "$send_log" "$key_log" \
    || grep -Eq $'^list\t(grok|gemini|cursorcodex)$' "$event_log"; then
    printf 'the launcher drove a helper-started agent pane\n' >&2
    exit 1
  fi
}

# Claude + Grok, the app's built-in default.
room_case duo-grok CMUX_PROJECT_LAUNCHER_AGENTS=claude,grok CMUX_FAKE_AGENT_ROSTER=claude,grok CMUX_FAKE_EXPECT_ROSTER=claude,grok,user
[[ "$room_case_status" -eq 0 ]]
check_layout 'claude,grok launch' <<'GOLDEN'
Project launcher: duo-grok (AMQ session: duo-grok)
{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"Claude","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_claude duo-grok -- --name claude-duo-grok'","focus":true}]}},{"pane":{"surfaces":[{"type":"terminal","name":"Grok","command":"cd /Users/example/git && zsh -ic 'coopgrok duo-grok'"}]}}]}
GOLDEN
grep -Fxq $'init\t'"$fake_amq_root/duo-grok"$'\tclaude,grok,user' "$event_log"
grep -Fxq $'helper-wake\tgrok\tcmux:surface:33333333-3333-4333-8333-333333333333' "$event_log"
[[ "$(event_count reattach)" -eq 1 ]]
grep -Fq $'reattach\tclaude\tcmux:surface:22222222-2222-4222-8222-222222222222' "$event_log"
grep -Fq $'surface:27\t/start duo-grok' "$send_log"
helper_panes_untouched
grep -Fq 'Launched duo-grok in workspace:10' "$stdout_log"
[[ ! -s "$close_log" ]]

# Three agents: three columns.
room_case trio CMUX_PROJECT_LAUNCHER_AGENTS=claude,codex,grok CMUX_FAKE_AGENT_ROSTER=codex,claude,grok CMUX_FAKE_EXPECT_ROSTER=claude,codex,grok,user
[[ "$room_case_status" -eq 0 ]]
check_layout 'codex,claude,grok launch' <<'GOLDEN'
Project launcher: trio (AMQ session: trio)
{"direction":"horizontal","split":0.3333,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"Codex","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_codex trio'","focus":true}]}},{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"Claude","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_claude trio -- --name claude-trio'"}]}},{"pane":{"surfaces":[{"type":"terminal","name":"Grok","command":"cd /Users/example/git && zsh -ic 'coopgrok trio'"}]}}]}]}
GOLDEN
[[ "$(event_count reattach)" -eq 2 ]]
grep -Fq $'surface:26\tcodex-trio' "$send_log"
# shellcheck disable=SC2016
grep -Fq $'surface:26\t$start trio' "$send_log"
grep -Fq $'surface:27\t/start trio' "$send_log"
helper_panes_untouched
grep -Fq 'Launched trio in workspace:10' "$stdout_log"

# Four agents: two over two.
room_case quad CMUX_PROJECT_LAUNCHER_AGENTS=claude,grok,gemini,cursorcodex CMUX_FAKE_AGENT_ROSTER=claude,grok,gemini,cursorcodex CMUX_FAKE_EXPECT_ROSTER=claude,grok,gemini,cursorcodex,user
[[ "$room_case_status" -eq 0 ]]
check_layout 'claude,grok,gemini,cursorcodex launch' <<'GOLDEN'
Project launcher: quad (AMQ session: quad)
{"direction":"vertical","split":0.5,"children":[{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"Claude","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_claude quad -- --name claude-quad'","focus":true}]}},{"pane":{"surfaces":[{"type":"terminal","name":"Grok","command":"cd /Users/example/git && zsh -ic 'coopgrok quad'"}]}}]},{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"Gemini","command":"cd /Users/example/git && zsh -ic 'coopgemini quad'"}]}},{"pane":{"surfaces":[{"type":"terminal","name":"CursorCodex","command":"cd /Users/example/git && zsh -ic 'coopcursorcodex quad'"}]}}]}]}
GOLDEN
[[ "$(event_count reattach)" -eq 1 ]]
[[ "$(event_count helper-wake)" -eq 3 ]]
grep -Fq $'surface:27\t/start quad' "$send_log"
helper_panes_untouched
grep -Fq 'Launched quad in workspace:10' "$stdout_log"

# All five: three over two.
room_case all-five CMUX_PROJECT_LAUNCHER_AGENTS=cursorcodex,gemini,grok,codex,claude CMUX_FAKE_AGENT_ROSTER=codex,claude,grok,gemini,cursorcodex CMUX_FAKE_EXPECT_ROSTER=claude,codex,grok,gemini,cursorcodex,user
[[ "$room_case_status" -eq 0 ]]
check_layout 'all-five launch' <<'GOLDEN'
Project launcher: all-five (AMQ session: all-five)
{"direction":"vertical","split":0.5,"children":[{"direction":"horizontal","split":0.3333,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"Codex","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_codex all-five'","focus":true}]}},{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"Claude","command":"cd /Users/example/git && zsh -ic 'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_claude all-five -- --name claude-all-five'"}]}},{"pane":{"surfaces":[{"type":"terminal","name":"Grok","command":"cd /Users/example/git && zsh -ic 'coopgrok all-five'"}]}}]}]},{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"Gemini","command":"cd /Users/example/git && zsh -ic 'coopgemini all-five'"}]}},{"pane":{"surfaces":[{"type":"terminal","name":"CursorCodex","command":"cd /Users/example/git && zsh -ic 'coopcursorcodex all-five'"}]}}]}]}
GOLDEN
grep -Fxq $'init\t'"$fake_amq_root/all-five"$'\tclaude,codex,grok,gemini,cursorcodex,user' "$event_log"
[[ "$(event_count reattach)" -eq 2 ]]
[[ "$(event_count helper-wake)" -eq 3 ]]
# shellcheck disable=SC2016
grep -Fq $'surface:26\t$start all-five' "$send_log"
grep -Fq $'surface:27\t/start all-five' "$send_log"
helper_panes_untouched
grep -Fq 'Launched all-five in workspace:10' "$stdout_log"

# Grok alone: no launcher attach and no prompt at all.
room_case solo-grok CMUX_PROJECT_LAUNCHER_AGENTS=grok CMUX_FAKE_AGENT_ROSTER=grok CMUX_FAKE_EXPECT_ROSTER=grok,user
[[ "$room_case_status" -eq 0 ]]
check_layout 'grok-only launch' <<'GOLDEN'
Project launcher: solo-grok (AMQ session: solo-grok)
{"pane":{"surfaces":[{"type":"terminal","name":"Grok","command":"cd /Users/example/git && zsh -ic 'coopgrok solo-grok'","focus":true}]}}
GOLDEN
[[ "$(event_count reattach)" -eq 0 ]]
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
grep -Fq 'Launched solo-grok in workspace:10' "$stdout_log"

# A helper wake that registers late is waited for, and Claude's /start follows it.
room_case helper-late CMUX_PROJECT_LAUNCHER_AGENTS=claude,grok CMUX_FAKE_AGENT_ROSTER=claude,grok CMUX_FAKE_EXPECT_ROSTER=claude,grok,user CMUX_FAKE_HELPER_WAKE_DELAY=2 CMUX_PROJECT_LAUNCHER_POLL=8
[[ "$room_case_status" -eq 0 ]]
helper_wake_line="$(awk -F '\t' '$1 == "helper-wake" { print NR; exit }' "$event_log")"
start_line="$(awk -F '\t' '$1 == "send" && $3 == "/start helper-late" { print NR; exit }' "$event_log")"
[[ -n "$helper_wake_line" && -n "$start_line" && "$helper_wake_line" -lt "$start_line" ]]
grep -Fq 'Launched helper-late in workspace:10' "$stdout_log"

# A helper wake that never reaches the exact pane fails the launch: no prompt to
# anyone, the workspace is closed and every launched identity is retired.
for helper_failure in CMUX_FAKE_HELPER_WAKE_SKIP=grok CMUX_FAKE_HELPER_WAKE_TARGET=wrong; do
  helper_project="helper-fail-${helper_failure##*=}"
  room_case "$helper_project" CMUX_PROJECT_LAUNCHER_AGENTS=claude,grok CMUX_FAKE_AGENT_ROSTER=claude,grok CMUX_FAKE_EXPECT_ROSTER=claude,grok,user "$helper_failure"
  if [[ "$room_case_status" -ne 1 ]]; then
    printf '%s exited %s, expected 1\n' "$helper_failure" "$room_case_status" >&2
    exit 1
  fi
  grep -Fq 'Grok surface surface:28' "$tmp_dir/stderr.log"
  grep -Fq 'no AMQ wake for grok on cmux:surface:33333333-3333-4333-8333-333333333333' "$tmp_dir/stderr.log"
  [[ ! -s "$send_log" ]]
  [[ "$(event_count reattach)" -eq 0 ]]
  grep -Fq 'workspace:10' "$close_log"
  grep -Fxq $'retire\tclaude,grok' "$event_log"
done

# --no-start names what each launched agent rests on, in roster order.
: >"$send_log"
: >"$key_log"
: >"$event_log"
: >"$create_log"
: >"$close_log"
CMUX_PROJECT_LAUNCHER_AGENTS=claude,grok \
  CMUX_FAKE_AGENT_ROSTER=claude,grok \
  CMUX_FAKE_EXPECT_ROSTER=claude,grok,user \
  CMUX_FAKE_EXPECT_SESSION=duo-adhoc \
  CMUX_FAKE_EXPECT_PROJECT=duo-adhoc \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_SELECT_LOG="$select_log" \
  CMUX_FAKE_OPEN_LOG="$open_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
  CMUX_PROJECT_LAUNCHER_WAIT=0 \
  $launch_bash "$repo_root/bin/cmux-project-launch" --no-start duo-adhoc >"$stdout_log"
grep -Fxq 'Launched ad-hoc workspace duo-adhoc in workspace:10 (Claude name requested at boot; Grok started by coopgrok; no /start sent)' "$stdout_log"
[[ ! -s "$send_log" ]]
[[ "$(event_count reattach)" -eq 1 ]]

# A live workspace holding all five agents, each with its exact wake and its
# process, is reattached as it is.
make_fake_room "$fake_amq_root/live-five" claude codex grok gemini cursorcodex user
setup_fake_wakes live-five
"$fake_helper_wake" live-five grok 33333333-3333-4333-8333-333333333333
"$fake_helper_wake" live-five gemini 44444444-4444-4444-8444-444444444444
"$fake_helper_wake" live-five cursorcodex 55555555-5555-4555-8555-555555555555
: >"$select_log"
room_case live-five CMUX_FAKE_AGENT_ROSTER=codex,claude,grok,gemini,cursorcodex CMUX_FAKE_AMQ_WHO_MODE=expected-active CMUX_FAKE_WORKSPACE_LIST_MODE=expected-project CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7
[[ "$room_case_status" -eq 0 ]]
if grep -Fq 'cannot start' "$tmp_dir/stderr.log"; then
  printf 'live-five skipped room agents it should check\n' >&2
  exit 1
fi
grep -Fq 'Reattached live-five in workspace:7 using AMQ session live-five' "$stdout_log"
grep -Fq 'workspace:7' "$select_log"
[[ ! -s "$create_log" ]]
[[ ! -s "$send_log" ]]

# The same workspace whose Gemini has exited to the shell is opened for
# inspection, not reported as reattached.
room_case live-five CMUX_FAKE_AGENT_ROSTER=codex,claude,grok,gemini,cursorcodex CMUX_FAKE_AMQ_WHO_MODE=expected-active CMUX_FAKE_WORKSPACE_LIST_MODE=expected-project CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7 CMUX_FAKE_SHELL_TTYS=ttys029
[[ "$room_case_status" -eq 1 ]]
grep -Fq 'its Gemini surface has no live Gemini process' "$tmp_dir/stderr.log"
[[ ! -s "$create_log" ]]
[[ ! -s "$send_log" ]]

# Live growth: a ticked agent whose pane a live workspace lacks gets a new pane
# there (Ohad, 2026-10-04). The room grows first, the pane is named for the
# next launch's checks, and the agents already running are left alone.
live_room_args=(
  CMUX_FAKE_AMQ_WHO_MODE=expected-active
  CMUX_FAKE_WORKSPACE_LIST_MODE=expected-project
  CMUX_FAKE_RUNTIME_WORKSPACE=workspace:7
)

# Grok joins a live Claude workspace whose room lacks it.
make_fake_room "$fake_amq_root/live-grow" claude user
setup_fake_wakes live-grow claude
room_case live-grow "${live_room_args[@]}" CMUX_PROJECT_LAUNCHER_AGENTS=claude,grok CMUX_FAKE_AGENT_ROSTER=claude CMUX_FAKE_EXPECT_ROSTER=claude,user,grok
[[ "$room_case_status" -eq 0 ]]
grep -Fxq $'init\t'"$fake_amq_root/live-grow"$'\tclaude,user,grok\tforce' "$event_log"
grep -Fxq $'new-pane\tgrok\tcd /Users/example/git && zsh -ic \'coopgrok live-grow\'' "$event_log"
grep -Fxq $'rename-tab\tsurface:28\tGrok' "$event_log"
grep -Fxq $'helper-wake\tgrok\tcmux:surface:33333333-3333-4333-8333-333333333333' "$event_log"
init_line="$(awk -F '\t' '$1 == "init" { print NR; exit }' "$event_log")"
new_pane_line="$(awk -F '\t' '$1 == "new-pane" { print NR; exit }' "$event_log")"
[[ "$init_line" -lt "$new_pane_line" ]]
[[ "$(event_count new-pane)" -eq 1 ]]
[[ "$(event_count reattach)" -eq 0 ]]
[[ "$(event_count workspace-create)" -eq 0 ]]
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$close_log" ]]
grep -Fq 'Added Grok to live-grow in workspace:7 using AMQ session live-grow' "$stdout_log"

# Codex joins a live Claude workspace: the launcher attaches, names and starts
# the new Codex pane only.
make_fake_room "$fake_amq_root/live-codex" claude user
setup_fake_wakes live-codex claude
room_case live-codex "${live_room_args[@]}" CMUX_PROJECT_LAUNCHER_AGENTS=claude,codex CMUX_FAKE_AGENT_ROSTER=claude CMUX_FAKE_EXPECT_ROSTER=claude,user,codex
[[ "$room_case_status" -eq 0 ]]
grep -Fxq $'new-pane\tcodex\tcd /Users/example/git && zsh -ic \'AMQ_COOP_WAKE_FLAG=--no-wake AMQ_KEEPALIVE_DISABLED=1 amq_codex live-codex\'' "$event_log"
grep -Fxq $'rename-tab\tsurface:26\tCodex' "$event_log"
[[ "$(event_count reattach)" -eq 1 ]]
grep -Fq $'reattach\tcodex\tcmux:surface:11111111-1111-4111-8111-111111111111' "$event_log"
grep -Fq $'surface:26\tcodex-live-codex' "$send_log"
# shellcheck disable=SC2016
grep -Fq $'surface:26\t$start live-codex' "$send_log"
if grep -Fq 'surface:27' "$send_log" "$key_log"; then
  printf 'live growth drove the Claude pane that was already running\n' >&2
  exit 1
fi
[[ "$(event_count workspace-create)" -eq 0 ]]
grep -Fq 'Added Codex to live-codex in workspace:7 using AMQ session live-codex' "$stdout_log"

# An added pane whose helper wake never arrives is closed again; the live
# workspace stays, and only the added agent's identity is retired.
make_fake_room "$fake_amq_root/live-grow-fails" claude user
setup_fake_wakes live-grow-fails claude
room_case live-grow-fails "${live_room_args[@]}" CMUX_PROJECT_LAUNCHER_AGENTS=claude,grok CMUX_FAKE_AGENT_ROSTER=claude CMUX_FAKE_EXPECT_ROSTER=claude,user,grok CMUX_FAKE_HELPER_WAKE_SKIP=grok
[[ "$room_case_status" -eq 1 ]]
grep -Fq 'no AMQ wake for grok on cmux:surface:33333333-3333-4333-8333-333333333333' "$tmp_dir/stderr.log"
grep -Fxq $'close-surface\tsurface:28' "$event_log"
grep -Fxq $'retire\tgrok' "$event_log"
[[ ! -s "$close_log" ]]
[[ ! -s "$send_log" ]]

# A missing pane whose agent still has a live AMQ wake is not re-added: that
# wake would be a second one for the same agent.
make_fake_room "$fake_amq_root/live-stale-wake" claude grok user
setup_fake_wakes live-stale-wake claude
"$fake_amq" wake </dev/null >/dev/null 2>&1 &
stale_wake_pid=$!
background_pids+=("$stale_wake_pid")
printf '{"pid":%s,"root":"%s","agent":"grok"}\n' "$stale_wake_pid" "$fake_amq_root/live-stale-wake" \
  >"$fake_amq_root/live-stale-wake/agents/grok/.wake.lock"
room_case live-stale-wake "${live_room_args[@]}" CMUX_FAKE_AGENT_ROSTER=claude
[[ "$room_case_status" -eq 1 ]]
grep -Fq 'Grok' "$tmp_dir/stderr.log"
grep -Fq 'live AMQ wake' "$tmp_dir/stderr.log"
[[ "$(event_count new-pane)" -eq 0 ]]
[[ "$(event_count init)" -eq 0 ]]
[[ ! -s "$send_log" ]]
kill "$stale_wake_pid" 2>/dev/null || true

# A dry run of live growth prints the room growth and the new pane, and changes
# nothing. The room is not grown in a dry run, so its health is not judged
# against the agents it would gain.
make_fake_room "$fake_amq_root/live-grow-dry" claude user
setup_fake_wakes live-grow-dry claude
room_case live-grow-dry "${live_room_args[@]}" CMUX_PROJECT_LAUNCHER_AGENTS=claude,grok CMUX_FAKE_AGENT_ROSTER=claude CMUX_PROJECT_LAUNCHER_DRY_RUN=1
if [[ "$room_case_status" -ne 0 ]]; then
  printf 'live growth dry run exited %s, expected 0\n' "$room_case_status" >&2
  exit 1
fi
grep -Fq 'would add grok to AMQ session' "$stdout_log"
grep -Fq 'cmux new-pane --workspace workspace:7 --direction right --command' "$stdout_log"
grep -Fq 'coopgrok' "$stdout_log"
grep -Fq 'cmux rename-tab --workspace workspace:7 --surface <new surface> Grok' "$stdout_log"
[[ "$(event_count init)" -eq 0 ]]
[[ "$(event_count new-pane)" -eq 0 ]]
[[ "$(event_count workspace-create)" -eq 0 ]]
grep -Fq '"agents":["claude","user"]' "$fake_amq_root/live-grow-dry/meta/config.json"

printf 'ok - cmux project launch shell fixtures passed\n'
