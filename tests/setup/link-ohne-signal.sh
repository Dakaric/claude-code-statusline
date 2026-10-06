#!/usr/bin/env bash
# Wie wechsel-blockiert, mit Link-URL: ohne Signal wird ⇄ angehängt.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 96 7200
