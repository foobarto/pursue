#!/usr/bin/env bash
# Install (or preview) the `pursue` skill into every AI coding CLI
# detected on the current user's system.
#
# This is a single-skill repo: SKILL.md lives at the repo root, so the
# installer treats the repo directory itself as the skill payload and
# links it in as ~/.<cli>/skills/pursue (the "clone into your skills
# dir" model).  CLIs read SKILL.md and ignore the sibling repo files.
#
# Usage:
#   ./install.sh                    # install into every detected CLI
#   ./install.sh pursue             # same (the skill name is accepted)
#   ./install.sh --list             # list what would be installed where, exit
#   ./install.sh --dry-run          # show every action without performing it
#   ./install.sh --copy             # use cp -r instead of symlinks
#   ./install.sh --cli claude-code  # only target the named CLI
#   ./install.sh --skill-dir PATH   # also install into an arbitrary dir
#                                   # (e.g. a project-local .claude/skills/)
#   ./install.sh --force            # overwrite pre-existing non-symlink destinations
#   ./install.sh --hooks            # also register the lifecycle hooks that
#                                   # enforce pursuits (Claude Code, Codex)
#   ./install.sh --no-hooks         # remove previously registered hooks
#   ./install.sh --version          # print repo commit/tag, exit
#
# Exit codes:
#   0  success (or dry-run completed)
#   1  no CLIs detected
#   2  unknown skill or CLI argument
#   3  filesystem error (couldn't create directory, symlink, etc.)
#   4  destination exists as a regular file/dir and --force was not passed

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_md="$repo_root/SKILL.md"

# ---------------------------------------------------------------------------
# CLI registry: <cli-name> <parent-dir> <skill-subdir> <entrypoint-filename>
#
# parent-dir        must exist for the CLI to be considered "installed"
# skill-subdir      the subdirectory under parent-dir where per-skill dirs live
# entrypoint        the per-skill file the CLI loads inside the skill dir
#
# Gemini is special: it needs a JSON manifest and a GEMINI.md context file
# rather than a single SKILL.md, so we generate those from the skill instead
# of symlinking. See install_gemini() below.
#
# Adding a standard CLI = one line per array here.
# ---------------------------------------------------------------------------
declare -a CLI_NAMES=(
  "claude-code"
  "codex"
  "gemini"
  "copilot"
  "cursor"
)
declare -A CLI_PARENT=(
  ["claude-code"]="$HOME/.claude"
  ["codex"]="$HOME/.codex"
  ["gemini"]="$HOME/.gemini"
  ["copilot"]="$HOME/.copilot"
  ["cursor"]="$HOME/.cursor"
)
declare -A CLI_SUBDIR=(
  ["claude-code"]="skills"
  ["codex"]="skills"
  ["gemini"]="extensions"
  ["copilot"]="skills"
  ["cursor"]="skills"
)
declare -A CLI_ENTRYPOINT=(
  ["claude-code"]="SKILL.md"
  ["codex"]="SKILL.md"
  ["gemini"]="gemini-extension.json"
  ["copilot"]="SKILL.md"
  ["cursor"]="SKILL.md"
)

# ---------------------------------------------------------------------------
# Frontmatter helpers (also used to derive the skill name and Gemini manifest)
# ---------------------------------------------------------------------------

# Parse a scalar field from SKILL.md YAML frontmatter.  We do this in awk
# rather than pulling in yq as a hard dep.  Handles quoted and unquoted
# scalars; does NOT handle block-style values (|, >).
read_frontmatter_field() {
  local file="$1" field="$2"
  awk -v f="$field" '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (in_fm) exit
      in_fm = 1; seen = 1; next
    }
    in_fm && $0 ~ "^[[:space:]]*"f"[[:space:]]*:" {
      sub("^[[:space:]]*"f"[[:space:]]*:[[:space:]]*", "", $0)
      gsub(/^["'\'']|["'\'']$/, "", $0)
      print
      exit
    }
    END { if (!seen) exit 1 }
  ' "$file"
}

