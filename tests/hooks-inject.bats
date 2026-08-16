#!/usr/bin/env bats
# End-to-end tests for the pursue injection hooks.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  PROJ="$TMP/proj"
  SLUG="2026-08-16-demo"
  GOAL_DIR="$PROJ/.agent/goals/$SLUG"
  mkdir -p "$GOAL_DIR"
  printf '%s\n' "$SLUG" > "$PROJ/.agent/goals/active"
  printf 'active\n' > "$GOAL_DIR/STATUS"
  printf '# Goal: ship the widget\n\nUNIQUE_CONTRACT_MARKER\n' > "$GOAL_DIR/goal.md"
  cat > "$GOAL_DIR/plan.json" <<'JSON'
{"plan_version": 2, "active_step": 1, "iteration": 5,
 "steps": [{"title": "scaffold", "done_when": "dir exists"},
           {"title": "wire the adapter", "done_when": "adapter test green"}]}
JSON
  cat > "$GOAL_DIR/progress.md" <<'MD'
# Progress

## 2026-08-16T09:00 — oldest entry
- Outcome: failed
ENTRY_ONE_MARKER

## 2026-08-16T10:00 — middle entry
ENTRY_TWO_MARKER

## 2026-08-16T11:00 — newest entry
ENTRY_THREE_MARKER
MD
  printf '# Active blockers\n\nBLOCKER_MARKER\n' > "$GOAL_DIR/blockers.md"
}

teardown() { rm -rf "$TMP"; }

payload() { printf '{"session_id":"s1","cwd":"%s","hook_event_name":"%s"}' "$1" "$2"; }

@test "session-start injects the contract" {
  run bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"'
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q UNIQUE_CONTRACT_MARKER
}

@test "session-start injects the active step, not the whole plan" {
  run bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'"
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  echo "$ctx" | grep -q "wire the adapter"
  echo "$ctx" | grep -q "adapter test green"
  # "not the whole plan" is the half that matters: step 0 must be absent.
  # Asserted with [[ ]], not `! grep`: set -e ignores the failure of a
  # pipeline that begins with `!`, so a negated grep anywhere but the last
  # line of a test is not an assertion at all (shellcheck SC2314).
  [[ "$ctx" != *"scaffold"* ]]
  [[ "$ctx" != *"dir exists"* ]]
}

@test "session-start injects open blockers" {
  run bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'"
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q BLOCKER_MARKER
}

@test "session-start injects only the last N progress entries" {
  run bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | PURSUE_PROGRESS_TAIL=2 '$REPO_ROOT/hooks/session-start.sh'"
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  echo "$ctx" | grep -q ENTRY_THREE_MARKER
  echo "$ctx" | grep -q ENTRY_TWO_MARKER
  ! echo "$ctx" | grep -q ENTRY_ONE_MARKER
}

@test "session-start includes the anchor" {
  run bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'"
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -qE 'Anchor: .+:2:1:5'
}

@test "session-start writes a heartbeat" {
  bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'" >/dev/null
  [ -f "$GOAL_DIR/triggers.jsonl" ]
  run jq -r '.event' "$GOAL_DIR/triggers.jsonl"
  [ "$output" = "SessionStart" ]
}

# Linux caps a single exec argument at MAX_ARG_STRLEN (128KB) regardless of
# the much larger ARG_MAX.  Passing the assembled context through jq's argv
# therefore truncated to nothing above ~126KB: the hook fell back to {} while
# the heartbeat had already been written, so a pursuit that injected nothing
# looked exactly like a healthy one.
@test "session-start injects a contract far larger than MAX_ARG_STRLEN" {
  { printf '# Goal: big\n\n'
    head -c 200000 /dev/zero | tr '\0' 'x'
    printf '\nUNIQUE_CONTRACT_MARKER\n'
  } > "$GOAL_DIR/goal.md"

  run bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 200000'
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q UNIQUE_CONTRACT_MARKER

  run jq -r '.kind' "$GOAL_DIR/triggers.jsonl"
  [ "$output" = "heartbeat" ]
}

# The heartbeat must describe what actually happened.  A jq that refuses the
# emit stands in for any reason emission can fail; the run must still emit
# valid JSON, and must NOT leave a record claiming a healthy injection.
@test "session-start records emit-failed rather than a heartbeat when emission fails" {
  real_jq="$(command -v jq)"
  mkdir -p "$TMP/stub"
  cat > "$TMP/stub/jq" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-Rs" ] && exit 1; done
exec "$real_jq" "\$@"
STUB
  chmod +x "$TMP/stub/jq"

  run bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | PATH='$TMP/stub:$PATH' '$REPO_ROOT/hooks/session-start.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]

  [ -f "$GOAL_DIR/triggers.jsonl" ]
  run jq -r '.kind' "$GOAL_DIR/triggers.jsonl"
  [ "$output" = "emit-failed" ]
}

@test "session-start no-ops when no pursuit is active" {
  : > "$PROJ/.agent/goals/active"
  run bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "session-start no-ops outside any pursuit" {
  run bash -c "printf '%s' '$(payload "$TMP" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "session-start no-ops for a stopped pursuit" {
  printf 'stopped\n' > "$GOAL_DIR/STATUS"
  run bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'"
  [ "$output" = "{}" ]
}

@test "session-start still injects for a paused pursuit" {
  printf 'paused\n' > "$GOAL_DIR/STATUS"
  run bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'"
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'Status: paused'
}

@test "session-start prints nothing to stderr when STATUS is missing" {
  rm -f "$GOAL_DIR/STATUS"
  bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'" \
    >"$TMP/out" 2>"$TMP/err"
  [ ! -s "$TMP/err" ]
  [ "$(cat "$TMP/out")" = "{}" ]
}

@test "session-start emits valid JSON on malformed input" {
  run bash -c "printf 'garbage' | '$REPO_ROOT/hooks/session-start.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
}

@test "session-start never emits decision or continue" {
  run bash -c "printf '%s' '$(payload "$PROJ" SessionStart)' | '$REPO_ROOT/hooks/session-start.sh'"
  echo "$output" | jq -e 'has("decision") | not'
  echo "$output" | jq -e 'has("continue") | not'
}

@test "pre-compact injects the contract" {
  run bash -c "printf '%s' '$(payload "$PROJ" PreCompact)' | '$REPO_ROOT/hooks/pre-compact.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreCompact"'
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q UNIQUE_CONTRACT_MARKER
}

@test "pre-compact writes a heartbeat naming its own event" {
  bash -c "printf '%s' '$(payload "$PROJ" PreCompact)' | '$REPO_ROOT/hooks/pre-compact.sh'" >/dev/null
  run jq -r '.event' "$GOAL_DIR/triggers.jsonl"
  [ "$output" = "PreCompact" ]
}

@test "pre-compact no-ops outside any pursuit" {
  run bash -c "printf '%s' '$(payload "$TMP" PreCompact)' | '$REPO_ROOT/hooks/pre-compact.sh'"
  [ "$output" = "{}" ]
}

@test "pre-compact never emits decision or continue" {
  run bash -c "printf '%s' '$(payload "$PROJ" PreCompact)' | '$REPO_ROOT/hooks/pre-compact.sh'"
  echo "$output" | jq -e 'has("decision") | not'
  echo "$output" | jq -e 'has("continue") | not'
}
