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
  run bash -c "jq -r 'select(.kind==\"verdict\") | .name' '$GOAL_DIR/triggers.jsonl'"
  [ "$output" = "recorded" ]
}

@test "subagent-stop discards a malformed verdict and says so" {
  payload="$(jq -cn --arg c "$PROJ" --arg m "$(msg_with '{"verdict":"maybe","reason":"x"}')" \
    '{cwd:$c, hook_event_name:"SubagentStop", last_assistant_message:$m}')"
  run bash -c "printf '%s' '$payload' | '$REPO_ROOT/hooks/subagent-stop.sh'"
  [ "$status" -eq 0 ]
  [ ! -d "$GOAL_DIR/verdicts" ] || {
    run bash -c "ls '$GOAL_DIR/verdicts' | wc -l"; [ "$output" = "0" ]
  }
  run bash -c "jq -r 'select(.kind==\"verdict\") | .name' '$GOAL_DIR/triggers.jsonl'"
  [ "$output" = "rejected" ]
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

# ---------------------------------------------------------------------------
# Extraction takes the last complete block
# ---------------------------------------------------------------------------

@test "pursue_verdict_extract takes the last of two complete blocks" {
  text="$(printf 'For example, a passing review looks like:\n\n```pursue-verdict\n{"verdict":"approve","reason":"the example from my brief"}\n```\n\nMy actual verdict:\n\n```pursue-verdict\n{"verdict":"stop","reason":"the tests do not run"}\n```\n')"
  run pursue_verdict_extract "$text"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verdict == "stop"'
}

@test "pursue_verdict_extract prefers a complete block over a later unclosed one" {
  text="$(printf '```pursue-verdict\n{"verdict":"stop","reason":"the tests do not run"}\n```\n\nOops, half a block:\n\n```pursue-verdict\n{"verdict":"continue"\n')"
  run pursue_verdict_extract "$text"
  echo "$output" | jq -e '.verdict == "stop"'
}

@test "pursue_verdict_extract ignores an unterminated block before a complete one" {
  text="$(printf 'Draft:\n\n```pursue-verdict\n{"verdict":"approve","reason":"draft"}\n\nActual:\n\n```pursue-verdict\n{"verdict":"stop","reason":"the tests do not run"}\n```\n')"
  run pursue_verdict_extract "$text"
  echo "$output" | jq -e '.verdict == "stop"'
}

@test "pursue_verdict_extract is empty when the only block is unterminated" {
  text="$(printf 'Here you go:\n\n```pursue-verdict\n{"verdict":"continue","reason":"looks fine"}\n\nand some trailing prose\n')"
  run pursue_verdict_extract "$text"
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# A verdict cannot be downgraded at the same anchor
# ---------------------------------------------------------------------------

@test "a recorded stop is not overwritten by a later continue" {
  pursue_verdict_write "$GOAL_DIR" 'a:1:0:1' '{"verdict":"stop","reason":"unsafe"}'
  run pursue_verdict_write "$GOAL_DIR" 'a:1:0:1' '{"verdict":"continue","reason":"looks fine to me"}'
  [ "$status" -ne 0 ]
  slug="$(pursue_anchor_slug 'a:1:0:1')"
  run jq -r '.verdict' "$GOAL_DIR/verdicts/$slug.json"
  [ "$output" = "stop" ]
}

@test "a recorded pause is not overwritten by a later continue" {
  pursue_verdict_write "$GOAL_DIR" 'a:1:0:1' '{"verdict":"pause","reason":"ask the operator"}'
  run pursue_verdict_write "$GOAL_DIR" 'a:1:0:1' '{"verdict":"continue","reason":"looks fine to me"}'
  [ "$status" -ne 0 ]
  slug="$(pursue_anchor_slug 'a:1:0:1')"
  run jq -r '.verdict' "$GOAL_DIR/verdicts/$slug.json"
  [ "$output" = "pause" ]
}

@test "a recorded continue is upgraded by a later stop" {
  pursue_verdict_write "$GOAL_DIR" 'a:1:0:1' '{"verdict":"continue","reason":"looks fine to me"}'
  run pursue_verdict_write "$GOAL_DIR" 'a:1:0:1' '{"verdict":"stop","reason":"unsafe"}'
  [ "$status" -eq 0 ]
  slug="$(pursue_anchor_slug 'a:1:0:1')"
  run jq -r '.verdict' "$GOAL_DIR/verdicts/$slug.json"
  [ "$output" = "stop" ]
}

@test "pursue_verdict_write records the reviewer's agent_id" {
  pursue_verdict_write "$GOAL_DIR" 'a:1:0:1' '{"verdict":"continue","reason":"ok"}' 'agt_7f3'
  slug="$(pursue_anchor_slug 'a:1:0:1')"
  run jq -r '.agent_id' "$GOAL_DIR/verdicts/$slug.json"
  [ "$output" = "agt_7f3" ]
}

@test "subagent-stop refuses a second reviewer downgrading a stop" {
  anchor="$(pursue_anchor "$PROJ" "$GOAL_DIR")"
  slug="$(pursue_anchor_slug "$anchor")"
  stop_payload="$(jq -cn --arg c "$PROJ" --arg g "agt_watchdog" --arg m "$(msg_with '{"verdict":"stop","reason":"acceptance criteria unmet"}')" \
    '{session_id:"s1", cwd:$c, hook_event_name:"SubagentStop", agent_id:$g, last_assistant_message:$m}')"
  cont_payload="$(jq -cn --arg c "$PROJ" --arg g "agt_friendly" --arg m "$(msg_with '{"verdict":"continue","reason":"all good, carry on"}')" \
    '{session_id:"s1", cwd:$c, hook_event_name:"SubagentStop", agent_id:$g, last_assistant_message:$m}')"

  printf '%s' "$stop_payload" | "$REPO_ROOT/hooks/subagent-stop.sh" >/dev/null
  printf '%s' "$cont_payload" | "$REPO_ROOT/hooks/subagent-stop.sh" >/dev/null

  run jq -r '.verdict' "$GOAL_DIR/verdicts/$slug.json"
  [ "$output" = "stop" ]
  run jq -r '.agent_id' "$GOAL_DIR/verdicts/$slug.json"
  [ "$output" = "agt_watchdog" ]
  run bash -c "jq -r 'select(.kind==\"verdict\") | .name' '$GOAL_DIR/triggers.jsonl' | tr '\n' ' '"
  [ "$output" = "recorded rejected " ]
}

# ---------------------------------------------------------------------------
# Verdict records are not triggers
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The downgrade refusal is a check-then-write, so it needs the lock
#
# Dispatching the two reviewers *together* is the case that matters: the
# clobber needs the continue's check to happen before the stop's write.
# Measured against this same hook with no serialisation on the verdict path,
# 21 of 40 pairs ended with `continue`; with the lock, 0 of 40.
#
# Deliberately not "write a stop, then race two continues": both continues
# read the stop and refuse whether or not anything is locked, so it asserts
# nothing at all — 0 of 40 unlocked, same as locked.
# ---------------------------------------------------------------------------

@test "a stop and a continue landing together leave the stop" {
  command -v flock >/dev/null 2>&1 || skip "no flock: this hook runs unlocked here by design"
  anchor="$(pursue_anchor "$PROJ" "$GOAL_DIR")"
  slug="$(pursue_anchor_slug "$anchor")"
  stop_payload="$(jq -cn --arg c "$PROJ" --arg g "agt_watchdog" --arg m "$(msg_with '{"verdict":"stop","reason":"acceptance criteria unmet"}')" \
    '{session_id:"s1", cwd:$c, hook_event_name:"SubagentStop", agent_id:$g, last_assistant_message:$m}')"
  cont_payload="$(jq -cn --arg c "$PROJ" --arg g "agt_friendly" --arg m "$(msg_with '{"verdict":"continue","reason":"all good, carry on"}')" \
    '{session_id:"s1", cwd:$c, hook_event_name:"SubagentStop", agent_id:$g, last_assistant_message:$m}')"

  for _ in $(seq 1 15); do
    rm -rf "$GOAL_DIR/verdicts"
    # 3>&- so bats does not wait on the background jobs holding its fd 3.
    printf '%s' "$stop_payload" | "$REPO_ROOT/hooks/subagent-stop.sh" >/dev/null 2>&1 3>&- &
    printf '%s' "$cont_payload" | "$REPO_ROOT/hooks/subagent-stop.sh" >/dev/null 2>&1 3>&- &
    wait
    [ "$(jq -r '.verdict' "$GOAL_DIR/verdicts/$slug.json")" = "stop" ]
  done
}

@test "subagent-stop writes no kind:trigger line on either path" {
  good="$(jq -cn --arg c "$PROJ" --arg m "$(msg_with '{"verdict":"stop","reason":"unsafe"}')" \
    '{session_id:"s1", cwd:$c, hook_event_name:"SubagentStop", last_assistant_message:$m}')"
  bad="$(jq -cn --arg c "$PROJ" --arg m "$(msg_with '{"verdict":"maybe","reason":"x"}')" \
    '{session_id:"s1", cwd:$c, hook_event_name:"SubagentStop", last_assistant_message:$m}')"
  printf '%s' "$good" | "$REPO_ROOT/hooks/subagent-stop.sh" >/dev/null
  printf '%s' "$bad"  | "$REPO_ROOT/hooks/subagent-stop.sh" >/dev/null
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' | wc -l"
  [ "$output" = "0" ]
  run bash -c "jq -r 'select(.kind==\"verdict\") | .name' '$GOAL_DIR/triggers.jsonl' | tr '\n' ' '"
  [ "$output" = "recorded rejected " ]
}
