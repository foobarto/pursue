#!/usr/bin/env python3
"""Validate the root SKILL.md frontmatter for this single-skill repo.

Emits `::error::` / `::warning::` annotations when run under GitHub Actions
and exits non-zero on any error.  Safe to run locally; annotations degrade
gracefully to plain stdout.

Checks:
  error   - missing SKILL.md
  error   - missing YAML frontmatter fence
  error   - unparseable YAML
  error   - missing required fields (name, description)
  error   - `name` is not a valid skill slug ([a-z][a-z0-9-]*)
  warn    - frontmatter `name` differs from the repo directory name
  warn    - no `allowed-tools` (Claude Code will prompt per invocation)
  warn    - description shorter than 30 chars (not a useful trigger)
  warn    - description longer than 1024 chars (truncated by Claude Code)
"""
from __future__ import annotations

import pathlib
import re
import sys

import yaml


REPO = pathlib.Path(__file__).resolve().parent.parent
SKILL_MD = REPO / "SKILL.md"
REQUIRED = {"name", "description"}
SLUG_RE = re.compile(r"^[a-z][a-z0-9-]*$")
DESC_MIN = 30
DESC_MAX = 1024  # Claude Code truncates descriptions beyond ~1024 chars.


def validate(skill_md: pathlib.Path) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []

    if not skill_md.exists():
        errors.append(f"{skill_md}: missing (expected SKILL.md at repo root)")
        return errors, warnings

    text = skill_md.read_text()
    if not text.startswith("---\n"):
        errors.append(f"{skill_md}: missing YAML frontmatter")
        return errors, warnings

    try:
        _, fm, _ = text.split("---\n", 2)
    except ValueError:
        errors.append(f"{skill_md}: unterminated YAML frontmatter")
        return errors, warnings

    try:
        meta = yaml.safe_load(fm)
    except yaml.YAMLError as e:
        errors.append(f"{skill_md}: frontmatter YAML error: {e}")
        return errors, warnings

    if not isinstance(meta, dict):
        errors.append(f"{skill_md}: frontmatter must be a mapping")
        return errors, warnings

    missing = REQUIRED - set(meta.keys())
    if missing:
        errors.append(f"{skill_md}: missing required field(s): {sorted(missing)}")

    name = meta.get("name")
    if isinstance(name, str) and not SLUG_RE.match(name):
        errors.append(
            f"{skill_md}: name {name!r} must match [a-z][a-z0-9-]*"
        )
    # The repo directory name is incidental for a single-skill repo (it can
    # be cloned anywhere), so a mismatch is a warning, not an error.
    if isinstance(name, str) and name != REPO.name:
        warnings.append(
            f"{skill_md}: frontmatter name {name!r} differs from repo dir "
            f"{REPO.name!r} (fine if cloned under a different dir name)"
        )

    if "allowed-tools" not in meta:
        warnings.append(
            f"{skill_md}: no allowed-tools "
            "(Claude Code will prompt per invocation)"
        )

    desc = meta.get("description", "")
    if not isinstance(desc, str):
        warnings.append(f"{skill_md}: description is not a string")
    else:
        if len(desc) < DESC_MIN:
            warnings.append(
                f"{skill_md}: description is short ({len(desc)} chars); "
                "should explain when to use the skill"
            )
        if len(desc) > DESC_MAX:
            warnings.append(
                f"{skill_md}: description is {len(desc)} chars; "
                f"Claude Code truncates at ~{DESC_MAX}"
            )

    return errors, warnings


def main() -> int:
    errors, warnings = validate(SKILL_MD)
    for w in warnings:
        print(f"::warning::{w}")
    for e in errors:
        print(f"::error::{e}")
    if errors:
        return 1
    print("OK — SKILL.md validated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
