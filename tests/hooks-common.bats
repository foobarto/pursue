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

@test "pursue_anchor has four colon-separated components" {
  run pursue_anchor "$PROJ" "$GOAL_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *:3:1:7 ]]
}
