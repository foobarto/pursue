#!/usr/bin/env bats
# Unit tests for hooks/lib/detect.sh.

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
}

teardown() { rm -rf "$TMP"; }

@test "pursue_payload_raw returns a compact object" {
  PURSUE_PAYLOAD='{"tool_input":{"b":2,"a":1}}'
  run pursue_payload_raw tool_input
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.a == 1 and .b == 2'
}

@test "pursue_payload_raw is empty for a missing field" {
  PURSUE_PAYLOAD='{"tool_input":{"a":1}}'
  run pursue_payload_raw tool_response
  [ "$output" = "" ]
}

@test "pursue_payload_raw is empty for malformed JSON" {
  PURSUE_PAYLOAD='not json'
  run pursue_payload_raw tool_input
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pursue_input_digest is stable regardless of key order" {
  PURSUE_PAYLOAD='{"tool_input":{"a":1,"b":2}}'
  one="$(pursue_input_digest)"
  PURSUE_PAYLOAD='{"tool_input":{"b":2,"a":1}}'
  two="$(pursue_input_digest)"
  [ -n "$one" ]
  [ "$one" = "$two" ]
}

@test "pursue_input_digest differs for different input" {
  PURSUE_PAYLOAD='{"tool_input":{"cmd":"npm test"}}'
  one="$(pursue_input_digest)"
  PURSUE_PAYLOAD='{"tool_input":{"cmd":"go test ./..."}}'
  two="$(pursue_input_digest)"
  [ "$one" != "$two" ]
}

@test "pursue_error_text reads an error field" {
  PURSUE_PAYLOAD='{"tool_response":{"error":"command not found: npm"}}'
  run pursue_error_text
  [[ "$output" == *"command not found"* ]]
}

@test "a successful object response with stderr noise is not an error" {
  PURSUE_PAYLOAD='{"tool_response":{"stdout":"done","stderr":"Shell cwd was reset to /tmp","interrupted":false}}'
  run pursue_error_text
  [ "$output" = "" ]
  run pursue_error_fingerprint
  [ "$output" = "" ]
}

@test "pursue_error_text is empty on success" {
  PURSUE_PAYLOAD='{"tool_response":{"stdout":"ok","stderr":""}}'
  run pursue_error_text
  [ "$output" = "" ]
}

@test "pursue_error_fingerprint is empty when there was no error" {
  PURSUE_PAYLOAD='{"tool_response":{"stdout":"ok"}}'
  run pursue_error_fingerprint
  [ "$output" = "" ]
}

@test "pursue_error_fingerprint ignores line numbers and case" {
  PURSUE_PAYLOAD='{"tool_response":{"error":"Error at line 42: npm not found"}}'
  one="$(pursue_error_fingerprint)"
  PURSUE_PAYLOAD='{"tool_response":{"error":"error at line 1337: NPM not found"}}'
  two="$(pursue_error_fingerprint)"
  [ -n "$one" ]
  [ "$one" = "$two" ]
}

@test "pursue_error_fingerprint separates genuinely different errors" {
  PURSUE_PAYLOAD='{"tool_response":{"error":"npm not found"}}'
  one="$(pursue_error_fingerprint)"
  PURSUE_PAYLOAD='{"tool_response":{"error":"permission denied"}}'
  two="$(pursue_error_fingerprint)"
  [ "$one" != "$two" ]
}

@test "a string response is the failure signal" {
  PURSUE_PAYLOAD='{"tool_response":"Error: Exit code 2\nbash: npm: command not found"}'
  run pursue_error_text
  [[ "$output" == Error:* ]]
  run pursue_error_fingerprint
  [ -n "$output" ]
}

@test "a real successful bash-shaped object yields no fingerprint" {
  PURSUE_PAYLOAD='{"tool_response":{"stdout":"ok","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false}}'
  run pursue_error_fingerprint
  [ "$output" = "" ]
}

@test "structured error fields still work for other harnesses" {
  PURSUE_PAYLOAD='{"tool_response":{"error":"permission denied"}}'
  run pursue_error_text
  [[ "$output" == *"permission denied"* ]]
}

