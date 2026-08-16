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

pursue_detect_main() {
  local cwd root goal_dir status state

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

  state="$(pursue_detect_load "$goal_dir")"
  state="$(pursue_detect_failures "$goal_dir" "$state")"
  state="$(pursue_detect_churn "$goal_dir" "$state" "$root")"
  state="$(pursue_detect_verification "$goal_dir" "$state")"
  pursue_detect_scope "$goal_dir" "$root"
  pursue_detect_save "$goal_dir" "$state"
  return 0
}

pursue_detect_main
# Always the inert result: this hook observes, it does not decide.
printf '{}\n'
exit 0
