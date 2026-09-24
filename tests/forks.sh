#!/usr/bin/env bash
# Waechtertest fuer die Prozesslast: jede offene Session ruft das Skript jede Sekunde auf,
# und jeder Prozess kostet einen fork, ein externer Befehl dazu ein exec. Mit einem
# Dutzend Sessions summiert sich das zu Hunderten Starts pro Sekunde, und die Maschine
# erstickt an ihrer eigenen Statusline. Gemessen wird ein Lauf im vollen
# Zwei-Account-Fall:
# - externe Befehle ueber vorgeschaltete Wrapper, die jeden Aufruf mitschreiben,
# - Subshells wie $(...) ueber einen DEBUG-Trap, der die Verschachtelungstiefe
#   BASH_SUBSHELL mitschreibt. Jeder Wechsel von 0 auf mehr ist eine neue Subshell.
#   BASHPID waere genauer, fehlt aber in der Bash 3.2 von macOS.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
test_now=1788870000
max_jq_calls=6
max_processes=12
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

mkdir -p "$sandbox/bin"
for cmd in awk basename cat date git jq mkdir mv rm sed stat tail; do
  real=$(command -v "$cmd") || continue
  cat > "$sandbox/bin/$cmd" <<SHIM
#!/bin/sh
echo $cmd >> "$sandbox/calls"
exec "$real" "\$@"
SHIM
  chmod +x "$sandbox/bin/$cmd"
done

HOME="$sandbox" STATUSLINE_NOW="$test_now" \
  bash "$root/tests/setup/runway-knapp.sh" "$sandbox" >/dev/null
: > "$sandbox/calls"
: > "$sandbox/depths"
# shellcheck disable=SC2016  # $1 und $2 gehoeren der inneren bash, nicht dieser
HOME="$sandbox" PATH="$sandbox/bin:$PATH" NO_COLOR=1 STATUSLINE_NOW="$test_now" \
  env -u ENABLE_PROMPT_CACHING_1H bash -c '
    set -T
    trap "echo \$BASH_SUBSHELL >> \"$1/depths\"" DEBUG
    . "$2"' _ "$sandbox" "$root/statusline.sh" \
  < "$root/tests/fixtures/runway-knapp.json" >/dev/null

jq_calls=$(grep -c '^jq$' "$sandbox/calls")
external_calls=$(wc -l < "$sandbox/calls" | tr -d ' ')
subshells=$(awk 'previous == 0 && $1 > 0 { count++ } { previous = $1 } END { print count + 0 }' \
  "$sandbox/depths")
processes=$((external_calls + subshells))

failed=0
if [ "$jq_calls" -gt "$max_jq_calls" ]; then
  printf 'FEHLER forks: %d jq-Aufrufe pro Lauf, erlaubt sind %d\n' "$jq_calls" "$max_jq_calls"
  failed=1
fi
if [ "$processes" -gt "$max_processes" ]; then
  printf 'FEHLER forks: %d Prozesse pro Lauf (%d extern, %d Subshells), erlaubt sind %d\n' \
    "$processes" "$external_calls" "$subshells" "$max_processes"
  sort "$sandbox/calls" | uniq -c | sort -rn
  failed=1
fi
[ "$failed" = 0 ] && printf 'ok     forks (%d Prozesse pro Lauf, davon %d jq)\n' "$processes" "$jq_calls"
exit "$failed"
