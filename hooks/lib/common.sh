#!/usr/bin/env bash
# Shared helpers for pursue's lifecycle hooks (EP-0001).
#
# Sourced by hooks/*.sh.  Two rules for everything in here:
#   1. Never print to stdout.  Stdout is the hook's JSON result channel;
#      a stray line corrupts it.  Diagnostics go to stderr.
#      (The pursue_* accessors below are the exception: they print their
#      return value and are always consumed via command substitution.)
#   2. Fail open.  A hook that cannot do its job emits {} and exits 0.
#      Breaking the operator's session is worse than skipping injection.

# How many trailing progress.md entries to inject.
PURSUE_PROGRESS_TAIL="${PURSUE_PROGRESS_TAIL:-3}"

# ---------------------------------------------------------------------------
# State discovery
# ---------------------------------------------------------------------------

# Walk up from $1 looking for .agent/goals/active.  Prints the project root.
# Returns 1 if no pursuit state is found before reaching /.
pursue_project_root() {
  local dir="${1:-$PWD}"
  dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1
  while :; do
    [[ -f "$dir/.agent/goals/active" ]] && { printf '%s\n' "$dir"; return 0; }
    [[ "$dir" == "/" ]] && return 1
    dir="$(dirname "$dir")"
  done
}

# Print the active pursuit's slug.  Returns 1 if absent or empty (an empty
# `active` file is the documented "no active pursuit" state).
pursue_active_slug() {
  local slug
  slug="$(tr -d '[:space:]' < "$1/.agent/goals/active" 2>/dev/null)" || return 1
  [[ -n "$slug" ]] || return 1
  printf '%s\n' "$slug"
}

# Print the active pursuit's state directory.  Returns 1 if it is missing.
pursue_goal_dir() {
  local slug dir
  slug="$(pursue_active_slug "$1")" || return 1
  dir="$1/.agent/goals/$slug"
  [[ -d "$dir" ]] || return 1
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# Anchor (EP-0001 "The anchor")
# ---------------------------------------------------------------------------

# Print a scalar field from plan.json, or 0 when absent/unreadable.
pursue_plan_field() {
  jq -r --arg f "$2" '.[$f] // 0' "$1/plan.json" 2>/dev/null || printf '0\n'
}

# Digest of the working tree: HEAD plus uncommitted changes.  Outside a git
# repo this degrades to a digest of plan.json, which EP-0001 records as a
# known weakening of staleness detection.
pursue_tree_digest() {
  local root="$1" head diff
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    head="$(git -C "$root" rev-parse HEAD 2>/dev/null || printf 'nohead')"
    diff="$(git -C "$root" diff HEAD 2>/dev/null | sha256sum | cut -d' ' -f1)"
    printf '%.12s-%.12s\n' "$head" "$diff"
  else
    diff="$(cat "$root"/.agent/goals/*/plan.json 2>/dev/null | sha256sum | cut -d' ' -f1)"
    printf 'nogit-%.12s\n' "$diff"
  fi
}

# <tree-digest>:<plan-version>:<active-step>:<iteration>
pursue_anchor() {
  printf '%s:%s:%s:%s\n' \
    "$(pursue_tree_digest "$1")" \
    "$(pursue_plan_field "$2" plan_version)" \
    "$(pursue_plan_field "$2" active_step)" \
    "$(pursue_plan_field "$2" iteration)"
}
