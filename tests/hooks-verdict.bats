#!/usr/bin/env bats
# Verdict decoding, anchoring, and stale classification.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  PROJ="$TMP/proj"
  SLUG="2026-08-16-demo"
  GOAL_DIR="$PROJ/.agent/goals/$SLUG"
  mkdir -p "$GOAL_DIR"
  printf '%s\n' "$SLUG" > "$PROJ/.agent/goals/active"
  printf 'active\n' > "$GOAL_DIR/STATUS"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/hooks/lib/common.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/hooks/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/hooks/lib/verdict.sh"
}

teardown() { rm -rf "$TMP"; }

msg_with() {
  printf 'Here is my review.\n\n```pursue-verdict\n%s\n```\n\nThanks.\n' "$1"
}

@test "pursue_anchor_slug makes an anchor filename-safe" {
  run pursue_anchor_slug 'abc123-def456:2:1:7'
  [ "$status" -eq 0 ]
  [[ "$output" != *:* ]]
  [[ "$output" == *abc123* ]]
}

@test "pursue_anchor_slug is injective for different anchors" {
  a="$(pursue_anchor_slug 'aaa-bbb:1:0:1')"
  b="$(pursue_anchor_slug 'aaa-bbb:1:0:2')"
  [ "$a" != "$b" ]
}

@test "pursue_verdict_extract pulls the tagged block" {
  run pursue_verdict_extract "$(msg_with '{"verdict":"continue","reason":"looks fine"}')"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verdict == "continue"'
}

@test "pursue_verdict_extract ignores an untagged JSON block" {
  text="$(printf 'Result:\n\n```json\n{"verdict":"approve","reason":"x"}\n```\n')"
  run pursue_verdict_extract "$text"
  [ "$output" = "" ]
}

@test "pursue_verdict_extract is empty when there is no block" {
  run pursue_verdict_extract "I reviewed it and it seems fine."
  [ "$output" = "" ]
}

@test "pursue_verdict_validate accepts each allowed verdict" {
  for v in continue correct pause stop approve; do
    run pursue_verdict_validate "{\"verdict\":\"$v\",\"reason\":\"because\"}"
    [ "$status" -eq 0 ]
  done
}

@test "pursue_verdict_validate rejects an unknown verdict" {
  run pursue_verdict_validate '{"verdict":"maybe","reason":"x"}'
  [ "$status" -ne 0 ]
}

@test "pursue_verdict_validate rejects a missing reason" {
  run pursue_verdict_validate '{"verdict":"stop"}'
  [ "$status" -ne 0 ]
}

@test "pursue_verdict_validate rejects an empty reason" {
  run pursue_verdict_validate '{"verdict":"stop","reason":"  "}'
  [ "$status" -ne 0 ]
}

@test "pursue_verdict_validate rejects malformed JSON" {
  run pursue_verdict_validate 'not json'
  [ "$status" -ne 0 ]
}

@test "pursue_verdict_write stores the verdict under its anchor with the anchor inside" {
  pursue_verdict_write "$GOAL_DIR" 'aaa-bbb:1:0:3' '{"verdict":"correct","reason":"stop retrying npm"}'
  slug="$(pursue_anchor_slug 'aaa-bbb:1:0:3')"
  [ -f "$GOAL_DIR/verdicts/$slug.json" ]
  run jq -r '.anchor' "$GOAL_DIR/verdicts/$slug.json"
  [ "$output" = "aaa-bbb:1:0:3" ]
  run jq -r '.verdict' "$GOAL_DIR/verdicts/$slug.json"
  [ "$output" = "correct" ]
}

@test "pursue_verdict_classify calls a matching anchor current" {
  run pursue_verdict_classify '{"verdict":"continue","anchor":"a:1:0:1"}' 'a:1:0:1'
  [ "$output" = "current" ]
}

@test "stale continue and approve are discarded" {
  for v in continue approve; do
    run pursue_verdict_classify "{\"verdict\":\"$v\",\"anchor\":\"old:1:0:1\"}" 'new:1:0:2'
    [ "$output" = "stale-discard" ]
  done
}

