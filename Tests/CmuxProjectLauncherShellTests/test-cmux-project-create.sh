#!/usr/bin/env bash
set -euo pipefail

# This fake cmux harness asserts the emitted layout shape, but it still returns
# fixed panes/surfaces. Layout semantics changes need a live cmux probe until the
# fake derives panes and surfaces from --layout JSON.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Optional interpreter for the script-under-test. Empty = honor the script's own
# `#!/usr/bin/env bash` shebang. Set CMUX_TEST_SCRIPT_BASH=/bin/bash to exercise the
# bash-3.2 path the GUI .app hits (where `mapfile` does not exist).
create_bash="${CMUX_TEST_SCRIPT_BASH:-}"
tmp_dir="$(mktemp -d)"

fake_cmux="$tmp_dir/cmux"
fake_amq="$tmp_dir/amq"
fake_claude="$tmp_dir/claude"
fake_commit_progress="$tmp_dir/commit-progress.sh"
fake_repo="$tmp_dir/claude-repo"
fake_progress="$fake_repo/project-git/progress"
send_log="$tmp_dir/send.log"
key_log="$tmp_dir/key.log"
create_log="$tmp_dir/create.log"
close_log="$tmp_dir/close.log"
brief_file="$tmp_dir/brief.json"
draft_file="$tmp_dir/draft.json"
stdout_log="$tmp_dir/stdout.log"
stderr_log="$tmp_dir/stderr.log"
mkdir -p "$fake_progress"
git -C "$fake_repo" init -q
git -C "$fake_repo" config user.name "Cmux Test"
git -C "$fake_repo" config user.email "cmux-test@example.invalid"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat >"$brief_file" <<'JSON'
{
  "name": "display",
  "description": "Build a display flow.",
  "initial_intent": "Create the first UI slice.",
  "jira": "DEMO-1",
  "plane": "",
  "notes": "Keep it small.",
  "rough_prompt": "Infer the missing details."
}
JSON

cat >"$fake_claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" != *"--dangerously-skip-permissions"* ]]
if [[ "${CMUX_FAKE_CLAUDE_MODE:-json}" == "invalid" ]]; then
  printf 'I cannot produce JSON for this request.\n'
  exit 0
fi
cat <<'JSON'
Here is the result:
```json
{
  "name": "display",
  "description": "Build a display flow.",
  "initial_intent": "Create the first UI slice.",
  "jira": "DEMO-1",
  "plane": "",
  "notes": "Keep it small.",
  "confidence": "high",
  "unresolved_questions": []
}
```
JSON
SH
chmod +x "$fake_claude"

cat >"$fake_amq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:?missing command}" in
  who)
    printf '%s\n' "${CMUX_FAKE_AMQ_WHO_JSON:-[]}"
    ;;
  env)
    printf '{"base_root":"%s","root":"%s"}\n' "${CMUX_FAKE_AMQ_ROOT:?}" "${CMUX_FAKE_AMQ_ROOT:?}"
    ;;
  *)
    printf 'unexpected amq command: %s\n' "$1" >&2
    exit 64
    ;;
esac
SH
chmod +x "$fake_amq"
fallback_amq_dir="$tmp_dir/fallback-amq-bin"
mkdir -p "$fallback_amq_dir"
cp "$fake_amq" "$fallback_amq_dir/amq"
chmod +x "$fallback_amq_dir/amq"

cat >"$fake_commit_progress" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

action="${1:?missing action}"
project="${2:?missing project}"
repo="${CMUX_FAKE_PROGRESS_REPO:?}"
prog="project-git/progress/progress__${project}.md"
arch="project-git/progress/archive/progress__${project}.md"

case "$action" in
  create|update)
    paths=("$prog")
    ;;
  archive|unarchive)
    paths=("$prog" "$arch")
    ;;
  *)
    printf 'unexpected action: %s\n' "$action" >&2
    exit 64
    ;;
esac

git -C "$repo" add -A -- "${paths[@]}"
if git -C "$repo" diff --cached --quiet -- "${paths[@]}"; then
  exit 0
