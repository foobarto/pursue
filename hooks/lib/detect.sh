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

# True when $1 is a plain non-negative integer.  Every arithmetic comparison
# in this file is gated on it, and nothing that has not passed it may reach
# `[[ -eq ]]`, `[[ -gt ]]`, or `(( ))`.
#
# This is a security boundary, not a tidiness rule.  `[[ x -eq y ]]` evaluates
# BOTH operands in *arithmetic* context, and bash expands `$(...)` inside an
# array subscript while doing so — so a counter whose value is the string
# `a[$(touch /tmp/PWNED)]` runs the command on the next tool call.  The `=`
# string comparison this file used before did not.  And detect-state.json is
# reachable by an attacker: SKILL.md tells operators to track pursuit state in
# git, so any cloned repository can ship a poisoned one.  `[[ =~ ]]` performs
# no arithmetic evaluation, which is what makes this test safe to run on the
# untrusted value itself.
pursue_is_uint() { [[ "${1-}" =~ ^[0-9]+$ ]]; }

# How long to wait for the state lock before giving up on this call.
#
# One second, not five.  pursue_detect_locked below states the asymmetry — a
# missed detection costs one signal out of many, a blocked hook costs the
# operator a wedged tool call — and then five seconds contradicted it, on a
# hook that runs after *every* tool call.  Measured against a held lock, the
# hook stalled for 5.02s.  One second still absorbs the contention this lock
# actually sees (a handful of parallel hooks each holding it for tens of
# milliseconds) without ever being the thing the operator notices.
PURSUE_DETECT_LOCK_WAIT="${PURSUE_DETECT_LOCK_WAIT:-1}"

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
# tool call.  So an unwritable state directory, or a lock we cannot take
# within the timeout, both mean "skip detection for this call".
#
# A *missing* flock is the exception, and skipping was the wrong answer for
# it: with no flock on PATH this wrote no state, no triggers and — worst —
# no heartbeat, which is precisely the "hooks registered but never running"
# condition EP-0001's heartbeat exists to make detectable.  Silence is not a
# degraded signal, it is an actively misleading one.  So run the callback
# unlocked instead.  That reinstates the lost-update race on such systems
# (parallel PostToolUse hooks can overwrite each other's counters), which is
# strictly better than being unable to tell an unenforced pursuit from a
# quiet one.  install.sh names flock so the operator hears about it once, at
# install time, rather than never.
pursue_detect_locked() {
  local goal_dir="$1" lock wait
  shift
  if ! command -v flock >/dev/null 2>&1; then
    "$@"
    return 0
  fi
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
  # A malformed override must not reach flock.  `flock -w abc` errors out,
  # which reads here as "could not take the lock" and silently disables
  # detection for the whole session — the same shape of silent failure as
  # handing an unvalidated operand to arithmetic, and just as invisible.
  # Fall back to the default rather than trusting it.
  wait="$PURSUE_DETECT_LOCK_WAIT"
  pursue_is_uint "$wait" || wait=1
  (
    flock -w "$wait" 9 2>/dev/null || exit 0
    "$@"
  ) 9>"$lock"
  return 0
}

