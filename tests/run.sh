#!/usr/bin/env bash
# Charakterisierungstests: jede Fixture geht als Payload in statusline.sh, die Ausgabe
# wird mit der eingefrorenen Erwartung verglichen. HOME zeigt auf eine Sandbox, damit
# weder der echte token-optimizer-Cache noch echte Account-Dateien hineinspielen.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/statusline.sh"
test_now=1788870000
pass=0
fail=0

for fixture in "$root"/tests/fixtures/*.json; do
  name=$(basename "$fixture" .json)
  expected="$root/tests/expected/$name.txt"
  sandbox=$(mktemp -d)
  setup="$root/tests/setup/$name.sh"
  if [ -f "$setup" ]; then
    HOME="$sandbox" STATUSLINE_NOW="$test_now" bash "$setup" "$sandbox" >/dev/null
  fi
  # ENABLE_PROMPT_CACHING_1H aus der Umgebung wuerde das Cache-Segment veraendern und
  # das Ergebnis von der Shell des Ausfuehrenden abhaengig machen.
  actual=$(HOME="$sandbox" NO_COLOR=1 STATUSLINE_NOW="$test_now" \
    env -u ENABLE_PROMPT_CACHING_1H bash "$script" < "$fixture")
  rm -rf "$sandbox"

  if [ ! -f "$expected" ]; then
    printf 'FEHLT  %s (keine Erwartung hinterlegt)\n%s\n\n' "$name" "$actual"
    fail=$((fail + 1))
  elif [ "$actual" = "$(cat "$expected")" ]; then
    printf 'ok     %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FEHLER %s\n--- erwartet ---\n%s\n--- bekommen ---\n%s\n\n' \
      "$name" "$(cat "$expected")" "$actual"
    fail=$((fail + 1))
  fi
done

printf '\n%d bestanden, %d fehlgeschlagen\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
