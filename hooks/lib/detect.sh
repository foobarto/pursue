#!/usr/bin/env bash
# Deterministic detectors for pursue's PostToolUse hook (EP-0001 §Detectors).
#
# This is the half of supervision that needs no model: counting what code is
# good at counting.  No language model is required to notice that the same
# command produced the same failure three times.  Interpreting whether that
# repetition is justified is the reviewer's job, not this file's.
#
# Sourced by hooks/post-tool-use.sh, after hooks/lib/common.sh.  Same two
# rules as common.sh: never print to stdout outside the documented
# accessors, and fail open.

# ---------------------------------------------------------------------------
# Payload accessors
#
# common.sh's pursue_payload_field handles top-level scalars.  tool_input and
# tool_response are objects, so they need their own accessor rather than a
# change to a function slice 1's tests pin.
# ---------------------------------------------------------------------------

# Print a top-level object/array field as compact JSON, or nothing.
pursue_payload_raw() {
  printf '%s' "$PURSUE_PAYLOAD" \
    | jq -c --arg f "$1" '.[$f] // empty' 2>/dev/null \
    || true
}

# 12-char digest of tool_input, canonicalised so key order cannot make two
# identical calls look different.  This is what makes retry_thrash mean
# "same arguments" rather than "same JSON serialisation".
pursue_input_digest() {
  printf '%s' "$PURSUE_PAYLOAD" \
    | jq -S -c '.tool_input // {}' 2>/dev/null \
    | sha256sum | cut -c1-12
}

# Error text from tool_response, or nothing when the call succeeded.
#
# Shape is harness-specific and was settled by inspecting real transcripts
# rather than assumed.  On Claude Code a *successful* call returns an object
# ({stdout, stderr, interrupted, ...}) with no error field and no exit code;
# a *failed* one returns a bare string beginning "Error: ".  So the string
# form is the failure signal, not the fallback.
#
# .stderr is deliberately NOT consulted: across 104 observed object results it
# was empty 103 times, and the one non-empty value was an informational notice.
# Treating it as an error would fire the failure detectors on successful
# commands that merely printed something.
#
# .error/.message are kept for harnesses that do report structured errors.
pursue_error_text() {
  printf '%s' "$PURSUE_PAYLOAD" \
    | jq -r '
        (.tool_response // null) as $r
        | if   ($r | type) == "string" then $r
          elif ($r | type) == "object" then ($r.error // $r.message // "")
          else ""
          end
        | if . == null then "" else . end
      ' 2>/dev/null \
    || true
}

# 12-char fingerprint of an error, normalised so the *same* failure matches
# across runs: lowercased, digits stripped (line numbers, PIDs, addresses),
# whitespace collapsed, truncated.  Empty when there was no error — callers
# use emptiness to mean "this call succeeded".
pursue_error_fingerprint() {
  local text
  text="$(pursue_error_text)"
  [[ -n "$text" ]] || return 0
  printf '%s' "$text" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d '[:digit:]' \
    | tr -s '[:space:]' ' ' \
    | cut -c1-200 \
    | sha256sum | cut -c1-12
}