# Print the detector state.  A missing or unparseable file yields a valid
# empty state rather than an error: losing detector history is a degraded
# detector, but a hook that fails on it is a broken session.
#
# The counting collections must additionally hold numbers.  Same shape as the
# collection-type gate beside it, and the same reason as pursue_is_uint: these
# values end up as operands of an arithmetic comparison, so a state file that
# put a shell expansion where a count belongs is corrupt, not merely odd.
# Rejecting it here means the poisoned value never reaches the counters at
# all.  (files/verified/scope are excluded because their values are legitimately
# arrays, strings, and booleans.)
pursue_detect_load() {
  local f empty='{"version":1,"errors":{},"pairs":{},"files":{},"verified":{},"sessions":{},"scope":{}}'
  f="$(pursue_detect_state_path "$1")"
  if [[ -r "$f" ]] && jq -e '
      .version == 1
      and ([.errors, .pairs, .files, .verified, .sessions, .scope]
           | all(. == null or type == "object"))
      and ([.errors, .pairs, .sessions]
           | all((. == null) or (all(.[]; type == "number"))))
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

# The count held at state.<collection>.<key>.  Guaranteed to print a plain
# non-negative integer: a missing, non-numeric, or otherwise unusable value
# reads as 0 rather than being handed on to an arithmetic comparison.  Callers
# rely on that guarantee — it is what lets them compare the result without
# re-validating it.
pursue_detect_count() {
  local n
  n="$(printf '%s' "$1" | jq -r --arg c "$2" --arg k "$3" '(.[$c][$k] // 0)' 2>/dev/null)" || n=0
  pursue_is_uint "$n" || n=0
  printf '%s\n' "$n"
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
  # `${3-}`, not `$3`: under `set -u` a two-argument call aborts the shell
  # here, before anything is written — and it would abort it *silently*,
  # since every hook redirects its own stderr away.  The `-n` test below is
  # only a real guard once the expansion cannot itself be fatal.
  # (`${3:-{}}` is not an option: the default value's own brace closes the
  # expansion, so the parser sees `${3:-{}` followed by a stray `}`.)
  detail="${3-}"
  [[ -n "$detail" ]] || detail='{}'
  line="$(jq -cn --arg n "$2" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --argjson d "$detail" \
            '{ts: $ts, kind: "trigger", name: $n, detail: $d}' 2>/dev/null)" || return 0
  pursue_detect_append "$1" "$line"
}

# Append one line to triggers.jsonl, quietly.
#
# The append needs a writability guard for the same reason common.sh's
# readers need `-r`: the shell reports a failed redirection while setting it
# up, so the command's own `2>/dev/null` never covers it.  Without this, a
# state directory the hook cannot write leaks "Permission denied" to stderr
# on *every* tool call.
pursue_detect_append() {
  local f="$1/triggers.jsonl"
  if [[ -e "$f" ]]; then
    [[ -w "$f" ]] || return 0
  else
    [[ -w "$1" ]] || return 0
  fi
  printf '%s\n' "$2" >> "$f" 2>/dev/null || true
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
  local goal_dir="$1" state="$2" root="$3" fp digest tree pair n
  fp="$(pursue_error_fingerprint)"
  # Empty fingerprint means the call succeeded — nothing to count.
  [[ -n "$fp" ]] || { printf '%s\n' "$state"; return 0; }

  digest="$(pursue_input_digest)"
  # The tree digest is what makes "stopped changing anything" a claim this
  # function actually checks.  Without it the pair key is command+error
  # only, and the ordinary red-green loop — `npm test` fails, edit the
  # source, `npm test` fails again — reads as thrash even though the worker
  # changed the very thing under test.  Thrash is a *repeat against an
  # unchanged tree*; anything else is just a failure that happens twice,
  # which is what repeated_failure is for.
  tree="$(pursue_tree_digest "$root")"
  pair="${fp}-${digest}-${tree}"

  state="$(pursue_detect_bump "$state" errors "$fp")"
  n="$(pursue_detect_count "$state" errors "$fp")"
  # Arithmetic, not string, comparison: a non-canonical override such as
  # PURSUE_REPEAT_THRESHOLD="03" would never string-equal a count and would
  # silently disable the detector for the whole session.  Both operands are
  # validated first — see pursue_is_uint for why that is not optional — and
  # forced to base 10, so "08" is eight rather than a fatal octal literal.
  if pursue_is_uint "$n" && pursue_is_uint "$PURSUE_REPEAT_THRESHOLD" \
     && (( 10#$n == 10#$PURSUE_REPEAT_THRESHOLD )); then
    pursue_detect_trigger "$goal_dir" repeated_failure \
      "$(jq -cn --arg f "$fp" --argjson c "$n" '{fingerprint: $f, count: $c}')"
  fi

  state="$(pursue_detect_bump "$state" pairs "$pair")"
  n="$(pursue_detect_count "$state" pairs "$pair")"
  if pursue_is_uint "$n" && pursue_is_uint "$PURSUE_THRASH_THRESHOLD" \
     && (( 10#$n == 10#$PURSUE_THRASH_THRESHOLD )); then
    pursue_detect_trigger "$goal_dir" retry_thrash \
      "$(jq -cn --arg f "$fp" --arg d "$digest" --arg t "$tree" --argjson c "$n" \
           '{fingerprint: $f, input_digest: $d, tree: $t, count: $c}')"
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
  local goal_dir="$1" state="$2" root="$3" tool path hash prev seen
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

  # A match against the *immediately preceding* hash is not a revert, it is
  # an edit that changed nothing — a successful no-op write, which the edit
  # tools report exactly like any other success.  Five identical Writes used
  # to produce four edit_revert_churn triggers.  Churn means returning to an
  # older, non-adjacent content; a no-op is neither recorded nor counted, so
  # the history keeps describing distinct states.
  prev="$(printf '%s' "$state" \
    | jq -r --arg p "$path" '((.files[$p] // []) | last) // ""' 2>/dev/null || printf '')"
  [[ "$hash" != "$prev" ]] || { printf '%s\n' "$state"; return 0; }

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
# Unlike its siblings this detector's input is a *level*, not an event, and
# that is why it needs state at all.  A counter cannot skip past a
# threshold, so "fire when the count reaches N" is self-limiting.  A level
# can sit above its threshold indefinitely: without the `fired` flag, every
# subsequent Edit/Write/Bash appended another scope_growth trigger for as
# long as the tree stayed large — 20 changed files and 5 edits gave 5
# triggers.  In the next slice each trigger demands a review, so that is a
# block the worker cannot clear by working.  Fire once on the crossing,
# re-arm only when the count drops back under the threshold.
pursue_detect_scope() {
  local goal_dir="$1" state="$2" root="$3" tool porcelain changed fired

  # Only tools that can change the working tree are worth a git call.  This
  # runs after every tool call in an active pursuit, and `-uall` walks the
  # whole untracked tree — on a large repo it is the most expensive thing in
  # the hot path, and Read/Grep/WebSearch cannot have changed anything.
  # Bash is included because it is how most tree changes happen outside the
  # edit tools.
  tool="$(pursue_payload_field tool_name)"
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit|Bash) ;;
    *) printf '%s\n' "$state"; return 0 ;;
  esac

  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { printf '%s\n' "$state"; return 0; }
  # Exclude pursue's own state: a project that does not gitignore .agent/ would
  # otherwise count this hook's own bookkeeping as scope creep, and in the next
  # slice each verdict is a new file — a long pursuit would trip its own
  # detector and demand reviews about its own record-keeping.
  #
  # Capture git's exit status instead of piping straight into `wc -l`, which
  # swallows it: a failed `git status` then reads as "0 changed files", takes
  # the re-arm branch below, and lets scope_growth fire a second time for the
  # same crossing as soon as git recovers — with the tree unchanged
  # throughout.  Demonstrated with a corrupt index; in the next slice that
  # second trigger is a second review demand the worker cannot clear by
  # working.  A failure is no evidence about scope either way, so neither fire
  # nor re-arm: hand the state back exactly as it came in.
  if ! porcelain="$(git -C "$root" status --porcelain --untracked-files=all -- ':(exclude).agent' 2>/dev/null)"; then
    printf '%s\n' "$state"; return 0
  fi
  # Command substitution already stripped the trailing newline, so an empty
  # result has to be counted as 0 rather than as one line.  tr, because `wc`
  # pads its count with blanks on the BSD userland and the guarded comparison
  # below accepts digits only.
  changed=0
  [[ -z "$porcelain" ]] || changed="$(printf '%s\n' "$porcelain" | wc -l | tr -d '[:space:]')"
  fired="$(printf '%s' "$state" | jq -r '(.scope.fired // false)' 2>/dev/null || printf 'false')"

  if pursue_is_uint "$changed" && pursue_is_uint "$PURSUE_SCOPE_MAX_FILES" \
     && (( 10#$changed > 10#$PURSUE_SCOPE_MAX_FILES )); then
    if [[ "$fired" != "true" ]]; then
      pursue_detect_trigger "$goal_dir" scope_growth \
        "$(jq -cn --argjson n "$changed" --argjson max "$PURSUE_SCOPE_MAX_FILES" \
             '{changed_files: $n, threshold: $max, basis: "file-count fallback"}')"
      state="$(printf '%s' "$state" | jq -c '.scope = {fired: true}' 2>/dev/null || printf '%s' "$state")"
    fi
  elif [[ "$fired" == "true" ]]; then
    state="$(printf '%s' "$state" | jq -c '.scope = {fired: false}' 2>/dev/null || printf '%s' "$state")"
  fi

  printf '%s\n' "$state"
}

# A shell command that previously succeeded and now fails is a regression,
# which is a stronger signal than a command that never worked: something
# that was true stopped being true.
#
# KNOWN WIDENING: EP-0001 scopes this to "a previously passing *verify
# command*"; this watches every Bash call, so `grep -q TODO` succeeding and
# then failing reads as a regression.  The narrowing is not available yet —
# the declared verify commands live in the contract that EP-0001 D10 adds,
# and there is no contract to read.  Narrow the key to the contract's
# declared commands once those exist, rather than trying to guess which
# commands are verification from their text.
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

# ---------------------------------------------------------------------------
# Heartbeats for the observation hooks
# ---------------------------------------------------------------------------

# Write at most one heartbeat per (event, session), and print the updated
# state.
#
# EP-0001 Failure modes requires every hook to leave evidence that it ran,
# so `/pursue status` can tell "registered and quiet" from "never ran" —
# without it, an unenforced pursuit looks exactly like an enforced one that
# had nothing to say.  The injection hooks can heartbeat per run because
# they run a handful of times per session.  PostToolUse runs after every
# tool call, so per-run would make triggers.jsonl almost entirely
# heartbeat and drown the records the next slice has to read.  Once per
# session is enough to answer the question the heartbeat exists to answer.
#
# The marker lives in the same bounded state as the counters, so a long
# multi-session pursuit cannot grow it without limit either.
pursue_detect_session_heartbeat() {
  local goal_dir="$1" state="$2" event="$3" session="${4-}" key seen
  [[ -n "$session" ]] || session="unknown"
  key="${event}:${session}"
  seen="$(pursue_detect_count "$state" sessions "$key")"
  # "$seen" is a plain integer by pursue_detect_count's guarantee, and the
  # re-check costs nothing: this is the site the reviewer reached the
  # arithmetic-injection through, so it does not rely on a caller's promise.
  if pursue_is_uint "$seen" && (( 10#$seen == 0 )); then
    pursue_heartbeat "$goal_dir" "$event" session-heartbeat
    state="$(pursue_detect_bump "$state" sessions "$key")"
  fi
  printf '%s\n' "$state"
}
