#!/usr/bin/env bash
# Gibt den Rumpf des Klick-Handlers aus, so wie install.sh ihn einbettet. tests/handler.sh
# prüft genau diesen Text, CI lässt shellcheck darüber laufen.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
body=$(sed -n "/<<'SWITCH_HANDLER'\$/,/^SWITCH_HANDLER\$/p" "$root/install.sh" | sed '1d;$d')
[ -n "$body" ] || { echo "extract-handler: kein Handler-Rumpf in install.sh" >&2; exit 1; }
printf '%s\n' "$body"
