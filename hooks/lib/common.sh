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

# ---------------------------------------------------------------------------
# Hook payload I/O
#
# Both Claude Code and Codex deliver the same payload shape on stdin and
# read the same result shape from stdout (EP-0001 "Hook contract").
# ---------------------------------------------------------------------------

PURSUE_PAYLOAD="${PURSUE_PAYLOAD:-}"

pursue_have_jq() { command -v jq >/dev/null 2>&1; }

# Slurp the hook payload from stdin exactly once.
pursue_read_payload() { PURSUE_PAYLOAD="$(cat)"; }

# Print a top-level string field from the payload, or nothing.  Malformed
# JSON yields empty rather than an error: hooks fail open.
pursue_payload_field() {
  printf '%s' "$PURSUE_PAYLOAD" \
    | jq -r --arg f "$1" '.[$f] // empty' 2>/dev/null \
    || true
}

# The "we have nothing to say" result.  Valid, inert, always exit 0.
pursue_emit_noop() { printf '{}\n'; }

# Inject context into the model's next turn.  Deliberately emits no
# `decision` and no `continue`: SessionStart/PreCompact are injection-only,
# the gate is a separate hook.
pursue_emit_context() {
  jq -n --arg e "$1" --arg c "$2" \
    '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
}

# Record that a hook actually ran.  This is what makes "hooks silently not
# running" detectable after the fact (EP-0001 Failure modes) — without it,
# an unenforced pursuit looks exactly like an enforced quiet one.
pursue_heartbeat() {
  printf '{"ts":"%s","event":"%s","kind":"heartbeat"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >> "$1/triggers.jsonl" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Context assembly
#
# This is the reduced form of EP-0062's "keep the promises somewhere
# forgetting cannot edit them".  It is the highest-value thing these hooks
# do: it is what makes a pursuit survive a session reset without depending
# on the worker remembering to re-read its own state.
# ---------------------------------------------------------------------------

# Print the last N "## " sections of progress.md.
pursue_progress_tail() {
  local f="$1/progress.md"
  [[ -f "$f" ]] || return 0
  awk -v n="$2" '
    /^## / { c++; start[c] = NR }
    { line[NR] = $0 }
    END {
      from = (c > n) ? start[c - n + 1] : 1
      for (i = from; i <= NR; i++) print line[i]
    }
  ' "$f"
}

# Print the active plan step and its done condition.  Injecting only the
# active step is deliberate: exactly one step is active, and showing the
# whole plan invites the worker to work ahead of it.
pursue_active_step_text() {
  jq -r '
    (.active_step // null) as $i
    | if $i == null or (.steps | length) <= $i then "(no active step)"
      else "[\($i)] \(.steps[$i].title // "(unnamed)")\n    done when: \(.steps[$i].done_when // "(unspecified)")"
      end
  ' "$1/plan.json" 2>/dev/null || printf '(no plan.json)\n'
}

# Assemble the full injected block: contract, anchor, active step,
# blockers, recent progress.
pursue_context_block() {
  local root="$1" goal_dir="$2" status="$3" event="$4"
  printf '# Active pursuit — injected by the pursue %s hook\n\n' "$event"
  printf 'Status: %s\n' "$status"
  printf 'Anchor: %s\n' "$(pursue_anchor "$root" "$goal_dir")"
  printf 'State:  %s\n\n' "$goal_dir"
  printf -- '--- contract (goal.md) ---\n'
  cat "$goal_dir/goal.md" 2>/dev/null
  printf -- '\n--- active plan step ---\n'
  pursue_active_step_text "$goal_dir"
  if [[ -s "$goal_dir/blockers.md" ]]; then
    printf -- '\n--- open blockers ---\n'
    cat "$goal_dir/blockers.md"
  fi
  printf -- '\n--- last %s progress entries ---\n' "$PURSUE_PROGRESS_TAIL"
  pursue_progress_tail "$goal_dir" "$PURSUE_PROGRESS_TAIL"
}

# Shared entrypoint body for the injection hooks.  Both SessionStart and
# PreCompact do exactly this; only the event name differs.
pursue_inject_main() {
  local event="$1" cwd root goal_dir status

  pursue_read_payload
  pursue_have_jq || { pursue_emit_noop; return 0; }

  cwd="$(pursue_payload_field cwd)"
  [[ -n "$cwd" ]] || cwd="$PWD"

  root="$(pursue_project_root "$cwd")"     || { pursue_emit_noop; return 0; }
  goal_dir="$(pursue_goal_dir "$root")"    || { pursue_emit_noop; return 0; }

  status="$(tr -d '[:space:]' < "$goal_dir/STATUS" 2>/dev/null || printf 'unknown')"
  case "$status" in
    active|paused|awaiting-confirmation) ;;
    *) pursue_emit_noop; return 0 ;;
  esac

  pursue_heartbeat "$goal_dir" "$event"
  pursue_emit_context "$event" "$(pursue_context_block "$root" "$goal_dir" "$status" "$event")"
}
