#!/usr/bin/env bash
# Eingeloggt ist A, aber diese Session hat ihre letzte Antwort noch von B bekommen: der
# Payload traegt B's Wochen-Reset. Der Stand gehoert dann zu B und darf A's Snapshot
# nicht ueberschreiben.
set -u
now=${STATUSLINE_NOW:-1788870000}
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "$now" 5 501120 1 7200
write_snapshot "$1" "$ACCT_A" "$((now - 100))" "$((now - 600))" \
  43 "$((now + 293760))" 10 "$((now + 3600))"
