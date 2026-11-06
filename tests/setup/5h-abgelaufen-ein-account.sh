#!/usr/bin/env bash
# Ein Account, dessen Snapshot noch ein laengst abgelaufenes 5h-Fenster traegt, waehrend
# der Payload nur das Wochenlimit meldet. So sieht ein Abo ohne 5h-Limit aus, das frueher
# eines hatte. Ein Fenster, das vorbei ist, begrenzt nichts: kein 5h-Segment, kein "free".
set -u
now=${STATUSLINE_NOW:-1788870000}
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "$1/.claude"
cat > "$1/.claude.json" <<JSON
{ "oauthAccount": { "accountUuid": "$ACCT_A" } }
JSON
write_snapshot "$1" "$ACCT_A" "$((now - 100))" "$((now - 600))" \
  24 "$((now + 448800))" 0 "$((now - 950000))"
