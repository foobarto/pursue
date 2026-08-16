#!/usr/bin/env bash
# pursue PostToolUse hook (EP-0001 §Detectors).
#
# Runs after every tool call, derives deterministic warning signals, and
# appends them to triggers.jsonl.  Observation only: this hook never blocks,
# never denies, and never steers.  Plan 3's Stop gate is what consumes what
# this records.
#
# Because it fires on every tool call, the cost of a mistake here is paid
# continuously — hence the hard fail-open rule and the bounded state.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$here/lib/common.sh" 2>/dev/null || { printf '{}\n'; exit 0; }
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/detect.sh
. "$here/lib/detect.sh" 2>/dev/null || { printf '{}\n'; exit 0; }

# The read-modify-write cycle, run under the state lock.  Everything it
# produces is persisted to disk, so it does not need to hand anything back
# to its caller — which is what lets the lock be a plain subshell.
#
# shellcheck disable=SC2317  # reached indirectly, as pursue_detect_locked's callback
pursue_detect_cycle() {
  local goal_dir="$1" root="$2" state

  state="$(pursue_detect_load "$goal_dir")"
  state="$(pursue_detect_failures "$goal_dir" "$state")"
  state="$(pursue_detect_churn "$goal_dir" "$state" "$root")"
  state="$(pursue_detect_verification "$goal_dir" "$state")"
  state="$(pursue_detect_scope "$goal_dir" "$state" "$root")"
  pursue_detect_save "$goal_dir" "$state"
}

pursue_detect_main() {
  local cwd root goal_dir status

  pursue_read_payload
  pursue_have_jq || return 0

  cwd="$(pursue_payload_field cwd)"
  [[ -n "$cwd" ]] || cwd="$PWD"

  root="$(pursue_project_root "$cwd")"  || return 0
  goal_dir="$(pursue_goal_dir "$root")" || return 0

  status="unknown"
  [[ -r "$goal_dir/STATUS" ]] &&
    status="$(tr -d '[:space:]' < "$goal_dir/STATUS" 2>/dev/null || printf 'unknown')"
  # Only an active pursuit is observed.  A paused one is deliberately not
  # accumulating detector history the operator never asked for.
  [[ "$status" == "active" ]] || return 0

  # PostToolUse also fires for tool calls made *inside* a subagent, and the
  # payload carries agent_id when it does.  Those calls are not the worker's
  # work: a read-only reviewer's own failed Reads would land in the worker's
  # counters and could fire triggers about the review rather than the work.
  # Same self-reference class as excluding .agent/ from the scope count, and
  # it gets worse in the next slice, where reviewers run constantly.  So the
  # observation layer observes exactly one actor.
  [[ -z "$(pursue_payload_field agent_id)" ]] || return 0

  pursue_detect_locked "$goal_dir" pursue_detect_cycle "$goal_dir" "$root"
  return 0
}

pursue_detect_main
# Always the inert result: this hook observes, it does not decide.
printf '{}\n'
exit 0
