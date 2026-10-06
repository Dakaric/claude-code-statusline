#!/usr/bin/env bash
# Gemeinsame Umgebung fuer run.sh und freeze.sh. load_fixture_env NAME fuellt das
# globale Array extra_env aus tests/env/NAME.env (eine KEY=VALUE-Zuweisung pro Zeile).
# Fehlt die Datei, bleibt es leer. $root setzt der aufrufende Test.
# shellcheck disable=SC2154
load_fixture_env() {
  extra_env=()
  local envfile line
  envfile="$root/tests/env/$1.env"
  [ -f "$envfile" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && extra_env+=("$line")
  done < "$envfile"
  return 0
}
