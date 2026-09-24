#!/usr/bin/env bash
# Die Session hat seit dem Wechsel des 5h-Fensters nichts gefragt: Claude Code hat das
# abgelaufene Fenster aus dem Payload genommen, das neue kennt nur der Snapshot, den
# eine andere Session desselben Accounts geschrieben hat. Die Zeile zeigt dessen Stand.
set -u
now=${STATUSLINE_NOW:-1788870000}
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "$now" 78 77760 40 -3600
write_snapshot "$1" "$ACCT_A" "$((now - 100))" "$((now - 600))" \
  24 "$((now + 448800))" 12 "$((now + 7200))"