fi
git -C "$repo" commit -q -m "progress: ${action} ${project}" -- "${paths[@]}"
sha="$(git -C "$repo" rev-parse --short HEAD)"
case "${CMUX_FAKE_PUSH_FAIL_ACTION:-}" in
  "$action")
    printf 'commit-progress.sh: %s committed %s; push_exit=2\n' "$action" "$sha"
    exit 2
    ;;
esac
if [[ "$action" == "update" ]]; then
  printf 'commit-progress.sh: committed %s; push_exit=0; journal: captured\n' "$sha"
else
  printf 'commit-progress.sh: %s committed %s; push_exit=0\n' "$action" "$sha"
fi
SH
chmod +x "$fake_commit_progress"

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
        name=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --name)
              name="${2:?missing workspace name}"
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
        expected_session="${CMUX_FAKE_EXPECT_SESSION:-display}"
        [[ "$name" == "$expected_session" ]]
        [[ "$layout" == *"coopcodex $expected_session"* ]]
        [[ "$layout" == *"coopcc $expected_session"* ]]
        printf '%s\t%s\n' "$name" "$layout" >>"${CMUX_FAKE_CREATE_LOG:?}"
        printf 'OK workspace:42\n'
        ;;
      close)
        printf '%s\n' "${1:?missing workspace}" >>"${CMUX_FAKE_CLOSE_LOG:?}"
        printf 'OK %s\n' "$1"
        ;;
      select)
        printf 'OK\n'
        ;;
      *)
        printf 'unexpected workspace subcommand: %s\n' "$subcmd" >&2
        exit 64
        ;;
    esac
    ;;
  list-panes)
    printf '* pane:11 [1 surface] [focused]\n'
    printf '  pane:12 [1 surface]\n'
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
      pane:11)
        printf '* surface:26 Codex [selected]\n'
        ;;
      pane:12)
        printf 'surface:27 Claude\n'
        ;;
      *)
        printf '* surface:26 Codex [selected]\n'
        printf 'surface:27 Claude\n'
        ;;
    esac
    ;;
  debug-terminals)
    printf '[0] surface:26 "Codex" mapped=1 tree=1 window=window:1 workspace=workspace:42 pane=pane:11\n'
    printf '    runtime=1 focused=1 selected=1 terminal=0x3 ghostty=0x4\n'
    printf '    tty=ttys026 cwd=/Users/example/git\n'
    printf '[0] surface:27 "Claude" mapped=1 tree=1 window=window:1 workspace=workspace:42 pane=pane:12\n'
    printf '    runtime=1 focused=0 selected=0 terminal=0x1 ghostty=0x2\n'
    printf '    tty=ttys027 cwd=/Users/example/git\n'
    ;;
  read-screen)
    surface=""
    read_args=("$@")
    for ((i = 0; i < ${#read_args[@]}; i++)); do
      if [[ "${read_args[$i]}" == "--surface" && $((i + 1)) -lt ${#read_args[@]} ]]; then
        surface="${read_args[$((i + 1))]}"
      fi
    done
    if [[ "$surface" == "surface:26" ]]; then
      printf 'OpenAI Codex\n'
      printf 'gpt-5.4 100%% left\n'
      exit 0
    fi
    if [[ "${CMUX_FAKE_READ_FAIL_AFTER_START:-0}" == "1" && -f "${CMUX_FAKE_FAIL_AFTER_START_MARKER:?}" ]]; then
      printf 'read failed\n' >&2
      exit 70
    fi
    send_count="$(wc -l <"${CMUX_FAKE_SEND_LOG:?}" 2>/dev/null | tr -d ' ' || printf '0')"
    key_count="$(wc -l <"${CMUX_FAKE_KEY_LOG:?}" 2>/dev/null | tr -d ' ' || printf '0')"
    printf 'Welcome to Claude Code\n'
    printf 'Opus 4.8 bypass permissions\n'
    wrap_last_payload() {
      tail -n 1 "${CMUX_FAKE_SEND_LOG:?}" | cut -f2- | fold -w "${CMUX_FAKE_WRAP_WIDTH:-42}"
    }
    if [[ "$send_count" -eq 0 ]]; then
      printf '> \n'
    elif [[ "${CMUX_FAKE_NO_GATE_B:-0}" == "1" && "$send_count" -eq 1 && "$key_count" -ge 1 ]]; then
      printf '> \n'
    elif [[ "$send_count" -eq 1 && "$key_count" -ge 1 ]]; then
      printf 'Please describe the task goal and first concrete step.\n'
      printf '> \n'
    elif [[ "$send_count" -ge 2 && "$key_count" -lt 2 && "${CMUX_FAKE_WRAP_BRIEF:-0}" == "1" ]]; then
      wrap_last_payload
      printf '\n> \n'
    elif [[ "$send_count" -ge 2 && "$key_count" -ge 2 && "${CMUX_FAKE_ECHO_ONLY_AFTER_BRIEF:-0}" == "1" ]]; then
      wrap_last_payload
      printf '\n> \n'
    elif [[ "$send_count" -ge 2 && "$key_count" -ge 2 ]]; then
      printf '%s\n' "${CMUX_FAKE_COMMIT_LINE:-commit-progress.sh: create committed abc123; push_exit=0}"
      printf '> \n'
    else
      tail -n 1 "${CMUX_FAKE_SEND_LOG:?}" | cut -f2-
    fi
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
    if [[ "${CMUX_FAKE_READ_FAIL_AFTER_START:-0}" == "1" ]] \
      && grep -Fq '/start display' "${CMUX_FAKE_SEND_LOG:?}" \
      && ! grep -Fq 'Project creation brief' "${CMUX_FAKE_SEND_LOG:?}"; then
      touch "${CMUX_FAKE_FAIL_AFTER_START_MARKER:?}"
    fi
    if grep -Fq 'Project creation brief' "${CMUX_FAKE_SEND_LOG:?}"; then
      case "${CMUX_FAKE_PROGRESS_UPDATE_MODE:-changed-commit}" in
        changed-commit)
          cat >"${CMUX_FAKE_PROGRESS_ROOT:?}/progress__display.md" <<'MD'
# Project: display
**Schema**: progress/v2
**Last updated**: 2026-06-15 12:00
**Status**: Active
**Plane**: *(none yet)*
**Task State**: *(none yet)*
**Plan File**: *(none yet)*

## Resume Card
display - Build a display flow.
NEXT: Create the first UI slice.

## START HERE
Create the first UI slice.
MD
          "${CMUX_FAKE_COMMIT_PROGRESS:?}" update display >/dev/null
          ;;
        changed-no-commit)
          printf '# Project: display\nchanged without commit\n' >"${CMUX_FAKE_PROGRESS_ROOT:?}/progress__display.md"
          ;;
        unchanged)
          :
          ;;
        *)
          printf 'unexpected progress update mode: %s\n' "$CMUX_FAKE_PROGRESS_UPDATE_MODE" >&2
          exit 64
          ;;
      esac
    fi
    ;;
  focus-pane|refresh-surfaces)
    printf 'OK\n'
    ;;
  list-windows)
    printf '* 0: window:1 [selected]\n'
    ;;
  *)
    printf 'unexpected command: %s\n' "$cmd" >&2
    exit 64
    ;;
