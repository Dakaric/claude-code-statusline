#!/usr/bin/env bash
# Ein Account, der nur ein Wochenlimit meldet und nie ein 5h-Fenster hatte. "free"
# waere hier falsch: es gibt kein Fenster, das vorbei sein koennte.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "$1/.claude"
cat > "$1/.claude.json" <<JSON
{ "oauthAccount": { "accountUuid": "$ACCT_A" } }
JSON
