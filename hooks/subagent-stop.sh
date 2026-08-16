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

# One heartbeat per session, under the same lock the detectors use — this
# hook shares detect-state.json with PostToolUse, and several subagents can
# finish at once.
#
# shellcheck disable=SC2317  # reached indirectly, as pursue_detect_locked's callback
pursue_verdict_beat() {
  local goal_dir="$1" session="$2" state
  state="$(pursue_detect_load "$goal_dir")"
  state="$(pursue_detect_session_heartbeat "$goal_dir" "$state" SubagentStop "$session")"
  pursue_detect_save "$goal_dir" "$state"
}

pursue_verdict_main() {
  local cwd root goal_dir status message block anchor agent rc

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

  # Before the early returns below, not after: EP-0001 Failure modes wants
  # every hook to leave evidence it ran, and "an active pursuit whose
  # subagents are never reviewers" is exactly the case where this hook is
  # correct to stay quiet and still needs to be distinguishable from a hook
  # that was never registered.
  pursue_detect_locked "$goal_dir" \
    pursue_verdict_beat "$goal_dir" "$(pursue_payload_field session_id)"

  message="$(pursue_payload_field last_assistant_message)"
  [[ -n "$message" ]] || return 0

  block="$(pursue_verdict_extract "$message")"
  # No tagged block means this subagent was not a reviewer.  Say nothing:
  # a trigger here would fire on every ordinary subagent in the session.
  [[ -n "$block" ]] || return 0

  anchor="$(pursue_anchor "$root" "$goal_dir")"
  agent="$(pursue_payload_field agent_id)"

  # Discarded, never repaired.  In Plan 3 a rejection leaves the originating
  # trigger unconsumed, so the gate demands another review rather than
  # letting a garbled — or downgraded — verdict pass for consent.
  if ! pursue_verdict_validate "$block"; then
    pursue_detect_trigger "$goal_dir" verdict-rejected \
      "$(jq -cn --arg a "$anchor" '{anchor: $a, reason: "failed strict decoding"}')"
    return 0
  fi

  pursue_verdict_write "$goal_dir" "$anchor" "$block" "$agent"; rc=$?
  case "$rc" in
    0)
      pursue_detect_trigger "$goal_dir" verdict-recorded \
        "$(jq -cn --arg a "$anchor" --arg g "$agent" \
             --arg v "$(printf '%s' "$block" | jq -r '.verdict')" \
             '{anchor: $a, verdict: $v} + (if $g == "" then {} else {agent_id: $g} end)')"
      ;;
    2)
      pursue_detect_trigger "$goal_dir" verdict-rejected \
        "$(jq -cn --arg a "$anchor" \
             '{anchor: $a, reason: "a pause or stop is already recorded at this anchor"}')"
      ;;
    *)
      pursue_detect_trigger "$goal_dir" verdict-rejected \
        "$(jq -cn --arg a "$anchor" '{anchor: $a, reason: "could not be written"}')"
      ;;
  esac
  return 0
}

pursue_verdict_main
printf '{}\n'
exit 0
