---
name: pursue
description: Pursue a stated goal autonomously across iterations until acceptance criteria are met or the operator stops. Use when the operator invokes `/pursue <description>` to start a long-running pursuit, or `/pursue status|pause|resume|stop|continue` to control an active pursuit. Persists state under `.claude/goals/` so multi-day work survives session resets. Distinct from the built-in `/goal` (a lightweight stop-condition gate) — this is the heavyweight structured-pursuit framework with acceptance criteria, an iteration loop, and per-project state files.
argument-hint: "<goal description> | status | pause | resume | stop | continue"
---

# Pursue

Take a goal from the operator and pursue it relentlessly until the acceptance criteria are met or the operator stops. State persists under `.claude/goals/` so the pursuit survives session resets and context compaction.

> **Not the built-in `/goal`.** Claude Code ships a built-in `/goal <condition>` that sets a lightweight stop-condition: after each turn the harness checks whether the condition is met and auto-continues until it is. That primitive has no state files, no acceptance criteria, no iteration log. This skill (`/pursue`) is the heavyweight version: structured `goal.md` / `progress.md` / `blockers.md`, a self-paced `ScheduleWakeup` loop, and explicit pause/resume/stop lifecycle. Use the built-in for "keep going until X is true" within a session; use `/pursue` for multi-day work that must survive resets.

## When to use this

The operator invokes `/pursue` with one of:

- `/pursue <description>` — start a new pursuit in the current project
- `/pursue status` — report the active pursuit's progress
- `/pursue pause` — suspend the iteration loop, keep state
- `/pursue resume` — restart the loop on the active pursuit
- `/pursue stop` — terminal end; archive the pursuit
- `/pursue continue` — internal: one iteration of the loop. Also used to manually pick up after a session restart with no args change.

Treat `/pursue` as the workflow itself — do NOT also invoke `brainstorming`, `writing-plans`, or other meta skills on top. They have their place inside an iteration when the next concrete action is "design X" or "spec Y", but this skill drives the outer loop.

## State layout

Per-project, under the project's `.claude/`:

```
.claude/goals/
  active                     # plain text: slug of the active goal, or empty file
  <slug>/
    goal.md                  # statement, acceptance criteria, non-goals, constraints
    progress.md              # append-only iteration log
    blockers.md              # active blockers; resolved ones move to progress.md
    STATUS                   # active | paused | awaiting-confirmation | done | stopped
  _archive/
    <slug>/                  # stopped or done goals, preserved for retros
```

Slug = `YYYY-MM-DD-<first-40-chars-lowercased-non-alnum-to-dash>`.

Only one active pursuit per project. Enforce via `.claude/goals/active`. (The state directory keeps the name `.claude/goals/` — the built-in `/goal` is transcript-based and never touches it, so there is no collision.)

## Approach

### `/pursue <description>` — start a new pursuit

1. **Check active pursuit.** If `.claude/goals/active` is non-empty, ask the operator: pause/stop the existing one, or queue this for later? Don't silently overwrite.
2. **Audit gitignore.** Per the operator's CLAUDE.md, ensure project root `.gitignore` lists `.claude/.gitignore` and `.claude/.gitignore` covers any sensitive patterns. Default: track `goal.md`, `progress.md`, `blockers.md`, `STATUS`, `active` — they're history worth preserving. Extend exclusions if the operator asks.
3. **Extract acceptance criteria.** Convert the description into:
   - **Statement** — one paragraph: what success looks like, why it matters.
   - **Acceptance criteria** — 3 to 7 concrete, verifiable checks. Each must name the *evidence* required (a passing test, a published artifact, a confirmed metric, an operator sign-off). "Improves performance" is not a criterion; "p95 request latency under 200ms measured over a 1h window" is.
   - **Non-goals** — explicitly out of scope.
   - **Constraints** — deadlines, budget, off-limits paths, dependencies.
   If the description is too vague to extract verifiable criteria, ask **one** clarifying question (per CLAUDE.md: one good question, not a list), then proceed.
4. **Write `goal.md`** using the template below. Set `STATUS=active`. Write the slug to `.claude/goals/active`. Append a journal entry referencing the new goal.
5. **Kick off the loop.** Invoke `/loop /pursue continue` (no interval — self-paced via `ScheduleWakeup`). The first iteration starts immediately.

### `/pursue continue` — one iteration

This is the loop body. Each call is a complete unit of work, recorded with evidence, then either schedules the next or exits.