# The skill name drives every install path. Prefer the frontmatter `name`,
# fall back to the repo directory basename.
skill_name="$(read_frontmatter_field "$skill_md" name 2>/dev/null || true)"
[[ -z "$skill_name" ]] && skill_name="$(basename "$repo_root")"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
dry_run=0
do_list=0
do_version=0
use_copy=0
force=0
do_hooks=0
undo_hooks=0
target_cli=""
declare -a skill_dirs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  dry_run=1; shift ;;
    --list)     do_list=1; shift ;;
    --copy)     use_copy=1; shift ;;
    --force)    force=1; shift ;;
    --hooks)    do_hooks=1; shift ;;
    --no-hooks) undo_hooks=1; shift ;;
    --version)  do_version=1; shift ;;
    --cli)      target_cli="${2:-}"; shift 2 ;;
    --skill-dir)
      if [[ -z "${2:-}" ]]; then
        echo "error: --skill-dir requires a path argument" >&2
        exit 2
      fi
      skill_dirs+=("$2")
      shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --*)
      echo "error: unknown flag: $1" >&2
      exit 2 ;;
    *)
      # The only valid positional is the skill's own name. Anything else is
      # a typo for a skill this repo doesn't ship.
      if [[ "$1" != "$skill_name" ]]; then
        echo "error: unknown skill: $1 (this repo only ships '$skill_name')" >&2
        exit 2
      fi
      shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Version reporting
# ---------------------------------------------------------------------------
repo_version() {
  if ! command -v git >/dev/null 2>&1 || ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "unknown (not a git checkout)"
    return
  fi
  local describe sha dirty
  sha=$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo "?")
  describe=$(git -C "$repo_root" describe --tags --always --dirty 2>/dev/null || echo "$sha")
  dirty=""
  if ! git -C "$repo_root" diff --quiet 2>/dev/null || ! git -C "$repo_root" diff --cached --quiet 2>/dev/null; then
    dirty=" (dirty)"
  fi
  echo "$describe$dirty"
}

if (( do_version )); then
  echo "foobarto/pursue $(repo_version)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Sanity: the skill payload must exist
# ---------------------------------------------------------------------------
if [[ ! -f "$skill_md" ]]; then
  echo "error: $skill_md not found (run from the repo root)" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Discover installed CLIs
# ---------------------------------------------------------------------------
declare -a detected_clis=()
for cli in "${CLI_NAMES[@]}"; do
  parent="${CLI_PARENT[$cli]}"
  if [[ -d "$parent" ]]; then
    detected_clis+=("$cli")
  fi
done

if [[ -n "$target_cli" ]]; then
  if [[ -z "${CLI_PARENT[$target_cli]:-}" ]]; then
    echo "error: unknown CLI: $target_cli" >&2
    echo "available: ${CLI_NAMES[*]}" >&2
    exit 2
  fi
  detected_clis=("$target_cli")
fi

