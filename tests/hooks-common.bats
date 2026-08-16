#!/usr/bin/env bats
# Unit tests for hooks/lib/common.sh.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  PROJ="$TMP/proj"
  SLUG="2026-08-16-demo"
  GOAL_DIR="$PROJ/.agent/goals/$SLUG"
  mkdir -p "$GOAL_DIR/verdicts" "$PROJ/sub/deep"
  printf '%s\n' "$SLUG" > "$PROJ/.agent/goals/active"
  printf '# Goal: demo\n' > "$GOAL_DIR/goal.md"
  printf 'active\n' > "$GOAL_DIR/STATUS"
  cat > "$GOAL_DIR/plan.json" <<'JSON'
{"plan_version": 3, "active_step": 1, "iteration": 7,
 "steps": [{"title": "first", "done_when": "a"},
           {"title": "second", "done_when": "b"}]}
JSON
  # shellcheck source=/dev/null
  source "$REPO_ROOT/hooks/lib/common.sh"
}

teardown() { rm -rf "$TMP"; }

# Turn $PROJ into a real git repo.  Identity and signing are pinned so the
# fixture does not depend on (or trip over) the runner's global git config.
init_git_proj() {
  git -C "$PROJ" init -q
  git -C "$PROJ" config user.email "test@example.invalid"
  git -C "$PROJ" config user.name "pursue tests"
  git -C "$PROJ" config commit.gpgsign false
}

commit_git_proj() {
  printf 'hello\n' > "$PROJ/tracked.txt"
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "fixture"
}

@test "pursue_project_root finds the root from the project dir" {
  run pursue_project_root "$PROJ"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJ" ]
}

@test "pursue_project_root walks up from a nested dir" {
  run pursue_project_root "$PROJ/sub/deep"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJ" ]
}

@test "pursue_project_root fails when no pursuit state exists" {
  run pursue_project_root "$TMP"
  [ "$status" -eq 1 ]
}

@test "pursue_active_slug reads and trims the slug" {
  run pursue_active_slug "$PROJ"
  [ "$status" -eq 0 ]
  [ "$output" = "$SLUG" ]
}

@test "pursue_active_slug fails on an empty active file" {
  : > "$PROJ/.agent/goals/active"
  run pursue_active_slug "$PROJ"
  [ "$status" -eq 1 ]
}

@test "pursue_goal_dir returns the state directory" {
  run pursue_goal_dir "$PROJ"
  [ "$status" -eq 0 ]
  [ "$output" = "$GOAL_DIR" ]
}

@test "pursue_plan_field reads plan.json fields" {
  run pursue_plan_field "$GOAL_DIR" plan_version
  [ "$output" = "3" ]
  run pursue_plan_field "$GOAL_DIR" active_step
  [ "$output" = "1" ]
}

@test "pursue_plan_field defaults to 0 for a missing field" {
  run pursue_plan_field "$GOAL_DIR" nonexistent
  [ "$output" = "0" ]
}

@test "pursue_tree_digest is stable and marks non-git trees" {
  run pursue_tree_digest "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == nogit-* ]]
}

@test "pursue_tree_digest is a single line inside a git repo" {
  init_git_proj
  commit_git_proj
  run pursue_tree_digest "$PROJ"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" != nogit-* ]]
  [[ "$output" == *-* ]]
}

@test "pursue_tree_digest changes when the tree goes dirty" {
  init_git_proj
  commit_git_proj
  run pursue_tree_digest "$PROJ"
  clean="$output"
  printf 'uncommitted\n' >> "$PROJ/tracked.txt"
  run pursue_tree_digest "$PROJ"
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" != "$clean" ]
}

# `git rev-parse HEAD` prints the literal string "HEAD" to stdout and exits
# 128 in a repo with no commits, so a `|| printf 'nohead'` fallback appends
# to it rather than replacing it and the anchor renders across two lines.
@test "pursue_tree_digest is a single line in a commitless git repo" {
  init_git_proj
  run pursue_tree_digest "$PROJ"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == nohead-* ]]
}

@test "pursue_anchor is a single line in a commitless git repo" {
  init_git_proj
  run pursue_anchor "$PROJ" "$GOAL_DIR"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *:3:1:7 ]]
}

@test "pursue_anchor has four colon-separated components" {
  run pursue_anchor "$PROJ" "$GOAL_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *:3:1:7 ]]
}

@test "pursue_payload_field extracts top-level fields" {
  PURSUE_PAYLOAD='{"cwd":"/tmp/x","hook_event_name":"SessionStart"}'
  run pursue_payload_field cwd
  [ "$output" = "/tmp/x" ]
  run pursue_payload_field hook_event_name
  [ "$output" = "SessionStart" ]
}

@test "pursue_payload_field is empty for a missing field" {
  PURSUE_PAYLOAD='{"cwd":"/tmp/x"}'
  run pursue_payload_field nope
  [ "$output" = "" ]
}

@test "pursue_payload_field is empty for malformed JSON" {
  PURSUE_PAYLOAD='not json at all'
  run pursue_payload_field cwd
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pursue_emit_noop emits an empty JSON object" {
  run pursue_emit_noop
  [ "$output" = "{}" ]
}

@test "pursue_emit_context emits valid additionalContext JSON" {
  run pursue_emit_context SessionStart "line one
line \"two\""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"'
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("line one")'
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("line \"two\"")'
}

@test "pursue_emit_context emits no decision or continue key" {
  run pursue_emit_context SessionStart "x"
  echo "$output" | jq -e 'has("decision") | not'
  echo "$output" | jq -e 'has("continue") | not'
}

@test "pursue_heartbeat appends one JSON line per call" {
  pursue_heartbeat "$GOAL_DIR" SessionStart
  pursue_heartbeat "$GOAL_DIR" PreCompact
  [ "$(wc -l < "$GOAL_DIR/triggers.jsonl")" -eq 2 ]
  run jq -r -s '.[1].event' "$GOAL_DIR/triggers.jsonl"
  [ "$output" = "PreCompact" ]
}