esac
SH
chmod +x "$fake_cmux"

export CMUX_FAKE_PROGRESS_REPO="$fake_repo"
export CMUX_FAKE_COMMIT_PROGRESS="$fake_commit_progress"
export CMUX_PROJECT_LAUNCHER_COMMIT_PROGRESS="$fake_commit_progress"
export CMUX_PROJECT_LAUNCHER_PROGRESS_REPO="$fake_repo"

CMUX_PROJECT_LAUNCHER_CLAUDE="$fake_claude" \
CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
  $create_bash "$repo_root/bin/cmux-project-create" --mode draft --project display --brief-file "$brief_file" --draft-file "$draft_file" >"$stdout_log"

grep -Fq '"description": "Build a display flow."' "$draft_file"
grep -Fq 'Drafted display' "$stdout_log"

mkdir -p "$fake_progress/archive"
printf '# archived\n' >"$fake_progress/archive/progress__archived.md"
if CMUX_PROJECT_LAUNCHER_CLAUDE="$fake_claude" \
  CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
    $create_bash "$repo_root/bin/cmux-project-create" --mode draft --project archived --brief-file "$brief_file" --draft-file "$tmp_dir/archived.json" >"$stdout_log" 2>"$stderr_log"; then
  printf 'archive duplicate draft unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq 'progress archive' "$stderr_log"

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$close_log"
rm -f "$fake_progress/progress__display.md"
CMUX_FAKE_SEND_LOG="$send_log" \
CMUX_FAKE_KEY_LOG="$key_log" \
CMUX_FAKE_CREATE_LOG="$create_log" \
CMUX_FAKE_CLOSE_LOG="$close_log" \
CMUX_FAKE_PROGRESS_ROOT="$fake_progress" \
CMUX_FAKE_AMQ_ROOT="$tmp_dir/amq-root" \
CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
CMUX_PROJECT_LAUNCHER_POLL=1 \
  $create_bash "$repo_root/bin/cmux-project-create" --mode create --project display --brief-file "$brief_file" >"$stdout_log"