if (( ${#detected_clis[@]} == 0 && ${#skill_dirs[@]} == 0 )); then
  echo "error: no supported CLIs detected on this system." >&2
  echo "checked: ${CLI_NAMES[*]}" >&2
  echo "(pass --skill-dir PATH to target an arbitrary directory)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# List mode: print the plan and exit
# ---------------------------------------------------------------------------
if (( do_list )); then
  echo "Repo:          $repo_root"
  echo "Version:       $(repo_version)"
  echo "Skill:         $skill_name"
  echo "CLIs detected: ${detected_clis[*]}"
  echo ""
  echo "Plan:"
  for cli in "${detected_clis[@]}"; do
    parent="${CLI_PARENT[$cli]}"
    subdir="${CLI_SUBDIR[$cli]}"
    entry="${CLI_ENTRYPOINT[$cli]}"
    echo "  $cli: $parent/$subdir/$skill_name/ (entrypoint: $entry)"
  done
  for extra in "${skill_dirs[@]}"; do
    echo "  --skill-dir: $extra/$skill_name/ (entrypoint: SKILL.md)"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# Install helpers
# ---------------------------------------------------------------------------

# JSON-escape a string for embedding in a double-quoted JSON scalar.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Copy the repo into a destination, then drop the repo plumbing that has no
# business living inside a CLI skill dir.  Used by --copy mode.
copy_payload() {
  local dest="$1"
  cp -r "$repo_root" "$dest"
  rm -rf "$dest/.git"
  repo_version > "$dest/.foobarto-skills"
}

# Check whether a destination is "ours": a symlink pointing at this repo, or
# a copy we previously stamped with provenance.  Returns 0 if safe to
# replace, 1 if it's something the user created and we must not clobber.
dest_is_ours() {
  local dest="$1"
  if [[ -L "$dest" ]]; then
    local target
    target="$(readlink "$dest")"
    case "$target" in
      "$repo_root"/*|"$repo_root") return 0 ;;
      *) return 1 ;;
    esac
  fi
  if [[ -f "$dest/.foobarto-skills" ]]; then
    return 0
  fi
  return 1
}

# Remove a destination (file, dir, or symlink) after provenance check.
remove_dest() {
  local dest="$1" kind="$2"
  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    return 0
  fi
  if dest_is_ours "$dest"; then
    rm -rf "$dest"
    return 0
  fi
  if (( force )); then
    echo "warn: $kind $dest exists and is not ours — removing due to --force" >&2
    rm -rf "$dest"
    return 0
  fi
  echo "error: $kind $dest already exists and was not created by this installer" >&2
  echo "       pass --force to overwrite, or remove it manually" >&2
  exit 4
}

# ---------------------------------------------------------------------------
# Standard install (Claude Code, Codex, Copilot, Cursor): link the repo root
# in as the skill dir so SKILL.md (and any future sibling assets) are picked
# up by the CLI.
# ---------------------------------------------------------------------------
install_standard() {
  local cli="$1"
  local parent="${CLI_PARENT[$cli]}"
  local subdir="${CLI_SUBDIR[$cli]}"
  local dest_parent="$parent/$subdir"
  local dest_dir="$dest_parent/$skill_name"

  if [[ -L "$dest_dir" ]]; then
    local existing
    existing="$(readlink "$dest_dir")"
    if [[ "$existing" == "$repo_root" ]]; then
      echo "ok:   $cli/$skill_name already linked"
      return 0
    fi
  fi

  if (( dry_run )); then
    if (( use_copy )); then
      echo "plan: copy $repo_root → $dest_dir"
    else
      echo "plan: symlink $repo_root → $dest_dir"
    fi
    return 0
  fi

  mkdir -p "$dest_parent" || { echo "error: mkdir $dest_parent" >&2; exit 3; }
  remove_dest "$dest_dir" "directory"

  if (( use_copy )); then
    copy_payload "$dest_dir"
  else
    ln -s "$repo_root" "$dest_dir"
  fi

  echo "done: $cli/$skill_name -> $dest_dir"
}

# ---------------------------------------------------------------------------
# Gemini install: generate a gemini-extension.json manifest plus a GEMINI.md
# context file pointing at SKILL.md.  Gemini CLI expects:
#
#   ~/.gemini/extensions/<name>/gemini-extension.json   (manifest)
#   ~/.gemini/extensions/<name>/GEMINI.md               (context body)
#
# Ref: https://github.com/google-gemini/gemini-cli/blob/main/docs/extensions/reference.md
# ---------------------------------------------------------------------------
install_gemini() {
  local parent="${CLI_PARENT[gemini]}"
  local dest_parent="$parent/extensions"
  local dest_dir="$dest_parent/$skill_name"

  local name desc version
  name="$(read_frontmatter_field "$skill_md" name || true)"
  desc="$(read_frontmatter_field "$skill_md" description || true)"
  version="$(repo_version)"
  [[ -z "$name" ]] && name="$skill_name"
  [[ -z "$desc" ]] && desc="Skill: $skill_name"

  if [[ -f "$dest_dir/.foobarto-skills" && -L "$dest_dir/GEMINI.md" ]] \
     && [[ "$(cat "$dest_dir/.foobarto-skills")" == "$version" ]] \
     && [[ "$(readlink "$dest_dir/GEMINI.md")" == "$skill_md" ]]; then
    echo "ok:   gemini/$skill_name already installed ($version)"
    return 0
  fi

  if (( dry_run )); then
    echo "plan: write gemini manifest $dest_dir/gemini-extension.json"
    echo "plan: symlink GEMINI.md → $skill_md"
    return 0
  fi

  mkdir -p "$dest_parent" || { echo "error: mkdir $dest_parent" >&2; exit 3; }
  remove_dest "$dest_dir" "directory"
  mkdir -p "$dest_dir" || { echo "error: mkdir $dest_dir" >&2; exit 3; }

  cat > "$dest_dir/gemini-extension.json" <<EOF
{
  "name": "$(json_escape "$name")",
  "version": "$(json_escape "$version")",
  "description": "$(json_escape "$desc")",
  "contextFileName": "GEMINI.md"
}
EOF

  if (( use_copy )); then
    cp "$skill_md" "$dest_dir/GEMINI.md"
  else
    ln -s "$skill_md" "$dest_dir/GEMINI.md"
  fi

  echo "$version" > "$dest_dir/.foobarto-skills"

  echo "done: gemini/$skill_name -> $dest_dir"
}

# ---------------------------------------------------------------------------
# --skill-dir install: drop the skill into a caller-supplied directory
# (e.g. a project-local `.claude/skills/`).  Claude Code convention: one
# subdir per skill with SKILL.md inside.
# ---------------------------------------------------------------------------
install_skill_dir() {
  local parent="$1"

  # Expand a literal leading ~ if a caller passed one as a quoted token.
  # shellcheck disable=SC2088  # matching a literal tilde token, not expanding one
  case "$parent" in
    "~"|"~/"*) parent="$HOME${parent#\~}" ;;
  esac
  local dest_dir="$parent/$skill_name"

  if [[ -L "$dest_dir" ]]; then
    local existing
    existing="$(readlink "$dest_dir")"
    if [[ "$existing" == "$repo_root" ]]; then
      echo "ok:   skill-dir/$skill_name already linked ($parent)"
      return 0
    fi
  fi

  if (( dry_run )); then
    if (( use_copy )); then
      echo "plan: copy $repo_root → $dest_dir"
    else
      echo "plan: symlink $repo_root → $dest_dir"
    fi
    return 0
  fi

  mkdir -p "$parent" || { echo "error: mkdir $parent" >&2; exit 3; }
  remove_dest "$dest_dir" "directory"

  if (( use_copy )); then
    copy_payload "$dest_dir"
  else
    ln -s "$repo_root" "$dest_dir"
  fi

  echo "done: skill-dir/$skill_name -> $dest_dir"
}

# ---------------------------------------------------------------------------
# Lifecycle hooks (EP-0001)
#
# Claude Code and Codex accept the same hook scripts; only the config file
# differs.  Both are keyed on the absolute script path, which is also how we
# recognise our own entries on re-install and on --no-hooks.  Nothing else in
# either config is touched.
# ---------------------------------------------------------------------------

# Emit "<Event> <absolute-script-path>" per registered hook.
pursue_hook_entries() {
  printf '%s %s\n' SessionStart "$repo_root/hooks/session-start.sh"
  printf '%s %s\n' PreCompact  "$repo_root/hooks/pre-compact.sh"
}

require_jq_for_hooks() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: --hooks requires jq (the hooks parse JSON payloads)" >&2
    echo "       install jq, or re-run without --hooks" >&2
    exit 3
  fi
}

# Merge our entries into ~/.claude/settings.json, preserving every other key
# and every foreign hook.
install_hooks_claude() {
  local settings="${CLI_PARENT[claude-code]}/settings.json"
  local event script tmp

  if (( dry_run )); then
    while read -r event script; do
      echo "plan: register $event -> $script in $settings"
    done < <(pursue_hook_entries)
    return 0
  fi

  mkdir -p "$(dirname "$settings")" || { echo "error: mkdir $(dirname "$settings")" >&2; exit 3; }
  [[ -f "$settings" ]] || echo '{}' > "$settings"

  while read -r event script; do
    tmp="$(mktemp)"
    jq --arg e "$event" --arg c "$script" '
      .hooks //= {}
      | .hooks[$e] //= []
      # Drop any previous registration of this exact script, then append once.
      | .hooks[$e] = (
          [ .hooks[$e][]
            | .hooks = [ .hooks[]? | select(.command != $c) ]
            | select((.hooks | length) > 0)
          ]
          + [ { hooks: [ { type: "command", command: $c, timeout: 10 } ] } ]
        )
    ' "$settings" > "$tmp" || { echo "error: failed to update $settings" >&2; rm -f "$tmp"; exit 3; }
    mv "$tmp" "$settings"
  done < <(pursue_hook_entries)

  echo "done: claude-code hooks -> $settings"
}

# Remove only our entries from ~/.claude/settings.json.
uninstall_hooks_claude() {
  local settings="${CLI_PARENT[claude-code]}/settings.json"
  local event script tmp
  [[ -f "$settings" ]] || return 0

  if (( dry_run )); then
    echo "plan: remove pursue hooks from $settings"
    return 0
  fi

  while read -r event script; do
    tmp="$(mktemp)"
    jq --arg e "$event" --arg c "$script" '
      if (.hooks[$e]? | type) == "array" then
        .hooks[$e] = [ .hooks[$e][]
          | .hooks = [ .hooks[]? | select(.command != $c) ]
          | select((.hooks | length) > 0) ]
      else . end
    ' "$settings" > "$tmp" || { rm -f "$tmp"; exit 3; }
    mv "$tmp" "$settings"
  done < <(pursue_hook_entries)

  echo "done: removed claude-code hooks from $settings"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
for cli in "${detected_clis[@]}"; do
  if [[ "$cli" == "gemini" ]]; then
    install_gemini
  else
    install_standard "$cli"
  fi
done

for extra in "${skill_dirs[@]}"; do
  install_skill_dir "$extra"
done

if (( do_hooks )); then
  require_jq_for_hooks
  for cli in "${detected_clis[@]}"; do
    case "$cli" in
      claude-code) install_hooks_claude ;;
    esac
  done
fi

if (( undo_hooks )); then
  require_jq_for_hooks
  for cli in "${detected_clis[@]}"; do
    case "$cli" in
      claude-code) uninstall_hooks_claude ;;
    esac
  done
fi

if (( dry_run )); then
  echo ""
  echo "(dry-run — no changes written)"
fi
