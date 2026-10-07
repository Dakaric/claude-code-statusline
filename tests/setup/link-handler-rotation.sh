#!/usr/bin/env bash
# Wie wechsel-blockiert, mit Handler-Marker und Mails: ohne Signal verlinkt das
# angehaengte Zeichen auf die Rotation, ohne Ziel.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 96 7200 a@example.com b@example.com
mark_switch_handler "$1"
