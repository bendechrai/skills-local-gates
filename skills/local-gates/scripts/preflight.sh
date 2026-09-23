#!/usr/bin/env bash
#
# preflight.sh - run every Definition-of-Done gate against a clean export
# of a commit, on this machine, with no hosted CI minutes.
#
# The runner is stack-agnostic. Everything that knows what this project is
# lives in bin/preflight.gates.sh, which the runner sources *out of the
# archive* so the gate definitions are the ones belonging to the commit
# under test rather than the ones sitting in your working tree.
#
# Why an archive instead of the working tree: "it passed in my dev
# container" is not evidence that a fresh checkout passes. The container
# carries gitignored state a clone does not (generated type declarations,
# a stale build directory, a node_modules from a lockfile you have since
# changed), and that state is exactly what hides a failure until the
# push. `git archive <commit>` can only contain tracked files at that
# commit, so a gate that passes here passes for whoever clones it next.
#
# Usage:
#   bin/preflight.sh [<commit-ish>] [options]
#
#   <commit-ish>        what to test; defaults to HEAD
#   --skip-smoke        skip the reserved `smoke` gate (see LOCAL_GATES_SKIP_SMOKE)
#   --only <gate>       run one gate by name; repeatable
#   --list              print the gate order for this project and exit
#   -h, --help          this text
#
# Environment:
#   LOCAL_GATES_SKIP_SMOKE=1      same as --skip-smoke, for the pre-push hook
#   LOCAL_GATES_SKIP_SMOKE_REASON free text printed in the waiver line
#   LOCAL_GATES_NO_MARKER=1       run the smoke gate but do not certify the tree
#
# Exit status is 0 only when every gate that ran passed.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# The *common* git dir, not this worktree's: a linked worktree checking out
# the same tree has already been proven by whichever one ran the suite, and
# markers are keyed on content, so they belong to the repository.
GIT_COMMON_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
GATES_FILE="bin/preflight.gates.sh"
MARKER_DIR="$GIT_COMMON_DIR/local-gates-ok"
SMOKE_GATE="smoke"

commit="HEAD"
skip_smoke="${LOCAL_GATES_SKIP_SMOKE:-}"
list_only=""
only_gates=()

# ------------------------------------------------------------------
# Output helpers. Colour only when a terminal is watching, so a log
# captured by the hook or by a scrollback pager stays readable.
# ------------------------------------------------------------------
if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_RST=""
fi

banner() { printf '\n%s==> %s%s\n' "$C_BOLD" "$1" "$C_RST"; }
note()   { printf '    %s%s%s\n' "$C_DIM" "$1" "$C_RST"; }
good()   { printf '%s    ok%s %s\n' "$C_GRN" "$C_RST" "$1"; }
warn()   { printf '%s  warn%s %s\n' "$C_YEL" "$C_RST" "$1"; }
die()    { printf '\n%sPREFLIGHT FAILED%s %s\n' "$C_RED" "$C_RST" "$1" >&2; exit 1; }

usage() {
  sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-smoke) skip_smoke=1 ;;
    --only)
      [ $# -ge 2 ] || die "--only needs a gate name"
      only_gates+=("$2")
      shift
      ;;
    --only=*) only_gates+=("${1#*=}") ;;
    --list) list_only=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) commit="$1" ;;
  esac
  shift
done

git rev-parse --verify --quiet "$commit^{commit}" >/dev/null \
  || die "not a commit: $commit"

COMMIT_SHA="$(git rev-parse "$commit^{commit}")"
TREE_SHA="$(git rev-parse "$commit^{tree}")"
SHORT_SHA="$(git rev-parse --short "$COMMIT_SHA")"

# Every throwaway container a gate starts is named with this prefix so the
# runner can reap the ones a failing gate never got to remove.
PREFLIGHT_ID="local-gates-$$"
PREFLIGHT_NET="$PREFLIGHT_ID-net"
PREFLIGHT_DIR=""
ARCHIVE_DIR=""
net_created=""

cleanup() {
  local status=$?
  if [ -n "$net_created" ] && command -v docker >/dev/null 2>&1; then
    local stragglers
    stragglers="$(docker ps -aq --filter "name=^${PREFLIGHT_ID}" 2>/dev/null || true)"
    if [ -n "$stragglers" ]; then
      # shellcheck disable=SC2086 # deliberate word splitting: one id per arg
      docker rm -f $stragglers >/dev/null 2>&1 || true
    fi
    docker network rm "$PREFLIGHT_NET" >/dev/null 2>&1 || true
  fi
  [ -n "$ARCHIVE_DIR" ] && rm -rf "$ARCHIVE_DIR"
  return $status
}
trap cleanup EXIT

# ------------------------------------------------------------------
# Export the commit
# ------------------------------------------------------------------
ARCHIVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-gates.XXXXXX")"
PREFLIGHT_DIR="$ARCHIVE_DIR"
git -C "$REPO_ROOT" archive "$COMMIT_SHA" | tar -x -C "$ARCHIVE_DIR"

[ -f "$ARCHIVE_DIR/$GATES_FILE" ] \
  || die "$GATES_FILE is not committed at $SHORT_SHA - the gates have to travel with the code they gate"

# ------------------------------------------------------------------
# Load the project's gates. Sourced from the archive, with the archive as
# cwd, so a gates file may read anything the commit contains (a lockfile
# hash, a compose file, its own helper scripts) without caring where the
# repository happens to live.
# ------------------------------------------------------------------
GATES=()
cd "$ARCHIVE_DIR"
# shellcheck source=/dev/null
. "./$GATES_FILE"

