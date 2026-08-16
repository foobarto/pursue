#!/usr/bin/env bash
# pursue SessionStart hook (EP-0001).
#
# Re-injects the active pursuit's contract, anchor, active plan step, open
# blockers, and recent progress into a fresh session.  Injection only: this
# hook never gates.
#
# Registered by `install.sh --hooks` for Claude Code and Codex.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$here/lib/common.sh" 2>/dev/null || { printf '{}\n'; exit 0; }

pursue_inject_main SessionStart || printf '{}\n'
exit 0
