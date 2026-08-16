---
ep: 0001
title: Hook-Enforced Pursuit
author: Bartosz Ptaszynski <bartosz@foobarto.me>
status: Accepted
type: Standards
created: 2026-08-16
see-also: ["stado EP-0062", "stado EP-0009", "stado EP-0051"]
history:
  - date: 2026-08-16
    status: Draft
    note: >
      Initial draft after reading the stado supervision corpus. D1 (hooks
      enforce, worker reviews) and D2 (Stop-block drives iteration) are
      operator-settled; the remaining decisions are drafted and unreviewed.
  - date: 2026-08-16
    status: Accepted
    note: >
      Accepted after operator review. D10 (verification commands declared in
      the contract) was settled during that review and records a deliberate
      divergence from EP-0062. Implementation has not started; this document
      is append-only from here — a decision that changes goes in a new EP.
---

> **Relationships:** modelled on [stado
> EP-0062](https://github.com/foobarto/stado/blob/main/docs/eps/0062-harness-enforced-supervised-work.md)
> (Harness-Enforced Supervised Work). Hook-surface context: [stado
> EP-0009](https://github.com/foobarto/stado/blob/main/docs/eps/0009-session-guardrails-and-hooks.md),
> [stado
> EP-0051](https://github.com/foobarto/stado/blob/main/docs/eps/0051-lua-lifecycle-hook-contract.md).

# EP-0001: Hook-Enforced Pursuit

## Problem

`/pursue` today is a single `SKILL.md` that instructs one model to own the
plan, the implementation, the evidence, the exception process, and the
definition of done. The skill is candid about the consequence:

> The autonomous loop runs without operator supervision; the only check on
> quality is the discipline encoded in this skill.

That is an empty enforcement slot. stado's EP-0062 states the failure directly:
prompting the worker to be disciplined is not reliable enforcement, because
*the same context pressure that causes the failure can also make it forget the
instruction*. Every rule in pursue's "Honesty discipline" section — no
premature `done`, log failed attempts, self-verify before claiming a criterion
met, scan for stop signals — is addressed to the component with the strongest
bias toward declaring victory, and is evaluated by that same component.

Three specific consequences:

1. **Completion is self-certified.** The worker decides whether its own
   evidence satisfies its own acceptance criteria.
2. **Continuation is self-scheduled.** `ScheduleWakeup`, wrapped in
   `/loop /pursue continue`, means the worker chooses whether the pursuit
   advances. A worker that concludes it is finished simply stops rescheduling.
3. **The loop is not portable.** `ScheduleWakeup` is a Claude Code primitive.
   `install.sh` targets five CLIs; on four of them pursue's iteration loop does
   not iterate.

Claude Code and Codex both expose lifecycle hooks that run **outside the
model's context**, in a separate process, whether or not the model cooperates.
That is the enforcement slot pursue is missing.

## Goals

- Move continuation and completion decisions out of the worker's context and
  into harness hooks.
- Keep the contract, plan position, and criterion evidence in files the worker
  is denied write access to, and re-inject them at session and compaction
  boundaries.
- Derive deterministic warning signals from observed tool-call facts, without
  asking a model to notice them.
- Require an **anchored** reviewer verdict before a pursuit may end, so
  skipping review is blocking rather than merely discouraged.
- Ship **one** hook implementation that serves both Claude Code and Codex.
- Degrade honestly, and visibly, on harnesses with no hook surface.

## Non-goals

- **Parity with stado.** Pursue is a Markdown skill plus shell hooks running
  inside third-party harnesses. It has no broker, no CAS, no WAL, no capability
  sandbox, no signed artifacts, no scheduling leases, and no attenuated child
  admission. It uses what Claude Code and Codex expose and cannot be an exact
  pair match for functionality stado builds into its own runtime. Every
  mechanism below is a reduced analogue, and is labelled as one.
- **A security boundary.** As EP-0062 says of supervise: this is a quality
  gate. It does not make hostile repository content safe, contain a malicious
  worker, protect secrets, or turn model agreement into authorization.
- **Spawning models from hook processes.** v1 hooks never invoke a provider.
- **Nested supervision.** The root worker stays accountable for its subagents.
- **Replacing the built-in `/goal`.** The existing distinction stands.

## Design

### Roles

Four roles, three of which pursue can actually separate:

| Role | Who | Can it mutate the repo? |
|---|---|---|
| Worker | the main session | yes |
| Detector | `PostToolUse` hook | no — writes only pursuit state |
| Watchdog / verifier | a worker-dispatched subagent | no — read-only tool profile |
| Operator | you | authority over the contract and `done` |

The detector is genuinely independent: it is a separate process reading the
harness's own record of what happened. The watchdog is *dispatched* by the
worker but its **absence is detectable**, because the `Stop` hook requires a
verdict artifact anchored to the current state before it will let a turn end.
The worker may decline to review; it may not decline to review *and* finish.

### State layout

State moves from `.claude/goals/` to `.agent/goals/`. `.claude/` is wrong once
Codex is a target, and it reconciles an existing discrepancy between the repo's
`SKILL.md` and the installed skill description.

```
.agent/goals/
  active                        # slug of the active pursuit, or empty
  <slug>/
    goal.md                     # the confirmed contract: statement, criteria,
                                #   non-goals, constraints, verification commands
    plan.json                   # ordered steps, active step, plan version
    progress.md                 # append-only, evidence-bearing
    blockers.md
    triggers.jsonl              # detector events, append-only
    verdicts/<anchor>.json      # reviewer verdicts, one per anchor
    inputs/<ordinal>.json       # captured operator input records
    completion-request.json     # present only when completion is claimed
    STATUS                      # active | paused | awaiting-confirmation | done | stopped
    integrity                   # hash chain over the above
  _archive/<slug>/
```

Criterion evidence (`goal.md` + `progress.md`) and ordered-plan progression
(`plan.json`) are **separate state**, per EP-0062. A criterion can gain
evidence without the plan advancing, and the stall detector depends on the
difference.

### The anchor

Every verdict binds the state it reviewed. The anchor is:

```
<tree-digest>:<plan-version>:<active-step>:<iteration>
```

`tree-digest` is `git rev-parse HEAD` combined with a hash of `git diff HEAD` —
cheap, side-effect-free, and sensitive to uncommitted work. Outside a git
repository the tree component degrades to a hash of `plan.json` +
`progress.md` size, and the EP records that as a known weakening.

This is the reduced analogue of stado's authenticated
`git:<tree-ref>@<commit>#turn-N-iteration-M` source pinning. It is not
authenticated — it is computed by the same machine the worker runs on — but it
is sufficient to tell a current verdict from a stale one.

### Hook contract

Codex 0.147.0 deliberately implements Claude Code's hook contract. This is not
inference from similar naming — Codex embeds JSON Schemas for each hook, and
the `reason` field in `stop.command.output` is documented as:

> Claude requires `reason` when `decision` is `block`; we enforce that semantic
> rule during output parsing rather than in the JSON schema.

Codex also honours `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PLUGIN_DATA`. The payload
carries the same fields in both harnesses (`session_id`, `transcript_path`,
`cwd`, `hook_event_name`, `tool_name`, `tool_input`, `tool_response`, `prompt`,
`trigger`, `stop_hook_active`), and the same output keys (`decision`,
`reason`, `continue`, `stopReason`, `systemMessage`, `suppressOutput`,
`hookSpecificOutput`, `additionalContext`, `permissionDecision`,
`permissionDecisionReason`).

Event coverage is close but not identical:

| Event | Claude Code | Codex 0.147.0 |
|---|---|---|
| `SessionStart` / `SessionEnd` | yes | yes |
| `UserPromptSubmit` | yes | yes |
| `PreToolUse` / `PostToolUse` | yes | yes |
| `Stop` / `SubagentStop` | yes | yes |
| `PreCompact` | yes | yes |
| `PostCompact` | no (use `SessionStart` with `source: compact`) | yes |
| `SubagentStart` | no | yes |
| `PermissionRequest` | no | yes |
| `Notification` | yes | no |

Pursue uses only the intersection. `PostCompact`, `SubagentStart`,
`PermissionRequest`, and `Notification` are out of scope for v1 precisely
because they are not portable.

Two harness differences constrain the design:

- **Codex restricts `PreToolUse` outputs.** It rejects `decision: "approve"`,
  `permissionDecision: "allow"`, `permissionDecision: "ask"`,
  `continue: false`, `stopReason`, and `suppressOutput` on that event, and
  requires a non-empty `permissionDecisionReason` alongside
  `permissionDecision: "deny"`. Pursue's `PreToolUse` hook therefore emits
  **only deny-with-reason or nothing** — which is all the design needs, and
  which happens to be valid on both harnesses.
- **Codex hook entries carry a `trusted_hash`.** Its hook config supports
  `matcher`, `hooks`, `enabled`, and `trusted_hash`, so the installer must
  compute and record that hash, and re-record it whenever a hook script
  changes. There is no Claude Code equivalent. Getting this wrong means hooks
  silently not running, which is the worst possible failure for this design —
  see Failure modes.

Config location:

| | Claude Code | Codex |
|---|---|---|
| Config | `~/.claude/settings.json`, `"hooks"` key | `~/.codex/hooks.json`, `"hooks"` key |
| Enable | always on | `[features] hooks = true` in `config.toml` |
| Integrity | none | `trusted_hash` per entry |

Therefore: **one set of POSIX shell scripts, two installer paths.** Scripts
live in `hooks/` in this repo and are referenced by absolute path from both
configs.

Per-event responsibilities:

**`SessionStart`** — read `.agent/goals/active`; if a pursuit is active, emit
the contract, the active plan step, open blockers, and the last N `progress.md`
entries via `hookSpecificOutput.additionalContext`. This is the reduced form of
"keep the promises somewhere forgetting cannot edit them". It is the single
highest-value hook: it is what makes a pursuit survive a session reset without
depending on the worker remembering to re-read its own state.

**`PreCompact`** — same payload as `SessionStart`, plus a flush of in-flight
iteration state to `progress.md` before context is discarded.

**`UserPromptSubmit`** — two jobs. First, a mechanical stop-signal scan
(stop / halt / pause / wait / hold): on a match, write `STATUS=paused` and
inject a note. This replaces pursue's current prose instruction to "scan recent
operator messages", which is exactly the kind of rule a loaded context drops.
Second, capture the prompt verbatim as an immutable record under `inputs/`, so
follow-up instructions issued mid-pursuit are not lost when the worker is
mid-iteration. A reduced form of EP-0062's immutable broker input.

**`PreToolUse`** — three denials, via
`hookSpecificOutput.permissionDecision: "deny"`:

1. Writes by the worker to `.agent/goals/<slug>/` (except `progress.md`,
   `blockers.md`, and `completion-request.json`, which are the worker's
   designated append surfaces). The contract, plan version, verdicts, and
   integrity chain are not worker-writable.
2. Edits outside the active plan step's declared scope, when the contract
   declares one. Reduced form of scope-drift enforcement.
3. Destructive actions, which set `STATUS=paused` and surface to the operator
   rather than proceeding. Pursue's existing rule, moved from prose into
   enforcement.

**`PostToolUse`** — the detectors. Runs on every tool result, computes facts,
and appends triggers to `triggers.jsonl`. See below.

**`Stop`** — the gate. Ordered checks:

1. `STATUS` is `paused`, `stopped`, or `done` → allow.
2. Iteration budget exhausted → allow, and emit a `systemMessage` explaining
   that the pursuit stopped on budget rather than on criteria.
3. An unconsumed trigger exists with no verdict at the current anchor →
   `decision: "block"`, reason: review required at `<anchor>`, naming the
   trigger.
4. A current verdict says `correct` → block, delivering the correction.
   A current verdict says `pause` or `stop` → write `STATUS=paused` and allow.
5. `completion-request.json` present and current → run the completion gate
   (below).
6. Any acceptance criterion unmet → block, naming the unmet criteria and the
   next concrete action from `plan.json`.
7. All criteria met and a current `approve` verdict exists → write
   `STATUS=awaiting-confirmation` and allow.

**`SubagentStop`** — validate the reviewer's output, bind it to the current
anchor, and write `verdicts/<anchor>.json`. A verdict that fails strict
decoding is discarded rather than coerced; a discarded verdict leaves the
trigger unconsumed, so the `Stop` gate will demand another review.

### Detectors

`PostToolUse` computes, per call: `tool_name`, a digest of `tool_input`, and a
fingerprint of any error in `tool_response`. From those:

- **`repeated_failure`** — same error fingerprint, N times.
- **`retry_thrash`** — same error fingerprint *and* same input digest.
- **`edit_revert_churn`** — a file edited back to a previously seen content
  hash.
- **`scope_growth`** — changed paths exceeding the active step's declared
  scope, or diff size crossing a threshold.
- **`verification_regression`** — a previously passing verify command now
  failing.
- **`progress_stall`** — **four completed turns with no plan movement.**

The stall detector is the one that requires care. Per EP-0062 D5, **activity
does not reset it.** New evidence, a changed tree, and more tool calls are
useful review context but do not prove the approved work advanced. The counter
resets only when `plan.json`'s active step changes or its completed-step count
increases. A busy loop in the wrong place is a stall.

### Verdicts and the stale-result policy

A verdict is `continue | correct | pause | stop | approve`, with a reason,
evidence references, and a bounded handoff (open concerns, hypotheses,
interventions attempted, missing evidence, suggested probes) carried to the
next reviewer instead of keeping a second long-lived conversation.

A verdict whose anchor is not the current anchor is **stale**, and staleness is
asymmetric, following EP-0062 D6:

- stale `continue` / `approve` → discarded;
- stale `correct` → delivered at the next boundary as explicitly labelled
  earlier-anchor advisory steering; it does not satisfy a pending trigger;
- stale `pause` / `stop` → the `Stop` gate blocks and demands a fresh review at
  the current anchor. If that review cannot be obtained, the pursuit pauses for
  the operator.

This keeps ordinary steering cheap while preventing an obsolete approval from
completing a pursuit, and preventing an obsolete stop from being silently
dropped.

### Contract before implementation

Pursue adopts stado's ordering: `/supervise` "begins by declining to begin".

`/pursue <description>` no longer starts work. It dispatches a fresh read-only
subagent to propose a baseline — statement, constraints, non-goals, acceptance
criteria with named evidence, an ordered plan with explicit done conditions,
**the verification commands** (D10), and risks — renders that proposal, and
waits for operator confirmation. Only on confirmation does it write `goal.md` and
`plan.json`, set `STATUS=active`, and admit the first worker turn.

The rationale is EP-0062's: in an ordinary agent session the first plausible
implementation becomes the unstated specification, and later ambiguity gets
resolved in favour of the code that already exists.

Confirmation selects a contract. It does not authorize destructive actions,
external effects, or anything else; those remain per-action operator decisions.

### Completion

Prose cannot complete a pursuit, and neither can ending a turn. The worker must
write `completion-request.json` naming the current anchor and linking evidence
to each criterion. The `Stop` gate then:

1. Runs the verification commands **declared in the contract** (D10), recording
   typed outcomes and digests. **No declared suite records as `no_suite` — an
   absence, never a pass.**
2. Requires an `approve` verdict at the current anchor from a reviewer dispatch
   **separate from the last watchdog**, over the same contract, tree, and
   evidence.
3. On approval, sets `STATUS=awaiting-confirmation`.

`done` is still only ever set by the operator. That rule predates this EP and
survives it unchanged.

### Iteration budget and runaway guard

A blocking `Stop` hook can produce an unbounded session, so two guards are
mandatory:

- **`stop_hook_active`.** When true, the current turn exists *because* a Stop
  hook blocked. Pursue does not use it to suppress blocking outright — that
  would cap every pursuit at one iteration — but records it, so hook-driven
  continuations are counted separately from operator-driven turns.
- **An explicit iteration budget** in the contract, decremented per hook-driven
  continuation. On exhaustion the gate allows the stop and reports that the
  pursuit ended on budget, not on criteria. Silence here would be
  indistinguishable from success, which is the failure this whole EP exists to
  prevent.

### Portability

| Harness | Hooks | Result |
|---|---|---|
| Claude Code | full | full enforcement, plus `ScheduleWakeup` for external waits |
| Codex | full | full enforcement; parks on external waits |
| Gemini CLI | none | skill only |
| Copilot CLI | none | skill only |
| Cursor | none | skill only |

On the last three, **pursue loses its teeth** and depends on the agent actually
following instructions — which is the pre-EP-0001 behaviour. This is a real
reduction in guarantees, not a cosmetic one, and the installer must say so at
install time rather than leaving the operator to infer it. `/pursue status`
reports whether enforcement is active on the current harness.

## Migration / rollout

1. **State relocation.** `.claude/goals/` → `.agent/goals/`. The skill migrates
   an existing pursuit on first run and leaves a pointer behind. Existing
   `goal.md` / `progress.md` / `blockers.md` / `STATUS` are format-compatible;
   `plan.json` is derived from the existing criteria on migration, with the
   active step unset until the next iteration.
2. **Hooks ship uninstalled.** `install.sh` gains `--hooks` / `--no-hooks`.
   Hook installation merges into existing configs rather than replacing them —
   both harnesses' configs commonly already contain unrelated hooks, and
   clobbering them would be unacceptable.
3. **`SKILL.md` rewrite.** The loop section changes from "schedule the next
   iteration" to "the gate decides"; the honesty-discipline section shrinks,
   because most of it becomes enforced rather than requested.
4. **Hookless harnesses** keep working with no change beyond the state path.

## Failure modes

- **Hook not installed, or harness has no hook surface.** Pursue degrades to
  prose-only. `/pursue status` reports enforcement as inactive; it must never
  imply guarantees it cannot deliver.
- **Hooks silently not running.** The worst failure for this design, because an
  unenforced pursuit is indistinguishable from an enforced one that never
  tripped a detector. Two known causes: a stale Codex `trusted_hash` after a
  hook script is edited, and `[features] hooks = false` in Codex config. Guard:
  every hook writes a heartbeat into `triggers.jsonl`, and `/pursue status`
  reports "no hook heartbeat since `<time>`" rather than assuming enforcement.
  The skill body must also self-check at `SessionStart` — if the contract was
  not injected by a hook, the worker knows it is running unenforced and says so.
- **Hook crashes or times out.** Both harnesses treat hook failure as
  non-fatal. A crashed `Stop` hook therefore *fails open* — the turn ends. This
  is the opposite of stado's fail-closed broker, and is an accepted limitation:
  hooks cannot be made mandatory from inside the harness. Hook errors are
  logged to `triggers.jsonl` so an unenforced pursuit is visible after the
  fact.
- **Worker edits its own state.** `PreToolUse` denies direct writes and the
  integrity chain detects tampering, but a worker with shell access can
  circumvent both. Enforcement is strong-advisory, not authoritative.
- **Reviewer is steered by repository content.** As EP-0062 notes, the reader
  is an attack surface. Read-only tooling limits the blast radius; it does not
  make the judgment trustworthy.
- **Blocked-forever pursuit.** Guarded by the iteration budget, and by the
  operator, whose stop signal is checked mechanically at `UserPromptSubmit`.
- **Anchor collision outside git.** The degraded anchor may fail to distinguish
  two states. Recorded as a known weakening; pursuits outside a repository get
  less staleness protection.
- **`no_suite` misread as success.** Explicitly prevented; recorded as absence
  and surfaced in the completion summary.

## Test strategy

- **Hook unit tests** over fixture payloads for both harnesses' JSON shapes,
  asserting the emitted decision for each `Stop`-gate branch.
- **Detector tests** with synthetic tool-call sequences: retry thrash,
  edit/revert churn, scope growth, and — most importantly — a busy-but-stalled
  sequence that must still trip `progress_stall`.
- **Stale-verdict tests** covering all three asymmetric outcomes.
- **Completion-gate tests** including `no_suite`, a failing suite, a stale
  approval, and an approval from the same reviewer as the last watchdog.
- **Installer tests** (`bats`, extending `tests/install.bats`) covering merge
  into a populated `settings.json` and a populated `hooks.json`, idempotency,
  `--no-hooks`, and **`trusted_hash` correctness** — including the regression
  where a hook script is edited and the recorded hash is not refreshed.
- **Enforcement-detection test.** With hooks deliberately disabled, `/pursue
  status` must report enforcement inactive rather than reporting a healthy
  pursuit.
- **End-to-end** on both harnesses: a pursuit whose worker attempts to finish
  early must be blocked, and the block must be visible in `progress.md`.

## Open questions

- **Does the reviewer dispatch belong in `SKILL.md` or in the block reason?**
  Emitting the reviewer brief from the `Stop` hook's reason string would make
  the review harder to skip and easier to keep current, at the cost of a large
  string in a shell script.
- **Cross-harness state compatibility.** If a pursuit is started under Claude
  Code and continued under Codex, transcript paths and session IDs differ.
  Probably fine — nothing durable should reference them — but untested.
- **Integrity chain strength.** A plain hash chain the worker can recompute
  detects accident, not intent. Whether to bother, or to state plainly that
  tampering is out of scope, is unresolved.

## Decision log

### D1. Hooks enforce, the worker reviews

- **Decided:** hooks own the deterministic, non-negotiable parts — detectors,
  the `Stop` gate, contract re-injection, scope denial. The semantic review is
  dispatched by the worker, but the `Stop` gate blocks when no verdict exists
  at the current anchor. No model is spawned by a hook process.
- **Alternatives:** (a) the hook spawns a headless watchdog via `claude -p` /
  `codex exec`; (b) the worker dispatches with no hook backstop.
- **Why:** (a) buys true independence but needs provider credentials in a hook
  environment, plus token and latency cost on every trigger — too heavy for v1.
  (b) is what pursue already does, and is the empty enforcement slot this EP
  exists to fill. The hybrid keeps the slot filled at the cost of one artifact
  check.

### D2. `Stop`-block drives iteration; `ScheduleWakeup` is for real waits

- **Decided:** in-session iteration is driven by the `Stop` hook blocking while
  criteria are unmet. `ScheduleWakeup` is retained only for genuine external
  waits, on Claude Code.
- **Alternatives:** keep `ScheduleWakeup` primary with the hook as a gate only;
  or drop `ScheduleWakeup` entirely.
- **Why:** `ScheduleWakeup` has the worker schedule itself, which is the
  ownership inversion EP-0062 is about, and it exists on one harness of five.
  A blocking `Stop` hook behaves identically on Claude Code and Codex. Keeping
  the timer for external waits avoids burning turns polling a CI run.

### D3. State moves to `.agent/goals/`

- **Decided:** pursuit state lives under `.agent/`, not `.claude/`.
- **Alternatives:** keep `.claude/goals/`; make the path per-harness.
- **Why:** `.claude/` is wrong once Codex is a target, per-harness paths would
  break a pursuit that changes harness, and it resolves an existing
  documentation discrepancy.

### D4. Contract before implementation

- **Decided:** `/pursue <description>` proposes a baseline and waits for
  operator confirmation before any work begins.
- **Alternatives:** keep extracting criteria and starting immediately.
- **Why:** EP-0062's argument holds — the first plausible implementation
  otherwise becomes the unstated specification. The cost is one confirmation.

### D5. Activity does not reset the stall detector

- **Decided:** only an active-step change or a completed-step increment resets
  `progress_stall`.
- **Alternatives:** reset on any tool call, tree change, or new evidence.
- **Why:** directly inherited from EP-0062 D5. A worker can be extremely busy
  in the wrong place; resetting on activity would make the detector agree with
  the worker's own sense of momentum, which is the bias being checked.

### D6. Stale verdicts are asymmetric

- **Decided:** discard stale approvals, deliver stale corrections as labelled
  advice, and re-review stale pause/stop.
- **Alternatives:** treat all stale verdicts identically (discard, or apply).
- **Why:** inherited from EP-0062 D6. Discarding everything makes a slow
  reviewer decorative; applying everything lets a judgment about an old state
  control a new one.

### D7. Completion needs an explicit request and a separate verifier

- **Decided:** completion requires `completion-request.json`, a verify-command
  run, and an `approve` verdict from a reviewer other than the last watchdog.
  `no_suite` is an absence.
- **Alternatives:** let the worker declare completion in `progress.md`; reuse
  the last watchdog.
- **Why:** the component with the greatest bias toward "done" should not own
  the bit that means done. Reusing the last watchdog reuses a reviewer that may
  have spent the run defending its own corrections.

### D8. Hooks fail open, and that is documented rather than hidden

- **Decided:** accept that hook failure ends the turn, and make unenforced
  pursuits visible after the fact rather than pretending to a fail-closed
  guarantee.
- **Alternatives:** claim fail-closed semantics; attempt a watchdog process
  outside the harness.
- **Why:** neither harness lets a skill make its own hooks mandatory. Claiming
  a guarantee that the runtime does not provide would be exactly the kind of
  theater this EP is meant to remove.

### D9. Use only the portable intersection of hook events

- **Decided:** pursue's hooks target the events both harnesses implement.
  Codex-only `PostCompact`, `SubagentStart`, and `PermissionRequest`, and
  Claude-only `Notification`, are out of scope for v1.
- **Alternatives:** use the best event per harness, with per-harness scripts.
- **Why:** one script set is the property that makes this maintainable at all.
  `PermissionRequest` is genuinely a better fit than `PreToolUse` for
  destructive-action gating on Codex, and that is a real cost — recorded here
  so a future EP can revisit it rather than rediscover it.

### D10. Verification commands are specified in the contract

- **Decided:** the contract declares the verification commands. They are
  proposed by the baseline architect, confirmed by the operator alongside the
  acceptance criteria, and executed by the completion gate.
- **Alternatives:** a separate `verify.sh`; a per-project config surface;
  inferring commands from the repository.
- **Why:** it puts the commands in front of the operator at the moment they are
  already approving what "done" means, which is the only point where approving
  them is cheap. A separate file would drift from the criteria it is supposed
  to evidence, and inference would let the worker choose its own exam.
- **Divergence from EP-0062, deliberately:** in supervise, the contract's
  `verification` strings are explicitly *not* executable authority — the suite
  comes from the operator's separate `[verify].commands`, and the guest cannot
  supply commands or a tree anchor. Pursue has no separate operator-configured
  surface and no broker to enforce that separation, so collapsing the two is
  the honest option. The safeguard that survives is the one that matters:
  the commands are fixed at operator confirmation, and changing them is a
  contract change requiring re-confirmation, not something the worker can edit
  mid-pursuit. `PreToolUse` denies worker writes to `goal.md`.

## Related

- [stado EP-0062: Harness-Enforced Supervised
  Work](https://github.com/foobarto/stado/blob/main/docs/eps/0062-harness-enforced-supervised-work.md)
  — the normative quality contract this EP reduces.
- [Supervised work
  (`/supervise`)](https://github.com/foobarto/stado/blob/main/docs/features/supervise.md)
  — operator reference.
- [The Loop Needs a
  Witness](https://github.com/foobarto/stado/blob/main/docs/articles/supervise-in-practice.md)
  — design rationale and failure modes.
- [`foobarto/stado-plugins/supervise`](https://github.com/foobarto/stado-plugins/tree/main/supervise)
  — the signed application, including its detector and stale-result policy.
- `SKILL.md` — the current, pre-EP-0001 pursue behaviour.