@test "pursue_detect_load returns an empty state when the file is absent" {
  run pursue_detect_load "$GOAL_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version == 1'
  echo "$output" | jq -e '.errors == {}'
}

@test "pursue_detect_load returns an empty state when the file is corrupt" {
  printf 'not json at all' > "$GOAL_DIR/detect-state.json"
  run pursue_detect_load "$GOAL_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version == 1'
}

@test "pursue_detect_save then load round-trips" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  state="$(pursue_detect_bump "$state" errors abc123)"
  pursue_detect_save "$GOAL_DIR" "$state"
  run pursue_detect_load "$GOAL_DIR"
  echo "$output" | jq -e '.errors.abc123 == 1'
}

@test "pursue_detect_bump increments an existing key" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  state="$(pursue_detect_bump "$state" errors abc)"
  state="$(pursue_detect_bump "$state" errors abc)"
  run pursue_detect_count "$state" errors abc
  [ "$output" = "2" ]
}

@test "pursue_detect_count is 0 for an unseen key" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  run pursue_detect_count "$state" errors never-seen
  [ "$output" = "0" ]
}

@test "pursue_detect_save leaves no temp file behind" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  pursue_detect_save "$GOAL_DIR" "$state"
  run bash -c "ls '$GOAL_DIR'/detect-state.json.* 2>/dev/null | wc -l"
  [ "$output" = "0" ]
}

@test "detector state is bounded" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  for i in $(seq 1 20); do
    state="$(PURSUE_DETECT_MAX_KEYS=10 pursue_detect_bump "$state" errors "fp$i")"
  done
  run bash -c "printf '%s' '$state' | jq '.errors | length'"
  [ "$output" -le 10 ]
}

@test "detector state is bounded even at max=1" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  for i in $(seq 1 8); do
    state="$(PURSUE_DETECT_MAX_KEYS=1 pursue_detect_bump "$state" errors "key$i")"
  done
  run bash -c "printf '%s' '$state' | jq '.errors | length'"
  [ "$output" -le 1 ]
}

@test "pursue_detect_load rejects corrupt collection types" {
  printf '{"version":1,"errors":[1,2,3]}' > "$GOAL_DIR/detect-state.json"
  run pursue_detect_load "$GOAL_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version == 1'
  echo "$output" | jq -e '.errors == {}'
}

@test "pursue_detect_save cleans up temp file on jq failure" {
  state="not valid json for jq"
  pursue_detect_save "$GOAL_DIR" "$state"
  run bash -c "ls '$GOAL_DIR'/detect-state.json.* 2>/dev/null | wc -l"
  [ "$output" = "0" ]
  [[ ! -f "$GOAL_DIR/detect-state.json" ]]
}

# ---------------------------------------------------------------------------
# Triggers
# ---------------------------------------------------------------------------

fail_payload() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"error":"%s"}}' "$1" "$2"; }

@test "pursue_detect_trigger appends a trigger line" {
  pursue_detect_trigger "$GOAL_DIR" repeated_failure '{"count":3}'
  run jq -r '.kind' "$GOAL_DIR/triggers.jsonl"
  [ "$output" = "trigger" ]
  run jq -r '.name' "$GOAL_DIR/triggers.jsonl"
  [ "$output" = "repeated_failure" ]
}

@test "trigger lines are distinguishable from slice 1 heartbeats" {
  pursue_heartbeat "$GOAL_DIR" SessionStart heartbeat
  pursue_detect_trigger "$GOAL_DIR" repeated_failure '{"count":3}'
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' | wc -l"
  [ "$output" = "1" ]
  run bash -c "jq -r 'select(.kind==\"heartbeat\") | .event' '$GOAL_DIR/triggers.jsonl' | wc -l"
  [ "$output" = "1" ]
}

@test "pursue_detect_trigger emits valid JSON per line" {
  pursue_detect_trigger "$GOAL_DIR" scope_growth '{"paths":12}'
  run jq -e . "$GOAL_DIR/triggers.jsonl"
  [ "$status" -eq 0 ]
}

@test "repeated_failure fires on the third distinct-argument failure" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  for c in a b c; do
    PURSUE_PAYLOAD="$(fail_payload "$c" "npm not found")"
    state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  done
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c repeated_failure"
  [ "$output" = "1" ]
}

