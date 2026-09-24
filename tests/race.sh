#!/usr/bin/env bash
# Regressionstest fuer parallele Statuslines: jede offene Session ruft das Skript jede
# Sekunde auf, alle schreiben und lesen dieselben Account-Snapshots. Liest ein Lauf
# einen Snapshot, den ein anderer gerade schreibt, darf der zweite Account nicht fuer
# einen Frame aus der Zeile fallen. Vor dem atomaren Schreiben traf das rund 4 % der
# Frames, der Test ist also probabilistisch, schlaegt bei einer Regression aber mit
# hoher Wahrscheinlichkeit an.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
test_now=1788870000
workers=4
runs=40
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

HOME="$sandbox" STATUSLINE_NOW="$test_now" \
  bash "$root/tests/setup/zwei-accounts.sh" "$sandbox" >/dev/null

# Gibt je Lauf eine Zeile aus, wenn der zweite Account in der Limits-Zeile fehlt.
count_missing() {
  local line
  for _ in $(seq 1 "$runs"); do
    line=$(HOME="$sandbox" NO_COLOR=1 STATUSLINE_NOW="$test_now" \
      env -u ENABLE_PROMPT_CACHING_1H bash "$root/statusline.sh" \
      < "$root/tests/fixtures/zwei-accounts.json" | tail -1)
    case "$line" in *"B free"*) ;; *) echo "$line" ;; esac
  done
}

broken=$(for _ in $(seq 1 "$workers"); do count_missing & done; wait)
total=$((workers * runs))

if [ -n "$broken" ]; then
  printf 'FEHLER race: %d von %d Frames ohne zweiten Account\n%s\n' \
    "$(echo "$broken" | wc -l | tr -d ' ')" "$total" "$(echo "$broken" | sort -u)"
  exit 1
fi
printf 'ok     race (%d parallele Frames)\n' "$total"
