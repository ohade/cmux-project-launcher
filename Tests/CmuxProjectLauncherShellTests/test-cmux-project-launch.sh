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
fake_amq_root="$tmp_dir/amq-root"
send_log="$tmp_dir/send.log"
key_log="$tmp_dir/key.log"
create_log="$tmp_dir/create.log"
select_log="$tmp_dir/select.log"
open_log="$tmp_dir/open.log"
close_log="$tmp_dir/close.log"
stdout_log="$tmp_dir/stdout.log"
background_pids=()
mkdir -p "$fake_amq_root"
cleanup() {
  if [[ "${#background_pids[@]}" -gt 0 ]]; then
    kill "${background_pids[@]}" 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat >"$fake_cmux" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:?missing command}"
shift

case "$cmd" in
  workspace)
    subcmd="${1:?missing workspace subcommand}"
    shift
    case "$subcmd" in
      create)
        layout=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
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
        [[ "$layout" == *"coopcodex $expected_session"* ]]
        [[ "$layout" == *"coopcc $expected_session"* ]]
        [[ "$layout" != *"amq coop exec"* ]]
        [[ "$layout" != *"--no-wake"* ]]
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
    {"ref":"workspace:7","title":"demo-project","selected":false}
  ]
}
JSON
            ;;
          multi)
            cat <<'JSON'
{
  "window_ref": "window:1",
  "workspaces": [
    {"ref":"workspace:4","title":"demo-project","selected":false,"index":4},
    {"ref":"workspace:7","title":"demo-project","selected":true,"index":7}
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
    case "$pane" in
      pane:12)
        printf '* surface:27 Claude [selected]\n'
        ;;
      pane:11)
        printf 'surface:26 Codex\n'
        ;;
      "")
        printf '* surface:27 Claude [selected]\n'
        printf 'surface:26 Codex\n'
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
      if [[ -n "$payload" && "$key_count" -eq 0 ]]; then
        printf '> %s\n' "$payload"
      elif [[ -n "$payload" ]]; then
        printf 'Working on request\n'
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

case "${1:?missing command}" in
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
  wake)
    sleep 120
    ;;
  *)
    printf 'unexpected amq command: %s\n' "$1" >&2
    exit 64
    ;;
esac
SH
chmod +x "$fake_amq"

cat >"$fake_open" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${CMUX_FAKE_OPEN_LOG:?}"
SH
chmod +x "$fake_open"

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

grep -Fq $'surface:26\t$start demo-project' "$send_log"
grep -Fq $'surface:27\t/start demo-project' "$send_log"
grep -Fq $'surface:26\tenter' "$key_log"
grep -Fq $'surface:27\tenter' "$key_log"
grep -Fq 'demo-project' "$create_log"
grep -Fq 'Launched demo-project in workspace:10' "$stdout_log"
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
grep -Fq 'wake lock' "$tmp_dir/stderr.log"

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
[[ ! -s "$select_log" ]]
[[ ! -s "$open_log" ]]

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
if CMUX_FAKE_AMQ_WHO_MODE=demo-project-active \
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
  printf 'active-amq-without-workspace launch unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'already active' "$tmp_dir/stderr.log"
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
if CMUX_FAKE_SEND_LOG="$send_log" \
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
  printf 'wake-lock-without-workspace launch unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'already active' "$tmp_dir/stderr.log"
[[ ! -s "$send_log" ]]
[[ ! -s "$key_log" ]]
[[ ! -s "$create_log" ]]
[[ ! -s "$select_log" ]]
[[ ! -s "$open_log" ]]
rm -rf "$fake_amq_root/demo-project" "$fake_amq_root/demo-project-2"

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