[ "${#GATES[@]}" -gt 0 ] || die "$GATES_FILE defined no GATES"

for gate in "${GATES[@]}"; do
  declare -F "$gate" >/dev/null \
    || die "$GATES_FILE lists gate '$gate' but defines no function with that name"
done

if [ -n "$list_only" ]; then
  printf '%s\n' "${GATES[@]}"
  exit 0
fi

if [ "${#only_gates[@]}" -gt 0 ]; then
  for want in "${only_gates[@]}"; do
    found=""
    for gate in "${GATES[@]}"; do
      [ "$gate" = "$want" ] && found=1 && break
    done
    [ -n "$found" ] || die "no such gate: $want (try --list)"
  done
fi

wanted() {
  [ "${#only_gates[@]}" -eq 0 ] && return 0
  local want
  for want in "${only_gates[@]}"; do
    [ "$want" = "$1" ] && return 0
  done
  return 1
}

# ------------------------------------------------------------------
# A network the gates can hang service containers off. Created once per
# run and removed on exit, so a Postgres a test gate needs is reachable
# by name from the container running the tests and from nothing else.
# ------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  docker network create "$PREFLIGHT_NET" >/dev/null 2>&1 && net_created=1 || true
fi

export PREFLIGHT_ID PREFLIGHT_NET PREFLIGHT_DIR
export PREFLIGHT_COMMIT="$COMMIT_SHA" PREFLIGHT_TREE="$TREE_SHA"
# The checkout and the marker directory, for the rare gate that cannot run
# against the archive at all - a browser suite that drives a dev server is
# serving the working tree, not the export. Such a gate has to refuse
# unless the working tree matches the commit, or it certifies code that
# was never exercised.
export PREFLIGHT_REPO="$REPO_ROOT" PREFLIGHT_MARKER_DIR="$MARKER_DIR"

banner "preflight $SHORT_SHA"
note "tree    $TREE_SHA"
note "archive $ARCHIVE_DIR"
note "gates   ${GATES[*]}"

MARKER="$MARKER_DIR/$TREE_SHA"
run_started="$(date +%s)"
smoke_state="not run"
gate_log=()

elapsed() {
  local secs=$(( $(date +%s) - $1 ))
  printf '%dm%02ds' $(( secs / 60 )) $(( secs % 60 ))
}

# One line per gate at the end, printed on the way out whether the run
# passed or failed: "which gate is eating the twelve minutes" is the
# question that decides what to make faster.
summary() {
  local line
  printf '\n%stimings%s\n' "$C_BOLD" "$C_RST"
  for line in ${gate_log[@]+"${gate_log[@]}"}; do
    printf '  %s\n' "${line//|/  }"
  done
  printf '  %-12s  %-9s  %s\n' "TOTAL" "" "$(elapsed "$run_started")"
}

run_gate() {
  local gate="$1" started
  started="$(date +%s)"
  banner "$gate"
  if ( cd "$ARCHIVE_DIR" && "$gate" ); then
    good "$gate passed in $(elapsed "$started")"
    gate_log+=("$(printf '%-12s|%-9s|%s' "$gate" "ok" "$(elapsed "$started")")")
    return 0
  fi
  printf '\n%s    FAILED%s %s after %s\n' "$C_RED" "$C_RST" "$gate" "$(elapsed "$started")" >&2
  gate_log+=("$(printf '%-12s|%-9s|%s' "$gate" "FAILED" "$(elapsed "$started")")")
  return 1
}

# An optional assertion the gates file may define, run once before any
# gate. It is where "this generated file must not be committed" belongs:
# the point of the archive is that it holds only tracked files, and a
# generated file that has been committed silently defeats that.
if declare -F preflight_precheck >/dev/null; then
  banner "precheck"
  ( cd "$ARCHIVE_DIR" && preflight_precheck ) || die "precheck failed"
fi

for gate in "${GATES[@]}"; do
  wanted "$gate" || continue

  if [ "$gate" = "$SMOKE_GATE" ]; then
    # The slow suite is certified per *tree*, not per commit: a rebase, an
    # amended message or a second branch pointing at the same content is
    # the same bytes and has already been proven. The marker lives under
    # .git so it is never committed and never shared - somebody else's
    # machine has to earn its own.
    # The marker is checked before the waiver: a tree that has already
    # been proven is green on the evidence, and reporting a waiver for it
    # would understate what was actually run.
    if [ -f "$MARKER" ]; then
      smoke_state="certified earlier"
      banner "$gate"
      good "tree $TREE_SHA already certified - $MARKER"
      continue
    fi
    if [ -n "$skip_smoke" ]; then
      smoke_state="waived"
      warn "Waived: smoke - ${LOCAL_GATES_SKIP_SMOKE_REASON:-requested with LOCAL_GATES_SKIP_SMOKE}"
      continue
    fi
    run_gate "$gate" || { summary; die "$gate failed - $SHORT_SHA is not safe to push"; }
    if [ -n "${LOCAL_GATES_NO_MARKER:-}" ]; then
      smoke_state="passed (not certified)"
    else
      mkdir -p "$MARKER_DIR"
      printf 'commit %s\nrun     %s\n' "$COMMIT_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
      smoke_state="passed, tree certified"
    fi
    continue
  fi

  run_gate "$gate" || { summary; die "$gate failed - $SHORT_SHA is not safe to push"; }
done

banner "preflight passed"
note "commit  $SHORT_SHA"
note "smoke   $smoke_state"
summary
