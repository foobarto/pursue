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

# ---------------------------------------------------------------------------
# Detector state
#
# Detectors are counters, and counters need memory between tool calls.  That
# memory is bounded on purpose: a pursuit runs for days across thousands of
# calls, and an unbounded map would eventually make this hook's own jq the
# slowest thing in the session.
# ---------------------------------------------------------------------------

PURSUE_DETECT_MAX_KEYS="${PURSUE_DETECT_MAX_KEYS:-200}"

# How long to wait for the state lock before giving up on this call.
PURSUE_DETECT_LOCK_WAIT="${PURSUE_DETECT_LOCK_WAIT:-5}"

pursue_detect_state_path() { printf '%s/detect-state.json\n' "$1"; }
pursue_detect_lock_path()  { printf '%s/detect-state.lock\n' "$1"; }

# Run "$@" with the detector-state lock held, or not at all.
#
# The load-modify-save below is not atomic, and Claude Code batches
# independent tool calls in parallel by default, so concurrent PostToolUse
# hooks are the normal case rather than the edge case.  Measured with ten
# identical failing calls: sequential gave a count of 10 and fired both
# failure detectors; parallel gave a count of 1 and never created
# triggers.jsonl at all.  pursue_detect_save's atomic rename prevents a torn
# file; it does nothing about a lost update.
#
# Failing open here is deliberate and asymmetric.  A missed detection costs
# one signal out of many; a hook that blocks costs the operator a wedged
# tool call.  So no flock, an unwritable state directory, or a lock we
# cannot take within the timeout all mean "skip detection for this call".
pursue_detect_locked() {
  local goal_dir="$1" lock
  shift
  command -v flock >/dev/null 2>&1 || return 0
  lock="$(pursue_detect_lock_path "$goal_dir")"
  # Guard the redirection instead of redirecting and hoping: a failed `9>`
  # is reported while the redirection is being set up, so a 2>/dev/null
  # inside the subshell can never cover it.  Same hazard common.sh
  # documents for its -r guards.
  if [[ -e "$lock" ]]; then
    [[ -w "$lock" ]] || return 0
  else
    [[ -w "$goal_dir" ]] || return 0
  fi
  (
    flock -w "$PURSUE_DETECT_LOCK_WAIT" 9 2>/dev/null || exit 0
    "$@"
  ) 9>"$lock"
  return 0
}

# Print the detector state.  A missing or unparseable file yields a valid
# empty state rather than an error: losing detector history is a degraded
# detector, but a hook that fails on it is a broken session.
pursue_detect_load() {
  local f empty='{"version":1,"errors":{},"pairs":{},"files":{},"verified":{}}'
  f="$(pursue_detect_state_path "$1")"
  if [[ -r "$f" ]] && jq -e '
      .version == 1
      and ([.errors, .pairs, .files, .verified]
           | all(. == null or type == "object"))
    ' "$f" >/dev/null 2>&1; then
    jq -c '.' "$f" 2>/dev/null || printf '%s\n' "$empty"
  else
    printf '%s\n' "$empty"
  fi
}

