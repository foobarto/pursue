#!/usr/bin/env bash
# Verdict decoding and staleness (EP-0001 §Verdicts and the stale-result
# policy).
#
# A reviewer's judgement only means anything about the state it actually
# looked at.  Everything here exists to keep that binding intact: the
# verdict is written under the anchor it reviewed, and a verdict whose
# anchor is not the current one is classified rather than trusted.
#
# Sourced after common.sh and detect.sh.  Same rules: no stray stdout,
# fail open.

# The fenced-block tag a reviewer must use.  It is the discriminator: an
# ordinary subagent that happens to end with JSON is not a reviewer, and
# must not be mistaken for one.
PURSUE_VERDICT_TAG="${PURSUE_VERDICT_TAG:-pursue-verdict}"

# Filename-safe form of an anchor.  Anchors contain ':' — legal in a Linux
# filename but awkward everywhere else — so the on-disk name substitutes
# '_'.  The full anchor is stored inside the file, which is what the
# staleness comparison actually reads.
pursue_anchor_slug() { printf '%s\n' "${1//:/_}"; }

# Print the contents of the tagged fenced block, or nothing.
pursue_verdict_extract() {
  printf '%s' "$1" | awk -v tag="$PURSUE_VERDICT_TAG" '
    $0 ~ "^[[:space:]]*```" tag "[[:space:]]*$" { inblock = 1; next }
    inblock && /^[[:space:]]*```[[:space:]]*$/   { exit }
    inblock                                       { print }
  ' 2>/dev/null || true
}

# Strict decode.  Returns non-zero for anything that is not a well-formed
# verdict; callers discard rather than repair.  A garbled verdict that got
# coerced into a valid-looking one would be a model's noise promoted to
# consent.
pursue_verdict_validate() {
  # NOTE: the brief's original predicate was
  #   ["continue","correct","pause","stop","approve"] | index(.verdict) != null
  # which is a jq operator-precedence bug: inside `array | index(.verdict)`,
  # `.verdict` is evaluated against the array being piped in (the input to
  # index()), not the original object, so it always fails with "Cannot
  # index array with string verdict" -- every call, valid or not. Rewritten
  # with `.verdict | IN(...)` instead, which is semantically identical (same
  # five-value membership check) but evaluates against the right input
  # because the array literal here does not depend on `.` at all.
  printf '%s' "$1" | jq -e '
    type == "object"
    and (.verdict | type) == "string"
    and (.verdict | IN("continue","correct","pause","stop","approve"))
    and (.reason | type) == "string"
    and ((.reason | gsub("^\\s+|\\s+$"; "")) | length) > 0
  ' >/dev/null 2>&1
}

# Store a validated verdict under the anchor it reviewed, with that anchor
# recorded inside it.
pursue_verdict_write() {
  local goal_dir="$1" anchor="$2" json="$3" dir slug tmp
  dir="$goal_dir/verdicts"
  mkdir -p "$dir" 2>/dev/null || return 1
  slug="$(pursue_anchor_slug "$anchor")"
  tmp="$(mktemp "$dir/$slug.json.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s' "$json" \
       | jq -c --arg a "$anchor" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           '. + {anchor: $a, recorded_at: $ts}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$dir/$slug.json" 2>/dev/null || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"; return 1
  fi
  return 0
}

# The three-way stale policy.  Discarding everything stale would make a slow
# reviewer decoration; applying everything stale would let a judgement about
# an old state control a new one.  So: an obsolete approval is worthless, an
# obsolete correction may still be useful advice, and an obsolete stop is
# serious enough to demand a fresh look rather than be dropped.
pursue_verdict_classify() {
  local json="$1" current="$2" anchor verdict
  anchor="$(printf '%s' "$json" | jq -r '.anchor // empty' 2>/dev/null)"
  verdict="$(printf '%s' "$json" | jq -r '.verdict // empty' 2>/dev/null)"
  if [[ -n "$anchor" && "$anchor" == "$current" ]]; then
    printf 'current\n'; return 0
  fi
  case "$verdict" in
    continue|approve) printf 'stale-discard\n' ;;
    correct)          printf 'stale-advisory\n' ;;
    pause|stop)       printf 'stale-confirm\n' ;;
    *)                printf 'stale-discard\n' ;;
  esac
}