@test "stale correct becomes advisory steering" {
  run pursue_verdict_classify '{"verdict":"correct","anchor":"old:1:0:1"}' 'new:1:0:2'
  [ "$output" = "stale-advisory" ]
}

@test "stale pause and stop demand a fresh review" {
  for v in pause stop; do
    run pursue_verdict_classify "{\"verdict\":\"$v\",\"anchor\":\"old:1:0:1\"}" 'new:1:0:2'
    [ "$output" = "stale-confirm" ]
  done
}

@test "subagent-stop records a valid verdict at the current anchor" {
  anchor="$(pursue_anchor "$PROJ" "$GOAL_DIR")"
  payload="$(jq -cn --arg c "$PROJ" --arg m "$(msg_with '{"verdict":"correct","reason":"change tactics"}')" \
    '{session_id:"s1", cwd:$c, hook_event_name:"SubagentStop", last_assistant_message:$m, stop_hook_active:false}')"
  run bash -c "printf '%s' '$payload' | '$REPO_ROOT/hooks/subagent-stop.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  slug="$(pursue_anchor_slug "$anchor")"
  [ -f "$GOAL_DIR/verdicts/$slug.json" ]
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl'"
  [ "$output" = "verdict-recorded" ]
}

@test "subagent-stop discards a malformed verdict and says so" {
  payload="$(jq -cn --arg c "$PROJ" --arg m "$(msg_with '{"verdict":"maybe","reason":"x"}')" \
    '{cwd:$c, hook_event_name:"SubagentStop", last_assistant_message:$m}')"
  run bash -c "printf '%s' '$payload' | '$REPO_ROOT/hooks/subagent-stop.sh'"
  [ "$status" -eq 0 ]
  [ ! -d "$GOAL_DIR/verdicts" ] || {
    run bash -c "ls '$GOAL_DIR/verdicts' | wc -l"; [ "$output" = "0" ]
  }
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl'"
  [ "$output" = "verdict-rejected" ]
}

@test "subagent-stop ignores a subagent that emitted no verdict block" {
  payload="$(jq -cn --arg c "$PROJ" '{cwd:$c, hook_event_name:"SubagentStop", last_assistant_message:"I finished the search."}')"
  run bash -c "printf '%s' '$payload' | '$REPO_ROOT/hooks/subagent-stop.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  # The heartbeat is the only line it is allowed to write here.
  run bash -c "jq -r 'select(.kind!=\"session-heartbeat\") | .kind' '$GOAL_DIR/triggers.jsonl' | wc -l"
  [ "$output" = "0" ]
  [ ! -d "$GOAL_DIR/verdicts" ]
}

@test "subagent-stop never emits decision or continue" {
  payload="$(jq -cn --arg c "$PROJ" --arg m "$(msg_with '{"verdict":"stop","reason":"unsafe"}')" \
    '{cwd:$c, hook_event_name:"SubagentStop", last_assistant_message:$m}')"
  run bash -c "printf '%s' '$payload' | '$REPO_ROOT/hooks/subagent-stop.sh'"
  echo "$output" | jq -e 'has("decision") | not'
  echo "$output" | jq -e 'has("continue") | not'
}

@test "subagent-stop survives a malformed payload" {
  run bash -c "printf 'garbage' | '$REPO_ROOT/hooks/subagent-stop.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
}

# ---------------------------------------------------------------------------
# Heartbeat
# ---------------------------------------------------------------------------

@test "subagent-stop heartbeats even when the subagent was not a reviewer" {
  payload="$(jq -cn --arg c "$PROJ" '{session_id:"s1", cwd:$c, hook_event_name:"SubagentStop", last_assistant_message:"I finished the search."}')"
  printf '%s' "$payload" | "$REPO_ROOT/hooks/subagent-stop.sh" >/dev/null
  printf '%s' "$payload" | "$REPO_ROOT/hooks/subagent-stop.sh" >/dev/null
  run bash -c "jq -r 'select(.kind==\"session-heartbeat\") | .event' '$GOAL_DIR/triggers.jsonl' | tr '\n' ' '"
  [ "$output" = "SubagentStop " ]
}