# Write the state atomically, next to its destination so the rename is a
# same-filesystem rename(2).  Same reasoning as the installer's config
# writes: a partial write here silently corrupts detector history.
pursue_detect_save() {
  local dest tmp
  dest="$(pursue_detect_state_path "$1")"
  tmp="$(mktemp "${dest}.XXXXXX" 2>/dev/null)" || return 0
  if printf '%s\n' "$2" | jq -c '.' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$dest" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# Increment state.<collection>.<key>, trimming the collection when it grows
# past the cap.  jq preserves insertion order for object keys, so dropping
# from the front drops the oldest.
pursue_detect_bump() {
  printf '%s' "$1" | jq -c \
    --arg c "$2" --arg k "$3" --argjson max "$PURSUE_DETECT_MAX_KEYS" '
      .[$c] //= {}
      | .[$c][$k] = ((.[$c][$k] // 0) + 1)
      | if (.[$c] | length) > $max
        then .[$c] = (.[$c] | to_entries | .[([1, (($max / 2) | floor)] | max):] | from_entries)
        else . end
    ' 2>/dev/null || printf '%s' "$1"
}

pursue_detect_count() {
  printf '%s' "$1" \
    | jq -r --arg c "$2" --arg k "$3" '(.[$c][$k] // 0)' 2>/dev/null \
    || printf '0\n'
}

# ---------------------------------------------------------------------------
# Triggers
# ---------------------------------------------------------------------------

PURSUE_REPEAT_THRESHOLD="${PURSUE_REPEAT_THRESHOLD:-3}"
# Stricter than repeat: same error *and* same arguments means the worker has
# stopped changing anything, which is a much stronger signal than the same
# error arrived at two different ways.
PURSUE_THRASH_THRESHOLD="${PURSUE_THRASH_THRESHOLD:-2}"

# Append one trigger to triggers.jsonl.  Shares the file with slice 1's
# heartbeats; `kind` is what tells them apart.  Detail is caller-supplied
# compact JSON, embedded as an object rather than a string so the record
# stays queryable.
pursue_detect_trigger() {
  local detail line
  # Assigned to a local first: `${3:-{}}` is ambiguous to the parser
  # because the default value's own brace closes the expansion.
  detail="$3"
  [[ -n "$detail" ]] || detail='{}'
  line="$(jq -cn --arg n "$2" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --argjson d "$detail" \
            '{ts: $ts, kind: "trigger", name: $n, detail: $d}' 2>/dev/null)" || return 0
  printf '%s\n' "$line" >> "$1/triggers.jsonl" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Failure detectors
#
# Both fire when the count *reaches* the threshold, not above it, so a
# persistent failure produces one trigger rather than one per call.  In
# Plan 3 each trigger demands a fresh review; firing per call would turn a
# stuck loop into a review storm.
# ---------------------------------------------------------------------------

pursue_detect_failures() {
  local goal_dir="$1" state="$2" fp digest pair n
  fp="$(pursue_error_fingerprint)"
  # Empty fingerprint means the call succeeded — nothing to count.
  [[ -n "$fp" ]] || { printf '%s\n' "$state"; return 0; }

  digest="$(pursue_input_digest)"
  pair="${fp}-${digest}"

  state="$(pursue_detect_bump "$state" errors "$fp")"
  n="$(pursue_detect_count "$state" errors "$fp")"
  if [[ "$n" == "$PURSUE_REPEAT_THRESHOLD" ]]; then
    pursue_detect_trigger "$goal_dir" repeated_failure \
      "$(jq -cn --arg f "$fp" --argjson c "$n" '{fingerprint: $f, count: $c}')"
  fi

  state="$(pursue_detect_bump "$state" pairs "$pair")"
  n="$(pursue_detect_count "$state" pairs "$pair")"
  if [[ "$n" == "$PURSUE_THRASH_THRESHOLD" ]]; then
    pursue_detect_trigger "$goal_dir" retry_thrash \
      "$(jq -cn --arg f "$fp" --arg d "$digest" --argjson c "$n" \
           '{fingerprint: $f, input_digest: $d, count: $c}')"
  fi

  printf '%s\n' "$state"
}

# ---------------------------------------------------------------------------
# Churn, scope, and regression detectors
# ---------------------------------------------------------------------------

# How many changed files count as scope growth when the active plan step
# declares no scope of its own.
PURSUE_SCOPE_MAX_FILES="${PURSUE_SCOPE_MAX_FILES:-15}"

# A file edited back to a content hash it already had is churn: the worker
# is cycling rather than converging.  Only the last few hashes per file are
# kept — the interesting case is a short oscillation, not a file returning
# after a hundred edits.
PURSUE_CHURN_HISTORY="${PURSUE_CHURN_HISTORY:-6}"

pursue_detect_churn() {
  local goal_dir="$1" state="$2" root="$3" tool path hash seen
  tool="$(pursue_payload_field tool_name)"
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit) ;;
    *) printf '%s\n' "$state"; return 0 ;;
  esac

  # A failed edit leaves the file untouched, so its hash matches the previous
  # one and looks identical to a revert.  Only successful edits can churn.
  [[ -z "$(pursue_error_fingerprint)" ]] || { printf '%s\n' "$state"; return 0; }

  path="$(pursue_payload_raw tool_input | jq -r '.file_path // .notebook_path // empty' 2>/dev/null)"
  [[ -n "$path" && -r "$path" ]] || { printf '%s\n' "$state"; return 0; }
  hash="$(sha256sum "$path" 2>/dev/null | cut -c1-12)"
  [[ -n "$hash" ]] || { printf '%s\n' "$state"; return 0; }

  seen="$(printf '%s' "$state" \
    | jq -r --arg p "$path" --arg h "$hash" \
        '[(.files[$p] // [])[] | select(. == $h)] | length' 2>/dev/null || printf '0')"

  state="$(printf '%s' "$state" | jq -c \
    --arg p "$path" --arg h "$hash" --argjson keep "$PURSUE_CHURN_HISTORY" '
      .files //= {}
      | .files[$p] = ((.files[$p] // []) + [$h] | .[-$keep:])
    ' 2>/dev/null || printf '%s' "$state")"

  if [[ "$seen" != "0" ]]; then
    pursue_detect_trigger "$goal_dir" edit_revert_churn \
      "$(jq -cn --arg p "$path" --arg h "$hash" '{path: $p, content: $h}')"
  fi
  printf '%s\n' "$state"
}

# Scope growth against the active step's declared scope, falling back to a
# changed-file count when no scope is declared.  The fallback matters: until
# the contract flow lands there is no declared scope at all, and a detector
# that silently does nothing in that case would be the same mistake as
# shipping a hook whose inputs nobody writes.
pursue_detect_scope() {
  local goal_dir="$1" root="$2" tool changed

  # Only tools that can change the working tree are worth a git call.  This
  # runs after every tool call in an active pursuit, and `-uall` walks the
  # whole untracked tree — on a large repo it is the most expensive thing in
  # the hot path, and Read/Grep/WebSearch cannot have changed anything.
  # Bash is included because it is how most tree changes happen outside the
  # edit tools.
  tool="$(pursue_payload_field tool_name)"
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit|Bash) ;;
    *) return 0 ;;
  esac

  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  # Exclude pursue's own state: a project that does not gitignore .agent/ would
  # otherwise count this hook's own bookkeeping as scope creep, and in the next
  # slice each verdict is a new file — a long pursuit would trip its own
  # detector and demand reviews about its own record-keeping.
  changed="$(git -C "$root" status --porcelain --untracked-files=all -- ':(exclude).agent' 2>/dev/null | wc -l)"
  [[ "$changed" -gt "$PURSUE_SCOPE_MAX_FILES" ]] || return 0
  pursue_detect_trigger "$goal_dir" scope_growth \
    "$(jq -cn --argjson n "$changed" --argjson max "$PURSUE_SCOPE_MAX_FILES" \
         '{changed_files: $n, threshold: $max, basis: "file-count fallback"}')"
}

# A shell command that previously succeeded and now fails is a regression,
# which is a stronger signal than a command that never worked: something
# that was true stopped being true.
pursue_detect_verification() {
  local goal_dir="$1" state="$2" tool cmd cwd key prior fp
  tool="$(pursue_payload_field tool_name)"
  [[ "$tool" == "Bash" ]] || { printf '%s\n' "$state"; return 0; }

  cmd="$(pursue_payload_raw tool_input | jq -r '.command // empty' 2>/dev/null)"
  [[ -n "$cmd" ]] || { printf '%s\n' "$state"; return 0; }

  # Include cwd in the key to distinguish the same command in different directories.
  # This is imperfect — a cd inside a command still isn't reflected — but it is
  # strictly more correct than command-text-only.
  cwd="$(pursue_payload_field cwd)"
  key="$(printf '%s\n%s' "$cwd" "$cmd" | sha256sum | cut -c1-12)"

  prior="$(printf '%s' "$state" | jq -r --arg k "$key" '(.verified[$k] // "")' 2>/dev/null)"
  fp="$(pursue_error_fingerprint)"

  if [[ -z "$fp" ]]; then
    state="$(printf '%s' "$state" | jq -c --arg k "$key" '.verified //= {} | .verified[$k] = "pass"' 2>/dev/null || printf '%s' "$state")"
  else
    if [[ "$prior" == "pass" ]]; then
      pursue_detect_trigger "$goal_dir" verification_regression \
        "$(jq -cn --arg c "$cmd" --arg f "$fp" '{command: $c, fingerprint: $f}')"
    fi
    state="$(printf '%s' "$state" | jq -c --arg k "$key" '.verified //= {} | .verified[$k] = "fail"' 2>/dev/null || printf '%s' "$state")"
  fi
  printf '%s\n' "$state"
}
