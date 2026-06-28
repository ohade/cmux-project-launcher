#!/usr/bin/env bash
set -euo pipefail

# Regression guard for the GUI launch failure where the .app crashed with
#   line 211: mapfile: command not found
#   Error: not_found: Workspace not found
#
# Root cause: the launcher scripts used `mapfile` (a bash 4+ builtin). The Swift
# app runs the scripts via their `#!/usr/bin/env bash` shebang, and a GUI-launched
# .app inherits a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) that resolves
# `bash` to the macOS system /bin/bash (3.2.57), which has no `mapfile`. The
# developer-shell test runs never caught it because Homebrew bash 5 is first on PATH.
#
# This test enforces three layers:
#   A. Static guard  — no bash-4+ builtin/construct may reappear in bin/.
#   B. Full suite under bash 3.2 — re-run both shell fixtures with the
#      scripts-under-test forced through the oldest available bash.
#   C. GUI-PATH reproduction — run the launch fixture with the GUI's minimal PATH
#      so the shebang resolves to /bin/bash exactly as the .app does.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
launch_fixture="$repo_root/Tests/CmuxProjectLauncherShellTests/test-cmux-project-launch.sh"
create_fixture="$repo_root/Tests/CmuxProjectLauncherShellTests/test-cmux-project-create.sh"
gui_path="/usr/bin:/bin:/usr/sbin:/sbin"
fail=0

# ---------------------------------------------------------------------------
# A. Static guard: reject bash-4+ features in the launcher scripts.
#    Matching is command-position aware so the explanatory comments that mention
#    `mapfile`/`readarray` by name do not trip the guard.
# ---------------------------------------------------------------------------
scripts=(
  "bin/cmux-project-launch"
  "bin/cmux-project-create"
  "bin/lib/cmux-project-common.sh"
)
check_pattern() {
  local label="$1" regex="$2" script
  for script in "${scripts[@]}"; do
    if grep -nE "$regex" "$repo_root/$script" >/dev/null 2>&1; then
      printf 'FAIL(static guard): %s in %s\n' "$label" "$script" >&2
      grep -nE "$regex" "$repo_root/$script" >&2
      fail=1
    fi
  done
}
# `mapfile`/`readarray`/`coproc` invoked as a command (start of statement, or
# after a pipe / && / || / ; / `do` / `then` / `else` / `(`), never inside a comment.
check_pattern "mapfile/readarray/coproc builtin" \
  '(^[[:space:]]*|[|&;(]|[[:space:]](do|then|else)[[:space:]])[[:space:]]*(mapfile|readarray|coproc)([[:space:]]|$)'
# Negative array subscript (bash 4.3+), e.g. ${arr[-1]}.
check_pattern "negative array subscript" '\[[[:space:]]*-[0-9]+[[:space:]]*\]'
# Associative arrays / namerefs (bash 4+/4.3+).
check_pattern "declare/local -A or -n" '(declare|local)[[:space:]]+-[A-Za-z]*[An]'
# In-expansion case conversion ${v^^} / ${v,,} (bash 4+).
check_pattern "case-conversion expansion" '\$\{[A-Za-z_][A-Za-z0-9_]*[],[]*[\^,]'

if [[ "$fail" -eq 0 ]]; then
  printf 'ok - static guard: no bash-4+ constructs in launcher scripts\n'
fi

# ---------------------------------------------------------------------------
# B. Find the oldest available bash (< 4) and re-run the full fixtures under it.
# ---------------------------------------------------------------------------
old_bash=""
for cand in /bin/bash /usr/bin/bash /usr/local/bin/bash; do
  [[ -x "$cand" ]] || continue
  # shellcheck disable=SC2016  # ${BASH_VERSINFO} must expand in the candidate shell, not this one
  major="$("$cand" -c 'printf "%s" "${BASH_VERSINFO[0]:-0}"' 2>/dev/null || printf '0')"
  if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 1 && major < 4 )); then
    old_bash="$cand"
    break
  fi
done

run_fixture() {
  local label="$1" fixture="$2"
  shift 2
  local log
  log="$(mktemp)"
  if env "$@" "$fixture" >"$log" 2>&1; then
    printf 'ok - %s\n' "$label"
  else
    printf 'FAIL: %s (exit %s)\n' "$label" "$?" >&2
    tail -n 20 "$log" >&2
    fail=1
  fi
  if grep -q 'command not found' "$log"; then
    printf 'FAIL: %s leaked "command not found"\n' "$label" >&2
    grep -n 'command not found' "$log" >&2
    fail=1
  fi
  rm -f "$log"
}

if [[ -z "$old_bash" ]]; then
  printf 'SKIP - no bash < 4 found on this host; static guard still enforced\n' >&2
else
  printf '# using old bash: %s (%s)\n' "$old_bash" "$("$old_bash" --version | head -n 1)"
  run_fixture "launch fixture, scripts under $old_bash" "$launch_fixture" "CMUX_TEST_SCRIPT_BASH=$old_bash"
  run_fixture "create fixture, scripts under $old_bash" "$create_fixture" "CMUX_TEST_SCRIPT_BASH=$old_bash"

  # ---------------------------------------------------------------------------
  # C. GUI-PATH reproduction: minimal PATH so the script's own shebang resolves
  #    `bash` to the system /bin/bash, exactly as a double-clicked .app does.
  #    (Only meaningful when /bin/bash itself is < 4, i.e. macOS.)
  # ---------------------------------------------------------------------------
  # shellcheck disable=SC2016  # ${BASH_VERSINFO} must expand in /bin/bash, not this one
  binbash_major="$(/bin/bash -c 'printf "%s" "${BASH_VERSINFO[0]:-0}"' 2>/dev/null || printf '0')"
  if [[ "$binbash_major" =~ ^[0-9]+$ ]] && (( binbash_major < 4 )); then
    run_fixture "launch fixture via shebang under GUI minimal PATH" "$launch_fixture" "PATH=$gui_path"
  else
    printf 'SKIP - /bin/bash is %s (>=4); GUI-PATH repro only applies on macOS bash 3.2\n' "$binbash_major" >&2
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  printf 'FAILED - bash 3.2 compatibility regressions detected\n' >&2
  exit 1
fi
printf 'ok - cmux launcher bash 3.2 compatibility fixtures passed\n'
