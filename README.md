# pursue

A portable agent skill that pursues a stated goal **autonomously across
iterations** until acceptance criteria are met or you stop it. State
persists on disk under `.claude/goals/`, so a pursuit survives session
resets and context compaction — multi-day work picks up where it left off.

You drive it with a slash command:

```
/pursue <goal description>     # start a new pursuit in the current project
/pursue status                 # report progress against acceptance criteria
/pursue pause | resume         # suspend / restart the iteration loop
/pursue stop                   # end and archive the pursuit
```

The skill body lives in [`SKILL.md`](./SKILL.md) — that single file is the
whole skill.

## Not the built-in `/goal`

Claude Code ships a built-in `/goal <condition>`: a lightweight
stop-condition gate. After each turn the harness checks whether the
condition holds and auto-continues until it does. No state files, no
acceptance criteria, no iteration log.

`/pursue` is the heavyweight counterpart: structured
`goal.md` / `progress.md` / `blockers.md` state, a self-paced wake-up
loop, explicit pause/resume/stop lifecycle, and an honesty discipline for
recording evidence. Use the built-in for "keep going until X is true"
within one session; use `/pursue` for goal-driven work that must survive
resets.

## Install

`install.sh` links the skill into whichever AI coding CLIs it detects on
your system (Claude Code, Codex, Gemini CLI, GitHub Copilot CLI, Cursor):

```sh
# Install into every detected CLI
./install.sh

# Preview the plan without touching anything
./install.sh --list
./install.sh --dry-run

# Target one CLI
./install.sh --cli claude-code

# Install into a project-local dir so the skill rides with a repo
./install.sh --skill-dir .claude/skills/

# Copy instead of symlink (for harnesses that refuse symlinks)
./install.sh --copy
```

Because `SKILL.md` lives at the repo root, the installer links the repo
directory itself in as the skill (`~/.claude/skills/pursue/`). The CLI
reads `SKILL.md` and ignores the sibling repo files. Equivalently, you can
just clone straight into your skills directory:

```sh
git clone https://github.com/foobarto/pursue ~/.claude/skills/pursue
```

`install.sh` refuses to overwrite a destination it didn't create; pass
`--force` to replace one, or remove it yourself first. See `--help` for
all flags.

## Requirements & assumptions

`/pursue` was written for **Claude Code** and leans on a few harness
features and conventions. It still runs without the optional pieces, but
it's at its best alongside them.

**Required (Claude Code harness):**

- **Slash-command skills** — `/pursue` is invoked as a skill.
- **A self-pacing wake-up mechanism** — the iteration loop reschedules
  itself with `ScheduleWakeup` (wrapped in `/loop /pursue continue`), so
  the pursuit advances on its own between your messages. A harness without
  scheduled self-continuation can only run `/pursue continue` manually.
- **Subagent dispatch** — iterations delegate wide reads / adversarial
  review to subagents (`Explore`, `general-purpose`, `Plan`). Optional but
  assumed in several steps.

**Assumed conventions (optional, recommended):**

The skill references a discipline-oriented `CLAUDE.md` of the kind used for
long-running autonomous agents. Specifically it expects, where available:

- a **journal** (`.claude/journal/YYYY-MM-DD.md`) and **decisions log**
  (`.claude/decisions/`) it appends to as it works;
- a **`STATE.md`** it reloads at the start of each iteration;
- an **off-limits paths** policy and a **per-action confirmation rule for
  destructive operations** — the loop pauses and asks rather than
  auto-approving anything destructive;
- a **`.claude/.gitignore`** it audits so sensitive output never lands in
  tracked state files.

If your project has no such `CLAUDE.md`, those touch-points degrade to
no-ops: the skill still self-manages `.claude/goals/`, records evidence,
and respects stop signals — you just don't get the journal/decisions
cross-linking. A reference setup for this style of agent is the kind of
general-agent `CLAUDE.md` that defines journal, decisions, off-limits, and
self-critique discipline.

## How it works

1. **Start** — `/pursue <description>` turns your goal into a `goal.md`
   with a one-paragraph statement, 3–7 **verifiable** acceptance criteria
   (each naming the evidence required), non-goals, and constraints. It then
   kicks off the loop.
2. **Iterate** — each `/pursue continue` is one unit of work: reload
   context, self-critique the current trajectory, pick the smallest action
   that produces evidence, execute, then append an honest entry to
   `progress.md` (including failed attempts). It re-checks every acceptance
   criterion and either schedules the next iteration or, when all criteria
   are met, flips to `awaiting-confirmation` and asks you to confirm.
3. **Finish** — only *you* mark a pursuit `done`; the loop never declares
   victory on its own. `/pursue stop` archives it.

### State layout

Per project, under `.claude/`:

```
.claude/goals/
  active              # slug of the active goal (one pursuit per project)
  <slug>/
    goal.md           # statement, acceptance criteria, non-goals, constraints
    progress.md       # append-only iteration log (evidence-bearing)
    blockers.md       # active blockers
    STATUS            # active | paused | awaiting-confirmation | done | stopped
  _archive/<slug>/    # stopped or done goals, kept for retros
```

## Development

- `python3 scripts/validate_skill.py` — frontmatter lint (matches CI).
- `bats tests/` — install-script integration tests.
- `shellcheck install.sh` — shell lint.

CI runs all three on every push and pull request. See
[CONTRIBUTING.md](./CONTRIBUTING.md).

## License

Apache-2.0. See [LICENSE](./LICENSE).