@test "repeated_failure does not fire on the second failure" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  for c in a b; do
    PURSUE_PAYLOAD="$(fail_payload "$c" "npm not found")"
    state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  done
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c repeated_failure || true"
  [ "$output" = "0" ]
}

@test "repeated_failure fires once, not on every later failure" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  for c in a b c d e; do
    PURSUE_PAYLOAD="$(fail_payload "$c" "npm not found")"
    state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  done
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c repeated_failure"
  [ "$output" = "1" ]
}

@test "retry_thrash fires when the same command repeats the same error" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  for _ in 1 2; do
    PURSUE_PAYLOAD="$(fail_payload "npm test" "npm not found")"
    state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  done
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c retry_thrash"
  [ "$output" = "1" ]
}

@test "retry_thrash does not fire when the worker changes tactics" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  for c in "npm test" "yarn test" "pnpm test"; do
    PURSUE_PAYLOAD="$(fail_payload "$c" "not found")"
    state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  done
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c retry_thrash || true"
  [ "$output" = "0" ]
}

@test "successful calls never fire a failure detector" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  for _ in 1 2 3 4; do
    PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"go test ./..."},"tool_response":{"stdout":"ok"}}'
    state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  done
  [ ! -s "$GOAL_DIR/triggers.jsonl" ] || {
    run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | wc -l"
    [ "$output" = "0" ]
  }
}

real_fail_payload() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":"Error: Exit code 127\\nbash: %s: command not found"}' "$1" "$1"
}

@test "retry_thrash fires on the real string-shaped failure response" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  for _ in 1 2; do
    PURSUE_PAYLOAD="$(real_fail_payload 'npm test')"
    state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  done
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c retry_thrash"
  [ "$output" = "1" ]
}

@test "a real successful object response never fires a failure detector" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  for _ in 1 2 3 4; do
    PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"go test ./..."},"tool_response":{"stdout":"ok","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false}}'
    state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  done
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | wc -l"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Churn, scope, and regression detectors
# ---------------------------------------------------------------------------

init_repo() {
  git -C "$PROJ" init -q 2>/dev/null
  git -C "$PROJ" config user.email t@e.st
  git -C "$PROJ" config user.name Test
  printf 'one\n' > "$PROJ/a.txt"
  git -C "$PROJ" add -A && git -C "$PROJ" commit -qm init
}

edit_payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"tool_response":{"stdout":"ok"}}' "$1"; }

@test "edit_revert_churn fires when a file returns to an earlier content" {
  init_repo
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD="$(edit_payload "$PROJ/a.txt")"
  printf 'two\n' > "$PROJ/a.txt"; state="$(pursue_detect_churn "$GOAL_DIR" "$state" "$PROJ")"
  printf 'three\n' > "$PROJ/a.txt"; state="$(pursue_detect_churn "$GOAL_DIR" "$state" "$PROJ")"
  printf 'two\n' > "$PROJ/a.txt"; state="$(pursue_detect_churn "$GOAL_DIR" "$state" "$PROJ")"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c edit_revert_churn"
  [ "$output" = "1" ]
}

@test "edit_revert_churn stays quiet on forward-only edits" {
  init_repo
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD="$(edit_payload "$PROJ/a.txt")"
  for v in two three four; do
    printf '%s\n' "$v" > "$PROJ/a.txt"
    state="$(pursue_detect_churn "$GOAL_DIR" "$state" "$PROJ")"
  done
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c edit_revert_churn || true"
  [ "$output" = "0" ]
}

@test "edit_revert_churn ignores non-edit tools" {
  init_repo
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"ok"}}'
  run pursue_detect_churn "$GOAL_DIR" "$state" "$PROJ"
  [ "$status" -eq 0 ]
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c edit_revert_churn || true"
  [ "$output" = "0" ]
}

@test "scope_growth falls back to a file-count threshold with no plan.json" {
  init_repo
  for i in $(seq 1 6); do printf 'x\n' > "$PROJ/f$i.txt"; done
  git -C "$PROJ" add -A
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{"stdout":"ok"}}'
  PURSUE_SCOPE_MAX_FILES=3 pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c scope_growth"
  [ "$output" = "1" ]
}

