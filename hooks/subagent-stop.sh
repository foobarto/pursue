#!/usr/bin/env bash
# pursue SubagentStop hook (EP-0001 §Hook contract).
#
# Captures a reviewer subagent's verdict and binds it to the anchor it
# reviewed.  Observation only: this hook records, it does not act.  Plan 3's
# Stop gate is what reads these verdicts and decides.
#
# Subagents that are not reviewers pass through untouched — the tagged
# fenced block is the only thing that marks a message as a verdict.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$here/lib/common.sh" 2>/dev/null || { printf '{}\n'; exit 0; }
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/detect.sh
. "$here/lib/detect.sh" 2>/dev/null || { printf '{}\n'; exit 0; }
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/verdict.sh
. "$here/lib/verdict.sh" 2>/dev/null || { printf '{}\n'; exit 0; }

pursue_verdict_main() {
  local cwd root goal_dir status message block anchor

  pursue_read_payload
  pursue_have_jq || return 0

  cwd="$(pursue_payload_field cwd)"
  [[ -n "$cwd" ]] || cwd="$PWD"

  root="$(pursue_project_root "$cwd")"  || return 0
  goal_dir="$(pursue_goal_dir "$root")" || return 0

  status="unknown"
  [[ -r "$goal_dir/STATUS" ]] &&
    status="$(tr -d '[:space:]' < "$goal_dir/STATUS" 2>/dev/null || printf 'unknown')"
  [[ "$status" == "active" ]] || return 0

  message="$(pursue_payload_field last_assistant_message)"
  [[ -n "$message" ]] || return 0

  block="$(pursue_verdict_extract "$message")"
  # No tagged block means this subagent was not a reviewer.  Say nothing:
  # a trigger here would fire on every ordinary subagent in the session.
  [[ -n "$block" ]] || return 0

  anchor="$(pursue_anchor "$root" "$goal_dir")"

  if pursue_verdict_validate "$block" && pursue_verdict_write "$goal_dir" "$anchor" "$block"; then
    pursue_detect_trigger "$goal_dir" verdict-recorded \
      "$(jq -cn --arg a "$anchor" \
           --arg v "$(printf '%s' "$block" | jq -r '.verdict')" \
           '{anchor: $a, verdict: $v}')"
  else
    # Discarded, never repaired.  In Plan 3 this leaves the originating
    # trigger unconsumed, so the gate demands another review rather than
    # letting a garbled verdict pass for consent.
    pursue_detect_trigger "$goal_dir" verdict-rejected \
      "$(jq -cn --arg a "$anchor" '{anchor: $a, reason: "failed strict decoding"}')"
  fi
  return 0
}

pursue_verdict_main
printf '{}\n'
exit 0
