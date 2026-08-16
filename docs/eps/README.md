# Enhancement Proposals (EPs)

Numbered design records capturing the *what* and *why* of non-trivial changes
to pursue. The convention is borrowed from
[stado](https://github.com/foobarto/stado/tree/main/docs/eps).

## When to write one

Write an EP when introducing a new contract, touching a load-bearing invariant,
reversing a prior decision, or answering a "should we do X or Y?" question that
isn't obvious from the skill body. Skip it for bug fixes, doc typos, and
contained refactors.

`SKILL.md` says what pursue *does*. EPs say why it does it that way.

## How to write one

1. Copy `0000-template.md` to `NNNN-short-kebab-title.md` with the next unused
   number.
2. Fill in the frontmatter and the expected sections. The Decision Log is
   load-bearing — don't skip it.
3. Iterate while `status: Draft`. Once `Accepted`, the document is append-only:
   a decision that changes goes in a new EP that supersedes it.

## Index

| #    | Title | Type | Status |
|------|-------|------|--------|
| 0001 | [Hook-Enforced Pursuit](./0001-hook-enforced-pursuit.md) | Standards | Draft |
