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
#
# The -r guard is not redundant with 2>/dev/null: a failed input redirection
# is reported by the shell while setting the redirection up, so it is never
# covered by the redirection of the command's own stderr.  Rule 1 of this
# file is that hooks stay quiet, and a hook that chatters at every session
# start is a hook the operator disables.
pursue_active_slug() {
  local f="$1/.agent/goals/active" slug
  [[ -r "$f" ]] || return 1
  slug="$(tr -d '[:space:]' < "$f" 2>/dev/null)" || return 1
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
    # --verify is load-bearing: plain `rev-parse HEAD` in a repo with no
    # commits prints the literal string "HEAD" to *stdout* and exits 128, so
    # the fallback would append to it rather than replace it and the anchor
    # would render across two lines.  --verify prints nothing on failure.
    head="$(git -C "$root" rev-parse --verify HEAD 2>/dev/null || printf 'nohead')"
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
#
# The context goes in on jq's *stdin*, not its argv.  Linux caps a single
# exec argument at MAX_ARG_STRLEN (128KB) independently of the far larger
# ARG_MAX, so `--arg c "$block"` made exec fail outright once goal.md and
# the progress tail crossed ~126KB — injection stopped, silently.  A byte
# stream has no such limit.  `-Rs` reads it verbatim, producing exactly the
# string `--arg` used to.
pursue_emit_context() {
  printf '%s' "$2" | jq -Rs --arg e "$1" \
    '{hookSpecificOutput: {hookEventName: $e, additionalContext: .}}'
}

# Record that a hook actually ran, and what it managed to do.  This is what
# makes "hooks silently not running" detectable after the fact (EP-0001
# Failure modes) — without it, an unenforced pursuit looks exactly like an
# enforced quiet one.
#
# $3 is the record kind, default "heartbeat" (ran and injected).  Callers
# pass a different kind when the run did something else, so that a
# heartbeat never asserts more than actually happened.
pursue_heartbeat() {
  printf '{"ts":"%s","event":"%s","kind":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "${3:-heartbeat}" \
    >> "$1/triggers.jsonl" 2>/dev/null || true
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
  local event="$1" cwd root goal_dir status result

  pursue_read_payload
  pursue_have_jq || { pursue_emit_noop; return 0; }

  cwd="$(pursue_payload_field cwd)"
  [[ -n "$cwd" ]] || cwd="$PWD"

  root="$(pursue_project_root "$cwd")"     || { pursue_emit_noop; return 0; }
  goal_dir="$(pursue_goal_dir "$root")"    || { pursue_emit_noop; return 0; }

  # Same -r guard as pursue_active_slug, for the same reason: without it a
  # missing STATUS leaks the shell's redirection error to stderr.
  status="unknown"
  [[ -r "$goal_dir/STATUS" ]] &&
    status="$(tr -d '[:space:]' < "$goal_dir/STATUS" 2>/dev/null || printf 'unknown')"

  case "$status" in
    active|paused|awaiting-confirmation) ;;
    *) pursue_emit_noop; return 0 ;;
  esac

  # Emit first, record second, and record which of the two happened.  The
  # heartbeat is the only evidence that enforcement is live; writing it
  # before the emit meant a failed injection still logged a healthy-looking
  # run, which is exactly the "unenforced is indistinguishable from
  # enforced" failure the heartbeat exists to prevent.  Build the result in
  # a variable so a partial write from a failing jq never reaches stdout.
  if result="$(pursue_emit_context "$event" \
                 "$(pursue_context_block "$root" "$goal_dir" "$status" "$event")")" \
     && [[ -n "$result" ]]; then
    printf '%s\n' "$result"
    pursue_heartbeat "$goal_dir" "$event" heartbeat
  else
    pursue_emit_noop
    pursue_heartbeat "$goal_dir" "$event" emit-failed
  fi
  return 0
}
