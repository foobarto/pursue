#!/usr/bin/env bash
# pursue PreCompact hook (EP-0001).
#
# Same injection as SessionStart, fired just before context is discarded so
# the contract survives compaction.  Injection only: this hook never gates.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$here/lib/common.sh" 2>/dev/null || { printf '{}\n'; exit 0; }

pursue_inject_main PreCompact || printf '{}\n'
exit 0
