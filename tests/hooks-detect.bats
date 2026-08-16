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