grep -Fq 'Created display via /start' "$stdout_log"
grep -Fq '/start display' "$send_log"
grep -Fq 'Project creation brief' "$send_log"
[[ "$(awk -F '\t' 'NR == 1 { print $2 }' "$send_log")" == "/start display" ]]
[[ "$(awk -F '\t' 'NR == 2 { print $2 }' "$send_log")" == Project\ creation\ brief* ]]
# shellcheck disable=SC2016
if grep -Fq '$start display' "$send_log"; then
  printf 'Codex start prompt was unexpectedly sent during create mode\n' >&2
  exit 1
fi
[[ -f "$fake_progress/progress__display.md" ]]
[[ ! -s "$close_log" ]]
grep -Fq '"direction":"horizontal"' "$create_log"
grep -Fq '"name":"Codex"' "$create_log"
grep -Fq '"name":"Claude"' "$create_log"
[[ "$(cut -f1 "$create_log")" == "display" ]]
grep -Fq 'coopcodex display' "$create_log"
grep -Fq 'coopcc display' "$create_log"
grep -Fq 'using AMQ session display' "$stdout_log"
if grep -Fq 'cml-display-create' "$create_log"; then
  printf 'create leaked the internal helper prefix into the persistent workspace\n' >&2
  exit 1
fi

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$close_log"
rm -f "$fake_progress/progress__display.md"
CMUX_FAKE_AMQ_WHO_JSON='[{"name":"display","agents":[{"active":true}]}]' \
CMUX_FAKE_EXPECT_SESSION=display-2 \
CMUX_FAKE_SEND_LOG="$send_log" \
CMUX_FAKE_KEY_LOG="$key_log" \
CMUX_FAKE_CREATE_LOG="$create_log" \
CMUX_FAKE_CLOSE_LOG="$close_log" \
CMUX_FAKE_PROGRESS_ROOT="$fake_progress" \
CMUX_FAKE_AMQ_ROOT="$tmp_dir/amq-root" \
CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
CMUX_PROJECT_LAUNCHER_POLL=1 \
  $create_bash "$repo_root/bin/cmux-project-create" --mode create --project display --brief-file "$brief_file" >"$stdout_log"

