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
select_log="$tmp_dir/select.log"
open_log="$tmp_dir/open.log"
close_log="$tmp_dir/close.log"
keepalive_log="$tmp_dir/keepalive.log"
event_log="$tmp_dir/event.log"
stdout_log="$tmp_dir/stdout.log"
diagnostics_log="$tmp_dir/launcher.log"
background_pids=()
mkdir -p "$fake_amq_root"
export CMUX_PROJECT_LAUNCHER_LOG="$diagnostics_log"
export CMUX_FAKE_EVENT_LOG="$event_log"
export CMUX_FAKE_AMQ_ROOT="$fake_amq_root"
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
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

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
        [[ "$layout" == *"amq_codex $expected_session"* ]]
        [[ "$layout" == *"amq_claude $expected_session"* ]]
        [[ "$layout" == *"AMQ_COOP_WAKE_FLAG=--no-wake"* ]]
        [[ "$layout" != *"AMQ_COOP_WAKE_FLAG=--defer-wake"* ]]
        [[ "$layout" == *"AMQ_KEEPALIVE_DISABLED=1"* ]]
        [[ "$layout" != *"AMQ_KEEPALIVE_BIN="* ]]
        # Claude is named at boot via `--name claude-<session>` forwarded through amq_claude.
        [[ "$layout" == *"amq_claude $expected_session -- --name claude-$expected_session"* ]]
        # Codex has no boot flag, so its command must NOT carry a --name.
        [[ "$layout" != *"amq_codex $expected_session --name"* ]]
        [[ "$layout" != *"coopcodex $expected_session"* ]]
        [[ "$layout" != *"coopcc $expected_session"* ]]
        [[ "$layout" != *"amq coop exec"* ]]
        [[ "$layout" != *"--require-wake"* ]]
        mkdir -p "${CMUX_FAKE_AMQ_ROOT:?}/$expected_session/agents/codex"
        mkdir -p "${CMUX_FAKE_AMQ_ROOT:?}/$expected_session/agents/claude"
        printf '%s\n' "$expected_session" >>"${CMUX_FAKE_CREATE_LOG:?}"
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
    printf '* pane:12 [1 surface] [focused]\n'
    printf 'pane:11 [1 surface]\n'
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
      "")
        # Real cmux defaults to the focused pane when --pane is omitted.
        if [[ "$id_format" == "both" ]]; then
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
        if [[ "$send_count" -eq 0 ]]; then
          printf '> \n'
        elif [[ "$send_count" -eq 1 && "$key_count" -eq 0 ]]; then
          printf '> /rename\n'
        elif [[ "$send_count" -eq 1 ]]; then
          if [[ "$rename_mode" == "no-modal" ]]; then
            printf '> \n'
          else
            printf 'Name thread\nType a name and press Enter\n> \n'
          fi
        elif [[ "$send_count" -eq 2 && "$key_count" -eq 1 ]]; then
          printf 'Name thread\n> %s\n' "$rename_name"
        elif [[ "$send_count" -eq 2 && "$key_count" -eq 2 ]]; then
          if [[ "$rename_mode" == "vanished" ]]; then
            printf '> \n'
          elif [[ "$rename_mode" == "stale-modal" ]]; then
            printf 'Name thread\n> %s\nPress enter to confirm\n> ordinary prompt\n' "$rename_name"
          elif [[ "$rename_mode" == "missed-enter" || "$rename_mode" == "no-success" ]]; then
            printf 'Name thread\n> %s\nPress enter to confirm\n' "$rename_name"
          else
            printf 'Session renamed to %s. To resume this session run codex resume %s\n> \n' "$rename_name" "$rename_name"
          fi
        elif [[ "$send_count" -eq 2 ]]; then
          if [[ "$rename_mode" == "no-success" ]]; then
            printf 'Name thread\n> %s\nPress enter to confirm\n' "$rename_name"
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
    elif [[ "${CMUX_FAKE_MODE:-ready}" == "ghostty-only" ]]; then
      printf '[0] surface:26 "Codex" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:11\n' "$runtime_workspace"
      printf '    runtime=1 focused=1 selected=1 terminal=0x1 ghostty=0x2\n'
      printf '[1] surface:27 "Claude" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:12\n' "$runtime_workspace"
      printf '    runtime=1 focused=0 selected=1 terminal=0x3 ghostty=0x4\n'
    else
      printf '[0] surface:26 "Codex" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:11\n' "$runtime_workspace"
      printf '    runtime=1 focused=1 selected=1 terminal=0x1 ghostty=0x2\n'
      printf '    tty=ttys026 cwd=/Users/example/git\n'
      printf '[1] surface:27 "Claude" mapped=1 tree=1 window=window:1 workspace=%s pane=pane:12\n' "$runtime_workspace"
      printf '    runtime=1 focused=0 selected=1 terminal=0x3 ghostty=0x4\n'
      printf '    tty=ttys027 cwd=/Users/example/git\n'
    fi
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
    else
      printf '[]\n'
    fi
    ;;
  env)
    cat <<JSON
{"base_root":"$CMUX_FAKE_AMQ_ROOT","root":"$CMUX_FAKE_AMQ_ROOT"}
JSON
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
    exit 1
  fi
  root="${CMUX_FAKE_WAKE_COMMAND_ROOT:-${CMUX_FAKE_AMQ_ROOT:?}/${CMUX_FAKE_WAKE_SESSION:?}}"
  printf '/tmp/amq wake -root %s -me %s -inject-via /tmp/amq-keepalive -inject-arg inject -inject-arg cmux -inject-arg %s\n' \
    "$root" "$agent" "$target"
  exit 0