@test "scope_growth stays quiet under the threshold" {
  init_repo
  printf 'x\n' > "$PROJ/f1.txt"
  git -C "$PROJ" add -A
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"touch f1.txt"},"tool_response":{"stdout":"ok"}}'
  PURSUE_SCOPE_MAX_FILES=10 pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c scope_growth || true"
  [ "$output" = "0" ]
}

@test "scope_growth is silent outside a git repo" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"touch x"},"tool_response":{"stdout":"ok"}}'
  run pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ"
  [ "$status" -eq 0 ]
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c scope_growth || true"
  [ "$output" = "0" ]
}

@test "verification_regression fires when a passing command starts failing" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"go test ./..."},"tool_response":{"stdout":"ok"}}'
  state="$(pursue_detect_verification "$GOAL_DIR" "$state")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"go test ./..."},"tool_response":{"error":"FAIL"}}'
  state="$(pursue_detect_verification "$GOAL_DIR" "$state")"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c verification_regression"
  [ "$output" = "1" ]
}

@test "verification_regression does not fire for a command that never passed" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"go test ./..."},"tool_response":{"error":"FAIL"}}'
  state="$(pursue_detect_verification "$GOAL_DIR" "$state")"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c verification_regression || true"
  [ "$output" = "0" ]
}

@test "verification_regression ignores non-Bash tools" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Read","tool_input":{"file_path":"/x"},"tool_response":{"stdout":"ok"}}'
  run pursue_detect_verification "$GOAL_DIR" "$state"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verified == {}'
}

@test "verification_regression fires with real-shape success then failure" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"go test ./..."},"tool_response":{"stdout":"ok","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false}}'
  state="$(pursue_detect_verification "$GOAL_DIR" "$state")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"go test ./..."},"tool_response":"Error: Exit code 1\nFAIL github.com/x/y"}'
  state="$(pursue_detect_verification "$GOAL_DIR" "$state")"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c verification_regression"
  [ "$output" = "1" ]
}

@test "edit_revert_churn does not fire on failed Edit calls" {
  init_repo
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD="$(edit_payload "$PROJ/a.txt")"
  printf 'two\n' > "$PROJ/a.txt"; state="$(pursue_detect_churn "$GOAL_DIR" "$state" "$PROJ")"
  PURSUE_PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"'"$PROJ"'/a.txt"},"tool_response":"Error: old_string not found"}'
  state="$(pursue_detect_churn "$GOAL_DIR" "$state" "$PROJ")"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c edit_revert_churn || true"
  [ "$output" = "0" ]
}

@test "edit_revert_churn fires for NotebookEdit reverting content" {
  init_repo
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"'"$PROJ"'/a.txt"},"tool_response":{"stdout":"ok"}}'
  printf 'two\n' > "$PROJ/a.txt"; state="$(pursue_detect_churn "$GOAL_DIR" "$state" "$PROJ")"
  printf 'three\n' > "$PROJ/a.txt"; state="$(pursue_detect_churn "$GOAL_DIR" "$state" "$PROJ")"
  printf 'two\n' > "$PROJ/a.txt"; state="$(pursue_detect_churn "$GOAL_DIR" "$state" "$PROJ")"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c edit_revert_churn"
  [ "$output" = "1" ]
}

@test "scope_growth detects untracked files in subdirectories" {
  init_repo
  mkdir -p "$PROJ/subdir"
  for i in $(seq 1 6); do printf 'x\n' > "$PROJ/subdir/f$i.txt"; done
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{"stdout":"ok"}}'
  PURSUE_SCOPE_MAX_FILES=3 pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c scope_growth"
  [ "$output" = "1" ]
}

@test "verification_regression does not fire when same command fails in different cwd" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"cwd":"/path/one","tool_name":"Bash","tool_input":{"command":"npm test"},"tool_response":{"stdout":"ok"}}'
  state="$(pursue_detect_verification "$GOAL_DIR" "$state")"
  PURSUE_PAYLOAD='{"cwd":"/path/two","tool_name":"Bash","tool_input":{"command":"npm test"},"tool_response":{"error":"FAIL"}}'
  state="$(pursue_detect_verification "$GOAL_DIR" "$state")"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c verification_regression || true"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# PostToolUse entrypoint
