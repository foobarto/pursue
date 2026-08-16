---
ep: 0000                           # replace with the next free number
title: Short descriptive title     # ~60 chars max
author: Your Name <you@example.com>
status: Draft                      # Draft | Accepted | Implemented | Superseded
type: Standards                    # Standards | Informational | Process
created: YYYY-MM-DD
history:
  - date: YYYY-MM-DD
    status: Draft
    note: Initial draft.
# Optional — add only the fields you need:
# updated: YYYY-MM-DD
# supersedes: ["EP-NNNN"]
# superseded-by: ["EP-NNNN"]
# see-also: ["EP-NNNN"]
# implemented-in: vX.Y.Z
---

# EP-NNNN: Title

<!--
  Delete these instructions before merging.
  - Scale each section to its complexity. Short is fine.
  - Informational EPs can skip Migration, Failure modes, and Test strategy.
  - The Decision log is load-bearing — do not skip it.
  - Once status flips to Accepted, the document is append-only.
-->

## Problem

What's broken or missing today? One to three paragraphs.

## Goals

What does this proposal achieve?

## Non-goals

What does it explicitly not do? Important for scope control — and, for pursue
specifically, the place to be honest about what the host harnesses do not let
us enforce.

## Design

Contracts, data shapes, interfaces, state layout.

## Migration / rollout

How does this land without breaking existing pursuits or installs?

## Failure modes

What can go wrong, and how does the operator find out?

## Test strategy

How is it validated?

## Open questions

Decisions deferred. "We'll figure this out" beats pretending it's decided.

## Decision log

### D1. Short name of the decision

- **Decided:** what this EP commits to.
- **Alternatives:** what else was considered.
- **Why:** one or two sentences.

## Related

- Prior EPs, external references.