[[ "$(cut -f1 "$create_log")" == "display-2" ]]
grep -Fq 'coopcodex display-2' "$create_log"
grep -Fq 'coopcc display-2' "$create_log"
grep -Fq 'using AMQ session display-2' "$stdout_log"
[[ ! -s "$close_log" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$close_log"
rm -f "$fake_progress/progress__display.md"
PATH=/usr/bin:/bin:/usr/sbin:/sbin \
CMUX_PROJECT_LAUNCHER_DRY_RUN=1 \
CMUX_PROJECT_LAUNCHER_AMQ_PATH_HINTS="$fallback_amq_dir" \
CMUX_FAKE_AMQ_ROOT="$tmp_dir/amq-root" \
CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
CMUX_PROJECT_LAUNCHER_POLL=1 \
  $create_bash "$repo_root/bin/cmux-project-create" --mode create --project display --brief-file "$brief_file" >"$stdout_log" 2>"$stderr_log"

grep -Fq 'cmux workspace create' "$stdout_log"
grep -Fq 'coopcodex' "$stdout_log"
grep -Fq 'coopcc' "$stdout_log"
grep -Fq -- '--name display' "$stdout_log"
if grep -Fq 'cml-display-create' "$stdout_log"; then
  printf 'dry-run leaked the internal helper prefix\n' >&2
  exit 1
fi
grep -Fq 'Codex boot regex:' "$stdout_log"
grep -Fq 'Claude boot regex:' "$stdout_log"
grep -Fq 'Gate B regex:' "$stdout_log"
if grep -Fq 'Could not resolve AMQ base root' "$stderr_log"; then
  printf 'dry-run unexpectedly failed to resolve AMQ base root\n' >&2
  exit 1
fi
[[ ! -f "$fake_progress/progress__display.md" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$close_log"
rm -f "$fake_progress/progress__display.md"
CMUX_FAKE_PUSH_FAIL_ACTION=create \
CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_FAKE_PROGRESS_ROOT="$fake_progress" \
  CMUX_FAKE_AMQ_ROOT="$tmp_dir/amq-root" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
    $create_bash "$repo_root/bin/cmux-project-create" --mode create --project display --brief-file "$brief_file" >"$stdout_log" 2>"$stderr_log"

grep -Fq 'Created display via /start' "$stdout_log"
grep -Fq 'Warning: initial scaffold push failed or is pending' "$stderr_log"
grep -Fq 'Project creation brief' "$send_log"
[[ -f "$fake_progress/progress__display.md" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$close_log"
rm -f "$fake_progress/progress__display.md"
rm -f "$tmp_dir/fail-after-start"
if CMUX_FAKE_READ_FAIL_AFTER_START=1 \
  CMUX_FAKE_FAIL_AFTER_START_MARKER="$tmp_dir/fail-after-start" \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_FAKE_PROGRESS_ROOT="$fake_progress" \
  CMUX_FAKE_AMQ_ROOT="$tmp_dir/amq-root" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
    $create_bash "$repo_root/bin/cmux-project-create" --mode create --project display --brief-file "$brief_file" >"$stdout_log" 2>"$stderr_log"; then
  printf 'gate-b read failure unexpectedly succeeded\n' >&2
  exit 1
fi

if ! grep -Fq 'Could not confirm Claude submitted /start display' "$stderr_log"; then
  cat "$stderr_log" >&2
  exit 1
fi
grep -Fq '/start display' "$send_log"
if grep -Fq 'Project creation brief' "$send_log"; then
  printf 'brief was unexpectedly sent after read failure\n' >&2
  exit 1
fi

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$close_log"
rm -f "$fake_progress/progress__display.md"
CMUX_FAKE_WRAP_BRIEF=1 \
CMUX_FAKE_SEND_LOG="$send_log" \
CMUX_FAKE_KEY_LOG="$key_log" \
CMUX_FAKE_CREATE_LOG="$create_log" \
CMUX_FAKE_CLOSE_LOG="$close_log" \
CMUX_FAKE_PROGRESS_ROOT="$fake_progress" \
CMUX_FAKE_AMQ_ROOT="$tmp_dir/amq-root" \
CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
CMUX_PROJECT_LAUNCHER_POLL=1 \
  $create_bash "$repo_root/bin/cmux-project-create" --mode create --project display --brief-file "$brief_file" >"$stdout_log"

grep -Fq 'Created display via /start' "$stdout_log"
grep -Fq 'Project creation brief' "$send_log"
[[ -f "$fake_progress/progress__display.md" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$close_log"
rm -f "$fake_progress/progress__display.md"
if CMUX_FAKE_ECHO_ONLY_AFTER_BRIEF=1 \
  CMUX_FAKE_WRAP_BRIEF=1 \
  CMUX_FAKE_PROGRESS_UPDATE_MODE=unchanged \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_FAKE_PROGRESS_ROOT="$fake_progress" \
  CMUX_FAKE_AMQ_ROOT="$tmp_dir/amq-root" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
    $create_bash "$repo_root/bin/cmux-project-create" --mode create --project display --brief-file "$brief_file" >"$stdout_log" 2>"$stderr_log"; then
  printf 'unchanged-scaffold create unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'progress file did not change from the scaffold' "$stderr_log"
grep -Fq 'recoverable existing project' "$stderr_log"
grep -Fq 'Project creation brief' "$send_log"
[[ -f "$fake_progress/progress__display.md" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$close_log"
rm -f "$fake_progress/progress__display.md"
if CMUX_FAKE_PROGRESS_UPDATE_MODE=changed-no-commit \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_FAKE_PROGRESS_ROOT="$fake_progress" \
  CMUX_FAKE_AMQ_ROOT="$tmp_dir/amq-root" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
    $create_bash "$repo_root/bin/cmux-project-create" --mode create --project display --brief-file "$brief_file" >"$stdout_log" 2>"$stderr_log"; then
  printf 'changed-without-commit create unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'progress file did not change from the scaffold with a new local update commit' "$stderr_log"
grep -Fq 'changed from the scaffold, but no local post-brief update commit was observed' "$stderr_log"
grep -Fq 'Project creation brief' "$send_log"
[[ -f "$fake_progress/progress__display.md" ]]

git -C "$fake_repo" reset --hard -q
printf '# Project: display\nstale update %s\n' "$RANDOM" >"$fake_progress/progress__display.md"
git -C "$fake_repo" add -A -- project-git/progress/progress__display.md
git -C "$fake_repo" commit -q -m "progress: update display" -- project-git/progress/progress__display.md
rm -f "$fake_progress/progress__display.md"
git -C "$fake_repo" add -A -- project-git/progress/progress__display.md
git -C "$fake_repo" commit -q -m "test: remove display before retry" -- project-git/progress/progress__display.md
git -C "$fake_repo" log --format=%s --all | awk '
  $0 == "progress: update display" { found = 1 }
  END { exit found ? 0 : 1 }
'

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$close_log"
if CMUX_FAKE_PROGRESS_UPDATE_MODE=unchanged \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_FAKE_PROGRESS_ROOT="$fake_progress" \
  CMUX_FAKE_AMQ_ROOT="$tmp_dir/amq-root" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
    $create_bash "$repo_root/bin/cmux-project-create" --mode create --project display --brief-file "$brief_file" >"$stdout_log" 2>"$stderr_log"; then
  printf 'stale-update-commit create unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'progress file did not change from the scaffold' "$stderr_log"
grep -Fq 'Project creation brief' "$send_log"
[[ -f "$fake_progress/progress__display.md" ]]

: >"$send_log"
: >"$key_log"
: >"$create_log"
: >"$close_log"
rm -f "$fake_progress/progress__display.md"
if CMUX_FAKE_NO_GATE_B=1 \
  CMUX_FAKE_SEND_LOG="$send_log" \
  CMUX_FAKE_KEY_LOG="$key_log" \
  CMUX_FAKE_CREATE_LOG="$create_log" \
  CMUX_FAKE_CLOSE_LOG="$close_log" \
  CMUX_FAKE_PROGRESS_ROOT="$fake_progress" \
  CMUX_FAKE_AMQ_ROOT="$tmp_dir/amq-root" \
  CMUX_PROJECT_LAUNCHER_CMUX="$fake_cmux" \
  CMUX_PROJECT_LAUNCHER_AMQ="$fake_amq" \
  CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
  CMUX_PROJECT_LAUNCHER_POLL=1 \
    $create_bash "$repo_root/bin/cmux-project-create" --mode create --project display --brief-file "$brief_file" >"$stdout_log" 2>"$stderr_log"; then
  printf 'gate-b timeout unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'did not reach the project detail prompt' "$stderr_log"
grep -Fq '/start display' "$send_log"
if grep -Fq 'Project creation brief' "$send_log"; then
  printf 'brief was unexpectedly sent before gate B\n' >&2
  exit 1
fi

rm -f "$draft_file" "$tmp_dir/invalid-draft.json" "$fake_progress/progress__display.md"
if CMUX_FAKE_CLAUDE_MODE=invalid \
  CMUX_PROJECT_LAUNCHER_CLAUDE="$fake_claude" \
  CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT="$fake_progress" \
    $create_bash "$repo_root/bin/cmux-project-create" --mode draft --project display --brief-file "$brief_file" --draft-file "$tmp_dir/invalid-draft.json" >"$stdout_log" 2>"$stderr_log"; then
  printf 'invalid draft unexpectedly succeeded\n' >&2
  exit 1
fi

grep -Fq 'did not contain a JSON object' "$stderr_log"
[[ ! -f "$tmp_dir/invalid-draft.json" ]]

printf 'ok - cmux project create shell fixtures passed\n'
