#!/usr/bin/env bash
# Eingeloggt ist A, dessen Fenster noch 3,4 Tage laeuft. Der Payload traegt einen Reset,
# den kein Snapshot kennt: ein frisch begonnenes Fenster, aber nicht A's, denn A's altes
# ist noch nicht vorbei. Der Stand gehoert also nicht zu A und wird nicht geschrieben.
set -u
now=${STATUSLINE_NOW:-1788870000}
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "$now" 5 501120 1 7200
write_snapshot "$1" "$ACCT_A" "$((now - 100))" "$((now - 600))" \
  43 "$((now + 293760))" 10 "$((now + 3600))"