fi

case "${CMUX_FAKE_AGENT_PROCESS_MODE:-ready}:$tty" in
  ready:ttys026)
    printf '/Users/example/.local/bin/codex-pretty --enable hooks\n'
    ;;
  ready:ttys027)
    printf '/opt/homebrew/bin/claude --session-id fixture\n'
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

setup_fake_wakes() {
  local session="$1"
  local session_root="$fake_amq_root/$session"
  mkdir -p "$session_root/agents/codex" "$session_root/agents/claude"
  sleep 120 &
  codex_wake_pid=$!
  sleep 120 &
  claude_wake_pid=$!
  background_pids+=("$codex_wake_pid" "$claude_wake_pid")
  printf '{"pid":%s,"root":"%s","agent":"codex"}\n' "$codex_wake_pid" "$session_root" \
    >"$session_root/agents/codex/.wake.lock"
  printf '{"pid":%s,"root":"%s","agent":"claude"}\n' "$claude_wake_pid" "$session_root" \
    >"$session_root/agents/claude/.wake.lock"
  export CMUX_FAKE_CODEX_WAKE_PID="$codex_wake_pid"
  export CMUX_FAKE_CLAUDE_WAKE_PID="$claude_wake_pid"
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
    agent=""
    target=""
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
        --baseline-file)
          printf 'removed --baseline-file argument was used\n' >&2
          exit 65
          ;;
        *)
          shift
          ;;
      esac
    done
    printf 'reattach\t%s\t%s\n' "$agent" "$target" >>"${CMUX_FAKE_EVENT_LOG:?}"
    if [[ "${CMUX_FAKE_REATTACH_MODE:-success}" != "success" ]]; then
      printf 'reattach refused\n' >&2
      exit 1
    fi
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
# Fail closed at fixture scope: even a test case that accidentally omits one
# inline override must never reach the production cmux, AMQ, or open binaries.
export CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux"
export CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq"
export CMUX_PROJECT_LAUNCHER_OPEN="$fake_open"
export CMUX_PROJECT_LAUNCHER_AMQ_ROOT="$fake_amq_root"

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
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
grep -Fq $'reattach\tcodex\tcmux:surface:11111111-1111-4111-8111-111111111111' "$event_log"
grep -Fq $'reattach\tclaude\tcmux:surface:22222222-2222-4222-8222-222222222222' "$event_log"

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
[[ "$(awk -F '\t' '$1 == "reattach" { count++ } END { print count + 0 }' "$event_log")" -eq 1 ]]

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
mkdir -p "$fake_amq_root/demo-project"
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
[[ "$(awk -F '\t' '$1 == "list" { count++ } END { print count + 0 }' "$event_log")" -eq 2 ]]
[[ "$(awk -F '\t' '$1 == "inject" { count++ } END { print count + 0 }' "$event_log")" -eq 0 ]]
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

printf 'ok - cmux project launch shell fixtures passed\n'