#
# The brief's shared `trigger_names()` helper was never actually defined
# (Task 3 inlined the filter instead — see progress.md), so these tests use
# the same inline `jq` filter every other test in this file already uses,
# consistent with how Task 4 resolved the identical drift.
# ---------------------------------------------------------------------------

run_hook() { printf '%s' "$1" | "$REPO_ROOT/hooks/post-tool-use.sh"; }

pt_payload() {
  printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"error":"%s"}}' \
    "$PROJ" "$1" "$2"
}

@test "post-tool-use emits an empty object and exits 0" {
  run run_hook "$(pt_payload 'npm test' 'npm not found')"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "post-tool-use never emits decision, continue, or permissionDecision" {
  run run_hook "$(pt_payload 'npm test' 'npm not found')"
  echo "$output" | jq -e 'has("decision") | not'
  echo "$output" | jq -e 'has("continue") | not'
  echo "$output" | jq -e 'has("permissionDecision") | not'
  echo "$output" | jq -e 'has("stopReason") | not'
}

@test "post-tool-use accumulates state and fires retry_thrash across calls" {
  run_hook "$(pt_payload 'npm test' 'npm not found')" >/dev/null
  run_hook "$(pt_payload 'npm test' 'npm not found')" >/dev/null
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c retry_thrash"
  [ "$output" = "1" ]
}

@test "post-tool-use no-ops outside a pursuit" {
  run bash -c "printf '{\"cwd\":\"$TMP\",\"tool_name\":\"Bash\"}' | '$REPO_ROOT/hooks/post-tool-use.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "post-tool-use no-ops for a terminal STATUS" {
  printf 'stopped\n' > "$GOAL_DIR/STATUS"
  run_hook "$(pt_payload 'npm test' 'npm not found')" >/dev/null
  [ ! -f "$GOAL_DIR/detect-state.json" ]
}

@test "post-tool-use survives a malformed payload" {
  run bash -c "printf 'garbage' | '$REPO_ROOT/hooks/post-tool-use.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
}

@test "post-tool-use writes no stderr on the happy path" {
  run bash -c "printf '%s' '$(pt_payload 'npm test' 'npm not found')' | '$REPO_ROOT/hooks/post-tool-use.sh' 2>&1 1>/dev/null"
  [ "$output" = "" ]
}

@test "scope_growth excludes pursue's own state directory" {
  init_repo
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{"stdout":"ok"}}'
  mkdir -p "$PROJ/.agent/goals/$SLUG"
  for i in $(seq 1 6); do printf 'x\n' > "$PROJ/.agent/goals/$SLUG/scratch$i.txt"; done
  state="$(PURSUE_SCOPE_MAX_FILES=3 pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ")"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c scope_growth || true"
  [ "$output" = "0" ]

  mkdir -p "$PROJ/normal"
  for i in $(seq 1 6); do printf 'x\n' > "$PROJ/normal/file$i.txt"; done
  state="$(PURSUE_SCOPE_MAX_FILES=3 pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ")"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c scope_growth"
  [ "$output" = "1" ]
}

@test "scope_growth ignores read-only tools" {
  init_repo
  mkdir -p "$PROJ/src"; for i in $(seq 1 20); do : > "$PROJ/src/f$i.js"; done
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Read","tool_input":{"file_path":"/x"},"tool_response":{"stdout":"ok"}}'
  PURSUE_SCOPE_MAX_FILES=3 pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c scope_growth || true"
  [ "$output" = "0" ]
}

@test "scope_growth still fires for a mutating tool" {
  init_repo
  mkdir -p "$PROJ/src"; for i in $(seq 1 20); do : > "$PROJ/src/f$i.js"; done
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"touch x"},"tool_response":{"stdout":"ok"}}'
  PURSUE_SCOPE_MAX_FILES=3 pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' | grep -c scope_growth"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# PostToolUse under the harness's real concurrency
# ---------------------------------------------------------------------------

