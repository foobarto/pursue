#!/usr/bin/env bats
# bats-core test suite for install.sh.  Runs in CI via `bats tests/`.
# This is a single-skill repo, so the installed unit is the skill `pursue`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
}

teardown() {
  rm -rf "$FAKE_HOME"
}

@test "--version prints something" {
  run "$REPO_ROOT/install.sh" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"foobarto/pursue"* ]]
}

@test "exits 1 when no CLIs detected" {
  run "$REPO_ROOT/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no supported CLIs detected"* ]]
}

@test "--list shows plan for detected CLIs only" {
  mkdir -p "$FAKE_HOME/.claude"
  run "$REPO_ROOT/install.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-code"* ]]
  [[ "$output" == *"pursue"* ]]
  [[ "$output" != *"codex:"* ]]
}

@test "unknown --cli exits 2" {
  run "$REPO_ROOT/install.sh" --cli bogus
  [ "$status" -eq 2 ]
}

@test "unknown skill positional exits 2" {
  mkdir -p "$FAKE_HOME/.claude"
  run "$REPO_ROOT/install.sh" nonexistent-skill
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown skill"* ]]
}

@test "accepts its own skill name as a positional" {
  mkdir -p "$FAKE_HOME/.claude"
  run "$REPO_ROOT/install.sh" pursue
  [ "$status" -eq 0 ]
  [ -L "$FAKE_HOME/.claude/skills/pursue" ]
}

@test "install links the repo in as the skill dir for claude-code" {
  mkdir -p "$FAKE_HOME/.claude"
  run "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ -L "$FAKE_HOME/.claude/skills/pursue" ]
  target="$(readlink "$FAKE_HOME/.claude/skills/pursue")"
  [ "$target" = "$REPO_ROOT" ]
  # SKILL.md is reachable via the symlink.
  [ -f "$FAKE_HOME/.claude/skills/pursue/SKILL.md" ]
}

@test "install is idempotent for claude-code" {
  mkdir -p "$FAKE_HOME/.claude"
  "$REPO_ROOT/install.sh" >/dev/null
  run "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already linked"* ]]
}

@test "install generates gemini-extension.json manifest" {
  mkdir -p "$FAKE_HOME/.gemini"
  run "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  manifest="$FAKE_HOME/.gemini/extensions/pursue/gemini-extension.json"
  [ -f "$manifest" ]
  python3 -c "import json; m=json.load(open('$manifest')); assert m['name']=='pursue'; assert m['contextFileName']=='GEMINI.md'; assert m['description']"
  [ -L "$FAKE_HOME/.gemini/extensions/pursue/GEMINI.md" ]
}

@test "install is idempotent for gemini" {
  mkdir -p "$FAKE_HOME/.gemini"
  "$REPO_ROOT/install.sh" >/dev/null
  run "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
}

@test "refuses to clobber user directory without --force" {
  mkdir -p "$FAKE_HOME/.claude/skills/pursue"
  echo "user data" > "$FAKE_HOME/.claude/skills/pursue/README.md"
  run "$REPO_ROOT/install.sh"
  [ "$status" -eq 4 ]
  [[ "$output" == *"was not created by this installer"* ]]
  [ -f "$FAKE_HOME/.claude/skills/pursue/README.md" ]
}

@test "--force overwrites pre-existing user directory" {
  mkdir -p "$FAKE_HOME/.claude/skills/pursue"
  echo "user data" > "$FAKE_HOME/.claude/skills/pursue/README.md"
  run "$REPO_ROOT/install.sh" --force
  [ "$status" -eq 0 ]
  [ -L "$FAKE_HOME/.claude/skills/pursue" ]
}

@test "--dry-run writes nothing to disk" {
  mkdir -p "$FAKE_HOME/.claude"
  run "$REPO_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/.claude/skills/pursue" ]
}

@test "--skill-dir installs into an arbitrary directory" {
  dest="$FAKE_HOME/project/.claude/skills"
  run "$REPO_ROOT/install.sh" --skill-dir "$dest"
  [ "$status" -eq 0 ]
  [ -L "$dest/pursue" ]
  target="$(readlink "$dest/pursue")"
  [ "$target" = "$REPO_ROOT" ]
}

@test "--skill-dir works with no CLIs detected" {
  dest="$FAKE_HOME/proj/.claude/skills"
  run "$REPO_ROOT/install.sh" --skill-dir "$dest"
  [ "$status" -eq 0 ]
  [ -L "$dest/pursue" ]
}

@test "--skill-dir is idempotent" {
  dest="$FAKE_HOME/proj/.claude/skills"
  "$REPO_ROOT/install.sh" --skill-dir "$dest" >/dev/null
  run "$REPO_ROOT/install.sh" --skill-dir "$dest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already linked"* ]]
}

@test "--skill-dir requires an argument" {
  run "$REPO_ROOT/install.sh" --skill-dir
  [ "$status" -eq 2 ]
}

@test "--copy uses cp instead of symlink, prunes .git, records provenance" {
  mkdir -p "$FAKE_HOME/.claude"
  run "$REPO_ROOT/install.sh" --copy
  [ "$status" -eq 0 ]
  [ ! -L "$FAKE_HOME/.claude/skills/pursue" ]
  [ -d "$FAKE_HOME/.claude/skills/pursue" ]
  [ -f "$FAKE_HOME/.claude/skills/pursue/SKILL.md" ]
  [ -f "$FAKE_HOME/.claude/skills/pursue/.foobarto-skills" ]
  [ ! -e "$FAKE_HOME/.claude/skills/pursue/.git" ]
}
