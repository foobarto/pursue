# Contributing

Thanks for considering a contribution. This repo ships one skill:
`pursue`, a self-contained instruction sheet various AI coding CLIs load
to gain a goal-pursuit capability. The skill *is* the root
[`SKILL.md`](./SKILL.md).

Report vulnerabilities through the repository Security tab or the
[account-wide security policy](https://github.com/foobarto/.github/blob/main/SECURITY.md),
not a public issue. Participation is subject to the account-wide
[Code of Conduct](https://github.com/foobarto/.github/blob/main/CODE_OF_CONDUCT.md).

## Editing the skill

The skill lives entirely in `SKILL.md`, with YAML frontmatter up top:

```yaml
---
name: pursue
description: >-
  When-to-use trigger description. Claude Code matches against this string
  to decide whether to invoke the skill, so lead with the user phrasing
  that should trigger it. Keep under 1024 chars; the tail is truncated.
argument-hint: "<goal description> | status | pause | resume | stop | continue"
---
```

Rules the lint enforces:

- `name` must be a valid slug (`[a-z][a-z0-9-]*`). It should normally equal
  the repo directory name (`pursue`); a mismatch is a warning, not an
  error, so the repo can be cloned under any directory name.
- `description` should be at least 30 chars and under 1024 chars. Lead with
  "when to use" language, not "what this does."
- `allowed-tools` is optional. `pursue` deliberately omits it — the loop
  needs broad tool access (file edits, Bash, scheduling, subagents), so
  pinning a list would only get in the way.

Write the body in plain Markdown: when to use, how it works, the per-mode
behavior, honesty discipline, pitfalls, and the state-file templates.

## Sibling assets

If the skill ever needs extra files beside `SKILL.md` (a `references/` dir,
helper `scripts/`, fixtures), add them at the repo root. `install.sh` links
the whole repo in as the skill directory, so anything you add is reachable
beside `SKILL.md` at skill-invocation time.

## Supporting a new CLI

Add one entry to each associative array at the top of `install.sh`:
`CLI_NAMES`, `CLI_PARENT`, `CLI_SUBDIR`, `CLI_ENTRYPOINT`. If the CLI needs
a generated manifest rather than a raw `SKILL.md` (as Gemini does), add a
dedicated `install_<cli>()` function modelled on `install_gemini()` and
dispatch to it from the main install loop.

## Checks

Run the same three checks CI runs before opening a PR:

```sh
python3 scripts/validate_skill.py   # frontmatter lint
shellcheck install.sh               # shell lint
bats tests/                         # install-script tests
```

## Releases

Cut a release by tagging `main` with a semver string:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Symlink installs point at the working tree, so `git pull && ./install.sh`
is enough to update. `./install.sh --version` prints the current tag.

## Commit style

- Prefix commits with a short type: `feat:`, `fix:`, `docs:`, `ci:`,
  `refactor:`, `test:`.
- Keep the subject line under 70 chars; put context in the body.