@test "parallel post-tool-use calls do not lose detector updates" {
  payload="$(pt_payload 'npm test' 'npm not found')"
  for _ in $(seq 1 10); do
    # 3>&- so bats does not wait on the background jobs holding its fd 3.
    printf '%s' "$payload" | "$REPO_ROOT/hooks/post-tool-use.sh" >/dev/null 2>&1 3>&- &
  done
  wait
  run jq -r '.errors | to_entries[0].value' "$GOAL_DIR/detect-state.json"
  [ "$output" = "10" ]
}

# ---------------------------------------------------------------------------
# Subagent isolation
# ---------------------------------------------------------------------------

@test "post-tool-use ignores tool calls made inside a subagent" {
  payload="$(jq -cn --arg c "$PROJ" '{session_id:"s1", cwd:$c, hook_event_name:"PostToolUse",
    agent_id:"agt_reviewer_1", agent_type:"Explore", tool_name:"Read",
    tool_input:{file_path:"/nope"}, tool_response:"Error: file not found"}')"
  run bash -c "printf '%s' '$payload' | '$REPO_ROOT/hooks/post-tool-use.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  [ ! -f "$GOAL_DIR/detect-state.json" ]
  [ ! -f "$GOAL_DIR/triggers.jsonl" ]
}

# ---------------------------------------------------------------------------
# scope_growth is a level, not an event (fire-once + re-arm)
# ---------------------------------------------------------------------------

@test "scope_growth fires once while the tree stays over the threshold" {
  init_repo
  mkdir -p "$PROJ/src"; for i in $(seq 1 20); do : > "$PROJ/src/f$i.js"; done
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"/x"},"tool_response":{"stdout":"ok"}}'
  for _ in 1 2 3 4 5; do
    state="$(PURSUE_SCOPE_MAX_FILES=3 pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ")"
  done
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' | grep -c scope_growth"
  [ "$output" = "1" ]
}

@test "scope_growth re-arms after the tree drops back under the threshold" {
  init_repo
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"/x"},"tool_response":{"stdout":"ok"}}'

  mkdir -p "$PROJ/src"; for i in $(seq 1 20); do : > "$PROJ/src/f$i.js"; done
  state="$(PURSUE_SCOPE_MAX_FILES=3 pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ")"
  rm -rf "$PROJ/src"
  state="$(PURSUE_SCOPE_MAX_FILES=3 pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ")"
  mkdir -p "$PROJ/src"; for i in $(seq 1 20); do : > "$PROJ/src/f$i.js"; done
  state="$(PURSUE_SCOPE_MAX_FILES=3 pursue_detect_scope "$GOAL_DIR" "$state" "$PROJ")"

  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' | grep -c scope_growth"
  [ "$output" = "2" ]
}

# ---------------------------------------------------------------------------
# retry_thrash means "unchanged tree", not merely "same command"
# ---------------------------------------------------------------------------

@test "retry_thrash does not fire when the tree changed between identical failures" {
  init_repo
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD="$(fail_payload 'npm test' 'assertion failed')"
  state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  printf 'edited by the worker\n' > "$PROJ/a.txt"
  state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' 2>/dev/null | grep -c retry_thrash || true"
  [ "$output" = "0" ]
}

@test "retry_thrash still fires when the tree is untouched between identical failures" {
  init_repo
  state="$(pursue_detect_load "$GOAL_DIR")"
  PURSUE_PAYLOAD="$(fail_payload 'npm test' 'assertion failed')"
  state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  state="$(pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' | grep -c retry_thrash"
  [ "$output" = "1" ]
}

@test "a non-canonical threshold override still fires the detector" {
  state="$(pursue_detect_load "$GOAL_DIR")"
  for c in a b c; do
    PURSUE_PAYLOAD="$(fail_payload "$c" "npm not found")"
    state="$(PURSUE_REPEAT_THRESHOLD='03' pursue_detect_failures "$GOAL_DIR" "$state" "$PROJ")"
  done
  run bash -c "jq -r 'select(.kind==\"trigger\") | .name' '$GOAL_DIR/triggers.jsonl' | grep -c repeated_failure"
  [ "$output" = "1" ]
}
