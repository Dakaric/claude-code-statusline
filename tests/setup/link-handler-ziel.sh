#!/usr/bin/env bash
# Wie zwei-accounts, mit Handler-Marker und Mails: das Wechselsignal verlinkt auf
# claude-statusline://switch mit Bs Mail als Ziel.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 40 -3600 a@example.com b@example.com
mark_switch_handler "$1"
