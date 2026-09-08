#!/usr/bin/env bash
# Schreibt die Erwartungen aus dem aktuellen Verhalten neu. Das ist ein Werkzeug, kein
# Testlauf: die erzeugten Dateien muessen von Hand gelesen werden, bevor sie committet
# werden. Blind eingefroren macht jeder Fehler den Test gruen.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
test_now=1788870000

for fixture in "$root"/tests/fixtures/*.json; do
  name=$(basename "$fixture" .json)
  sandbox=$(mktemp -d)
  setup="$root/tests/setup/$name.sh"
  if [ -f "$setup" ]; then
    HOME="$sandbox" STATUSLINE_NOW="$test_now" bash "$setup" "$sandbox" >/dev/null
  fi
  HOME="$sandbox" NO_COLOR=1 STATUSLINE_NOW="$test_now" \
    env -u ENABLE_PROMPT_CACHING_1H bash "$root/statusline.sh" < "$fixture" \
    > "$root/tests/expected/$name.txt"
  rm -rf "$sandbox"
  printf '=== %s ===\n' "$name"
  cat "$root/tests/expected/$name.txt"
  printf '\n\n'
done
