#!/usr/bin/env bats
# Hook registration tests for install.sh.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
  SETTINGS="$FAKE_HOME/.claude/settings.json"
}

teardown() { rm -rf "$FAKE_HOME"; }

@test "hooks are not installed by default" {
  mkdir -p "$FAKE_HOME/.claude"
  run "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$SETTINGS" ]
}

@test "--hooks registers SessionStart and PreCompact for claude-code" {
  mkdir -p "$FAKE_HOME/.claude"
  run "$REPO_ROOT/install.sh" --hooks
  [ "$status" -eq 0 ]
  [ -f "$SETTINGS" ]
  jq -e '.hooks.SessionStart[0].hooks[0].command | contains("session-start.sh")' "$SETTINGS"
  jq -e '.hooks.PreCompact[0].hooks[0].command | contains("pre-compact.sh")' "$SETTINGS"
  jq -e '.hooks.SessionStart[0].hooks[0].type == "command"' "$SETTINGS"
}

# The registered command is a shell word, not a bare path: both harnesses
# run it through a shell.  Truncating at the first space to find "the
# script" would hide exactly the bug this asserts against, so unwrap the
# whole command the way a shell does and check that.
@test "--hooks registers a command that resolves to an executable script" {
  mkdir -p "$FAKE_HOME/.claude"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$SETTINGS")"
  eval "script=$cmd"
  [[ "$script" == /* ]]
  [ -x "$script" ]
}

# Install from a directory whose name contains a space.  An unquoted command
# string becomes `/tmp/.../my` plus a stray argument once the harness hands
# it to a shell, so the hook never runs.
@test "--hooks registers a runnable command when the repo path contains a space" {
  spaced="$FAKE_HOME/my repo"
  mkdir -p "$spaced" "$FAKE_HOME/.claude"
  cp "$REPO_ROOT/install.sh" "$REPO_ROOT/SKILL.md" "$spaced/"
  cp -r "$REPO_ROOT/hooks" "$spaced/"

  "$spaced/install.sh" --hooks >/dev/null
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$SETTINGS")"
  [[ "$cmd" == *"my repo"* ]]

  # Run it exactly as the harness would: through a shell, as a command line.
  run bash -c "printf '{}' | $cmd"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

# Quoting has to round-trip: --no-hooks matches entries by exact command
# string, so whatever --hooks writes is what --no-hooks must look for.
@test "--hooks is idempotent and --no-hooks removes it when the path contains a space" {
  spaced="$FAKE_HOME/my repo"
  mkdir -p "$spaced" "$FAKE_HOME/.claude"
  cp "$REPO_ROOT/install.sh" "$REPO_ROOT/SKILL.md" "$spaced/"
  cp -r "$REPO_ROOT/hooks" "$spaced/"

  "$spaced/install.sh" --hooks >/dev/null
  "$spaced/install.sh" --hooks >/dev/null
  run jq '[.hooks.SessionStart[].hooks[] | select(.command | contains("session-start.sh"))] | length' "$SETTINGS"
  [ "$output" = "1" ]

  "$spaced/install.sh" --no-hooks >/dev/null
  run jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("session-start.sh"))] | length' "$SETTINGS"
  [ "$output" = "0" ]
}

@test "--hooks preserves unrelated settings keys" {
  mkdir -p "$FAKE_HOME/.claude"
  printf '{"model":"opus","env":{"FOO":"bar"}}' > "$SETTINGS"
  run "$REPO_ROOT/install.sh" --hooks
  [ "$status" -eq 0 ]
  jq -e '.model == "opus"' "$SETTINGS"
  jq -e '.env.FOO == "bar"' "$SETTINGS"
  jq -e '.hooks.SessionStart' "$SETTINGS"
}

@test "--no-hooks preserves unrelated settings keys" {
  mkdir -p "$FAKE_HOME/.claude"
  printf '{"model":"opus","env":{"FOO":"bar"}}' > "$SETTINGS"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  run "$REPO_ROOT/install.sh" --no-hooks
  [ "$status" -eq 0 ]
  jq -e '.model == "opus"' "$SETTINGS"
  jq -e '.env.FOO == "bar"' "$SETTINGS"
}

@test "--hooks preserves a foreign hook on the same event" {
  mkdir -p "$FAKE_HOME/.claude"
  cat > "$SETTINGS" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/other.sh"}]}]}}
JSON
  run "$REPO_ROOT/install.sh" --hooks
  [ "$status" -eq 0 ]
  jq -e '[.hooks.SessionStart[].hooks[].command] | any(. == "/opt/other.sh")' "$SETTINGS"
  jq -e '[.hooks.SessionStart[].hooks[].command] | any(contains("session-start.sh"))' "$SETTINGS"
}

@test "--hooks is idempotent" {
  mkdir -p "$FAKE_HOME/.claude"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  run jq '[.hooks.SessionStart[].hooks[] | select(.command | contains("session-start.sh"))] | length' "$SETTINGS"
  [ "$output" = "1" ]
}

@test "--no-hooks removes previously registered pursue hooks" {
  mkdir -p "$FAKE_HOME/.claude"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  run "$REPO_ROOT/install.sh" --no-hooks
  [ "$status" -eq 0 ]
  run jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("session-start.sh"))] | length' "$SETTINGS"
  [ "$output" = "0" ]
}

@test "--no-hooks leaves foreign hooks alone" {
  mkdir -p "$FAKE_HOME/.claude"
  cat > "$SETTINGS" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/other.sh"}]}]}}
JSON
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  "$REPO_ROOT/install.sh" --no-hooks >/dev/null
  jq -e '[.hooks.SessionStart[].hooks[].command] | any(. == "/opt/other.sh")' "$SETTINGS"
}

@test "--hooks --dry-run writes nothing" {
  mkdir -p "$FAKE_HOME/.claude"
  run "$REPO_ROOT/install.sh" --hooks --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$SETTINGS" ]
  [[ "$output" == *"plan:"* ]]
}

@test "--hooks writes valid JSON" {
  mkdir -p "$FAKE_HOME/.claude"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  run jq -e . "$SETTINGS"
  [ "$status" -eq 0 ]
}

# Symlinking a harness config into a dotfiles repo (stow, chezmoi) is
# common.  Replacing the link with a regular file detaches the config from
# its source of truth, and the next `stow` / `chezmoi apply` silently
# reverts the hook registration — back to hooks registered but not running,
# with no signal.
@test "--hooks writes through a symlinked settings.json" {
  mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/dotfiles"
  printf '{"model":"opus"}' > "$FAKE_HOME/dotfiles/settings.json"
  ln -s "$FAKE_HOME/dotfiles/settings.json" "$SETTINGS"

  run "$REPO_ROOT/install.sh" --hooks
  [ "$status" -eq 0 ]
  [ -L "$SETTINGS" ]
  [ "$(readlink "$SETTINGS")" = "$FAKE_HOME/dotfiles/settings.json" ]
  jq -e '.model == "opus"' "$FAKE_HOME/dotfiles/settings.json"
  jq -e '.hooks.SessionStart[0].hooks[0].command | contains("session-start.sh")' \
    "$FAKE_HOME/dotfiles/settings.json"
  [ "$(find "$FAKE_HOME/.claude" -name 'settings.json.??????' | wc -l)" -eq 0 ]
}

@test "--no-hooks writes through a symlinked settings.json" {
  mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/dotfiles"
  printf '{"model":"opus"}' > "$FAKE_HOME/dotfiles/settings.json"
  ln -s "$FAKE_HOME/dotfiles/settings.json" "$SETTINGS"
  "$REPO_ROOT/install.sh" --hooks >/dev/null

  run "$REPO_ROOT/install.sh" --no-hooks
  [ "$status" -eq 0 ]
  [ -L "$SETTINGS" ]
  [ "$(readlink "$SETTINGS")" = "$FAKE_HOME/dotfiles/settings.json" ]
  jq -e '.model == "opus"' "$FAKE_HOME/dotfiles/settings.json"
  run jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("session-start.sh"))] | length' \
    "$FAKE_HOME/dotfiles/settings.json"
  [ "$output" = "0" ]
}

@test "--hooks and --no-hooks write through a symlinked codex hooks.json" {
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/dotfiles"
  hj="$FAKE_HOME/.codex/hooks.json"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/mine.sh"}]}]}}' \
    > "$FAKE_HOME/dotfiles/hooks.json"
  ln -s "$FAKE_HOME/dotfiles/hooks.json" "$hj"

  "$REPO_ROOT/install.sh" --hooks >/dev/null
  [ -L "$hj" ]
  jq -e '[.hooks.SessionStart[].hooks[].command] | any(contains("session-start.sh"))' \
    "$FAKE_HOME/dotfiles/hooks.json"

  "$REPO_ROOT/install.sh" --no-hooks >/dev/null
  [ -L "$hj" ]
  [ "$(readlink "$hj")" = "$FAKE_HOME/dotfiles/hooks.json" ]
  jq -e '[.hooks.SessionStart[].hooks[].command] | any(. == "/opt/mine.sh")' \
    "$FAKE_HOME/dotfiles/hooks.json"
}

@test "--hooks registers hooks for codex in hooks.json" {
  mkdir -p "$FAKE_HOME/.codex"
  run "$REPO_ROOT/install.sh" --hooks
  [ "$status" -eq 0 ]
  hj="$FAKE_HOME/.codex/hooks.json"
  [ -f "$hj" ]
  jq -e '.hooks.SessionStart[0].hooks[0].command | contains("session-start.sh")' "$hj"
  jq -e '.hooks.PreCompact[0].hooks[0].command | contains("pre-compact.sh")' "$hj"
}

@test "--hooks enables the codex hooks feature" {
  mkdir -p "$FAKE_HOME/.codex"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  grep -q '^hooks = true' "$FAKE_HOME/.codex/config.toml"
  grep -q '^\[features\]' "$FAKE_HOME/.codex/config.toml"
}

@test "--hooks does not duplicate an existing features.hooks setting" {
  mkdir -p "$FAKE_HOME/.codex"
  printf '[features]\nhooks = true\n' > "$FAKE_HOME/.codex/config.toml"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  [ "$(grep -c '^\[features\]' "$FAKE_HOME/.codex/config.toml")" -eq 1 ]
}

@test "--hooks never writes a trusted_hash" {
  mkdir -p "$FAKE_HOME/.codex"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  ! grep -q 'trusted_hash' "$FAKE_HOME/.codex/hooks.json"
  ! grep -q 'trusted_hash' "$FAKE_HOME/.codex/config.toml"
}

@test "--hooks tells the user to expect a codex trust prompt" {
  mkdir -p "$FAKE_HOME/.codex"
  run "$REPO_ROOT/install.sh" --hooks
  [[ "$output" == *"trust"* ]]
}

@test "--hooks preserves a foreign codex hook" {
  mkdir -p "$FAKE_HOME/.codex"
  cat > "$FAKE_HOME/.codex/hooks.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/mine.sh","timeout":10}]}]}}
JSON
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  jq -e '[.hooks.SessionStart[].hooks[].command] | any(. == "/opt/mine.sh")' "$FAKE_HOME/.codex/hooks.json"
}

@test "--hooks is idempotent for codex" {
  mkdir -p "$FAKE_HOME/.codex"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  run jq '[.hooks.SessionStart[].hooks[] | select(.command | contains("session-start.sh"))] | length' \
    "$FAKE_HOME/.codex/hooks.json"
  [ "$output" = "1" ]
}

@test "--no-hooks removes codex entries" {
  mkdir -p "$FAKE_HOME/.codex"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  "$REPO_ROOT/install.sh" --no-hooks >/dev/null
  run jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("session-start.sh"))] | length' \
    "$FAKE_HOME/.codex/hooks.json"
  [ "$output" = "0" ]
}

@test "--hooks enables the codex feature even when hooks = true exists under another section" {
  mkdir -p "$FAKE_HOME/.codex"
  printf '[some.other]\nhooks = true\n' > "$FAKE_HOME/.codex/config.toml"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  grep -q '^\[features\]' "$FAKE_HOME/.codex/config.toml"
  run awk '/^\[features\]/{f=1;next} /^\[/{f=0} f&&/^hooks[[:space:]]*=[[:space:]]*true/{print "yes"}' \
    "$FAKE_HOME/.codex/config.toml"
  [ "$output" = "yes" ]
}

@test "--hooks does not append [features] when a top-level features.hooks key exists" {
  mkdir -p "$FAKE_HOME/.codex"
  printf 'features.hooks = true\n' > "$FAKE_HOME/.codex/config.toml"
  "$REPO_ROOT/install.sh" --hooks >/dev/null
  [ "$(grep -c '^\[features\]' "$FAKE_HOME/.codex/config.toml")" -eq 0 ]
}

# A [features] header may carry interior whitespace and still be the same
# table; appending a second one makes the file unparseable ("Cannot declare
# ('features',) twice").
@test "--hooks leaves a spaced [ features ] header alone and keeps the file parseable" {
  mkdir -p "$FAKE_HOME/.codex"
  printf '[ features ]\nhooks = true\n' > "$FAKE_HOME/.codex/config.toml"
  before="$(cat "$FAKE_HOME/.codex/config.toml")"
  run "$REPO_ROOT/install.sh" --hooks
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HOME/.codex/config.toml")" = "$before" ]
  python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); assert d['features']['hooks'] is True, d" \
    "$FAKE_HOME/.codex/config.toml"
}

# `features = { hooks = true }` is an inline table: the feature is already
# enabled, and appending a [features] header would redefine the key.
@test "--hooks leaves an inline features table alone and keeps the file parseable" {
  mkdir -p "$FAKE_HOME/.codex"
  printf 'features = { hooks = true }\nmodel = "gpt-5"\n' > "$FAKE_HOME/.codex/config.toml"
  before="$(cat "$FAKE_HOME/.codex/config.toml")"
  run "$REPO_ROOT/install.sh" --hooks
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HOME/.codex/config.toml")" = "$before" ]
  [[ "$output" != *"[features] exists"* ]]
  python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); assert d['features']['hooks'] is True, d; assert d['model']=='gpt-5', d" \
    "$FAKE_HOME/.codex/config.toml"
}

# An inline table that does NOT enable hooks must warn, never append.
@test "--hooks warns on an inline features table without hooks rather than redefining it" {
  mkdir -p "$FAKE_HOME/.codex"
  printf 'features = { other = true }\n' > "$FAKE_HOME/.codex/config.toml"
  before="$(cat "$FAKE_HOME/.codex/config.toml")"
  run "$REPO_ROOT/install.sh" --hooks
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HOME/.codex/config.toml")" = "$before" ]
  python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" \
    "$FAKE_HOME/.codex/config.toml"
}

@test "--hooks warns and does not rewrite when [features] exists without hooks" {
  mkdir -p "$FAKE_HOME/.codex"
  printf '[features]\nother = 1\n' > "$FAKE_HOME/.codex/config.toml"
  before="$(cat "$FAKE_HOME/.codex/config.toml")"
  run "$REPO_ROOT/install.sh" --hooks
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HOME/.codex/config.toml")" = "$before" ]
  [ "$(grep -c '^\[features\]' "$FAKE_HOME/.codex/config.toml")" -eq 1 ]
}