1. **Pre-flight.**
   - Read `STATUS`. If `paused`, `stopped`, `done`, or `awaiting-confirmation` → exit without scheduling. (For `awaiting-confirmation`, also surface the pending confirmation to the operator if it hasn't been surfaced this session.)
   - **Scan recent operator messages** in the conversation for stop/halt/pause/wait signals. If found, treat as `/pursue pause` and exit. Stop signals override everything below.
2. **Reload context.** Read `goal.md` (full), `blockers.md` (full), the last 10 entries of `progress.md`, the project's `.claude/STATE.md` and the most recent journal entry. Same discipline as session-start in the operator's CLAUDE.md — don't redo settled work, don't repeat approaches the journal says hit a wall.
3. **Self-critique** (CLAUDE.md discipline). Before picking the next action, write one paragraph in scratch on *why the current trajectory might be wrong*. Concretely, not academically. If the argument is strong, change direction. If `progress.md` shows the same approach failing 2+ times, switch perspective per the "more different, not more same" rule — re-read the original goal, switch level, look for what was skipped, ask one good clarifying question. Don't iterate variations of a wall.
4. **Pick the next concrete action.** Smallest unit that produces evidence. Examples: run a specific test, draft section X of artifact Y, dispatch an `Explore` subagent for codebase mapping, write a probe script, ask the operator one specific question. Not "investigate" — name the artifact you'll produce.
5. **Execute.** Use the tools available. Dispatch subagents (`Explore`, `general-purpose`, `Plan`) when the action would otherwise dump tens of files into context, or needs adversarial review (per the CLAUDE.md *Delegating to subagents* section). Brief them properly — they haven't seen this conversation.
6. **Record outcome.** Append to `progress.md` (template below). Include real evidence: paths, commands, command output, diffs, links. Failed attempts go in too — the journal is honest. No theater entries.
7. **Update `blockers.md`** if a new blocker appeared or an old one resolved. Resolved blockers move to `progress.md` as a final entry on that blocker.
8. **Re-evaluate acceptance criteria.** For each criterion, classify as `met | not-met | uncertain` with a one-line evidence reference. If all are `met`:
   - Set `STATUS=awaiting-confirmation`.
   - Write a final summary block at the top of `progress.md`: each criterion + its evidence path.
   - Surface to the operator: *"Pursuit `<slug>` looks complete — see `.claude/goals/<slug>/progress.md`. Confirm to mark done, or tell me what's missing."*
   - Exit without rescheduling. Operator confirmation flips `STATUS=done`.
9. **Otherwise, schedule the next iteration** via `ScheduleWakeup`:
   - **Local action ready to run:** `delaySeconds: 60–270` (cache stays warm).
   - **Waiting on external signal** (CI run, build, external answer that may arrive minutes later): `delaySeconds: 1200–3600`.
   - **Don't pick 300** — see the tool docs; worst-of-both. Stay <270 or commit to ≥1200.
   - `prompt: "/loop /pursue continue"` (preserves the loop wrapper so the next firing self-paces too).
   - `reason`: one specific sentence on what the next iteration will do. "checking npm build output" beats "waiting".

### `/pursue status`

Read `goal.md`, `STATUS`, last 5 entries of `progress.md`, `blockers.md`. Report:

- Goal statement (one line)
- Current status
- Acceptance criteria with current met / not-met / uncertain classification per criterion
- Active blockers, if any
- Last 3 actions and their outcomes
- Next planned action
- Whether the loop is currently scheduled (was a `ScheduleWakeup` set on the previous iteration?)

### `/pursue pause`

Set `STATUS=paused`. Append to `progress.md` with reason ("operator paused at <ISO>"). Don't schedule a new iteration. Tell the operator the pursuit is paused and how to resume (`/pursue resume`).

### `/pursue resume`

Set `STATUS=active`. Schedule one iteration immediately via `ScheduleWakeup` with `delaySeconds: 60` and `prompt: "/loop /pursue continue"`. Tell the operator the loop is running again.

### `/pursue stop`

Confirm with the operator first: *"This will end pursuit `<slug>` permanently and move it to archive. Confirm?"* On confirmation:

- Set `STATUS=stopped`.
- Append a final entry to `progress.md` with the reason for stopping.
- Clear `.claude/goals/active`.
- `mv .claude/goals/<slug> .claude/goals/_archive/<slug>`.

## Honesty discipline

This is the highest-cost area to get wrong. The autonomous loop runs without operator supervision; the only check on quality is the discipline encoded in this skill.

- **Every `progress.md` entry has evidence.** Paths, commands, output, diffs, or a clear reason why evidence was unavailable. Never just "completed step X."
- **Failed attempts get logged honestly.** "Tried X, failed because Y" is more valuable than silently moving on. Future iterations need to know what was tried.
- **No premature `done`.** The skill terminates iterations on `awaiting-confirmation`, never on `done`. Only the operator flips `STATUS=done`.
- **Self-verify before claiming a criterion met.** Per CLAUDE.md *Verify before you claim done*: run the test, check the output, read the artifact you produced. If you can't verify cheaply, log the gap as `uncertain` rather than claiming `met`.
- **Operator messages override the loop instantly.** Pre-flight always checks recent messages for stop signals before doing more work.

## Pitfalls

- **Theater iterations** — entries that say "made progress" without verifiable evidence. Reject these in self-critique. Either name the artifact or rewrite the entry.
- **Same-approach loops** — iteration N+1 is a tweaked retry of N which already hit a wall. Switch perspective, switch level, or ask one question. Don't retry the same approach with different settings.
- **Cache thrash on wakeup** — `delaySeconds: 300` is the worst-of-both option. Stay ≤270 or commit to ≥1200.
- **Cross-pursuit contamination** — only one active pursuit per project. Don't try to run two simultaneously.
- **Sensitive output in tracked files** — `progress.md` is tracked. Credentials, internal stakeholder names, third-party data go in `.claude/notes/brainstorms/` (gitignored) and `progress.md` references the path. Re-audit `.claude/.gitignore` whenever a new sensitive pattern appears.
- **Skipping pre-flight stop scan** — the loop is autonomous; missed stop signals mean wasted work and operator frustration. Pre-flight scan is non-negotiable.
- **Auto-approving destructive actions** — never. The operator's CLAUDE.md requires per-action confirmation for destructive moves. The loop pauses (sets `STATUS=paused`) when the next action would be destructive and asks the operator.

## When NOT to use this

- **Single-shot tasks.** "Fix this typo", "explain this function", "write a 200-word summary" — just do them. The skill's overhead (state files, criteria, loop) is wasted on anything under an hour of focused work.
- **Tasks blocked entirely on external humans.** If the bottleneck is "waiting for X to reply" with no productive sub-tasks while waiting, use `/schedule` for a reminder rather than burning iterations on no-ops.
- **Exploratory ideation.** "Brainstorm what we could do about X" has no verifiable acceptance criteria. Use the brainstorming skill, capture findings, then start a pursuit *if* a concrete goal emerges.
- **"Keep going until X" within one session.** If the operator just wants the agentic loop to auto-continue until a simple condition holds, that's the built-in `/goal <condition>` — no state files, no overhead. Reach for `/pursue` only when the work needs structured criteria and must survive session resets.
- **Tasks where the operator wants close supervision.** If they want to review every step, the loop is overhead. Just work iteratively in-session.

## Templates

### `goal.md`

```markdown
# Goal: <one-line statement>

- **Started:** YYYY-MM-DD
- **Slug:** <slug>

## Statement

<One paragraph: what success looks like, why it matters, who benefits.>

## Acceptance criteria

- [ ] <criterion 1 — name the evidence required>
- [ ] <criterion 2>
- [ ] <criterion 3>

## Non-goals

- <explicit out-of-scope items>

## Constraints

- <deadlines, off-limits paths, budget, dependencies the loop must respect>
```

### `progress.md`

```markdown
# Progress

Append-only. Newest at the bottom. Don't edit past entries.

## YYYY-MM-DDTHH:MM — <one-line action title>

- **Tried:** <what was attempted>
- **Evidence:** <paths, commands, output snippets, diffs, links>
- **Outcome:** met | partial | failed | blocked
- **Learned:** <what changed in understanding of the goal or the path to it>
- **Next:** <next action OR blocker reference>
```

### `blockers.md`

```markdown
# Active blockers

## <blocker-slug>

- **Since:** YYYY-MM-DD
- **Description:** <what's blocking progress>
- **Tried:** <approaches attempted, with progress.md timestamps>
- **Need:** <what would unblock — operator decision, external answer, infrastructure change, etc.>
```

When a blocker resolves, append a final entry to `progress.md` describing the resolution, then remove the block from `blockers.md`.
