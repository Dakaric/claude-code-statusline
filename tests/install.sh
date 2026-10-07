#!/usr/bin/env bash
# Tests für install.sh. Jeder Fall bekommt eine eigene Sandbox: ein HOME, einen PATH nur
# aus Fakes und ausgewählten echten Werkzeugen, und ein Release-Verzeichnis, aus dem der
# curl-Fake liefert. Ein echtes cswap, uv, osacompile oder lsregister ist so nie
# erreichbar. Jeder Lauf bekommt --yes: ohne würde der Installer auf /dev/tty fragen und
# ein Test im Terminal hinge.
set -u

root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd) || exit 1
failed=0
sb=""
home=""
# Alle Sandboxen dieses Laufs liegen unter einem Ordner. drop_sandbox löscht nur dort.
run_root=$(mktemp -d) || exit 1
trap 'rm -rf -- "$run_root"' EXIT

# rm kann auf dem Entwicklerrechner ein Löschwächter sein, der seinen Ort mit readlink -f
# und dirname auflöst; deshalb gehören beide in die Sandbox. Nicht auf /bin/rm umbiegen,
# das umginge den Wächter. Die Probe am Ende von new_sandbox meldet, wenn rm dort nicht
# löscht, statt dass Löschwächter-Tests aus dem falschen Grund grün werden.
real_tools="bash env cat cp mv rm mkdir chmod grep awk sed date mktemp rmdir dirname readlink cmp jq sha256sum shasum"
fake_tools="curl uname uv osacompile PlistBuddy codesign lsregister xdg-mime update-desktop-database osascript notify-send"
# Der statusLine-Befehl, den der Installer schreibt. Die Tilde ist Text, kein Pfad.
# shellcheck disable=SC2088
managed_command="~/.claude/statusline.sh"

sha256_line() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

new_sandbox() {
  local tool real
  sb=$(mktemp -d "$run_root/sb.XXXXXX") || exit 1
  home="$sb/home"
  mkdir -p "$home" "$sb/bin" "$sb/tmp" "$sb/release" "$sb/cswap"
  for tool in $real_tools; do
    real=$(command -v "$tool") && ln -s "$real" "$sb/bin/$tool"
  done
  for tool in $fake_tools; do
    ln -s "$root/tests/fakes/$tool" "$sb/bin/$tool"
  done
  cp "$root/statusline.sh" "$sb/release/statusline.sh"
  (cd "$sb/release" && sha256_line statusline.sh > SHA256SUMS)
  : > "$sb/log"
  : > "$sb/probe"
  env -i PATH="$sb/bin" rm -f "$sb/probe" 2>/dev/null
  if [ -e "$sb/probe" ]; then
    printf 'FEHLER install: rm löscht in der Sandbox nicht, Tests wären nicht aussagekräftig\n'
    exit 1
  fi
}

drop_sandbox() {
  case "$sb" in
    "$run_root"/sb.*) rm -rf -- "$sb" ;;
    *) printf 'drop_sandbox verweigert: %s\n' "$sb" >&2; exit 1 ;;
  esac
}

# Zählt die Sicherungen von settings.json, ohne ls | grep.
count_backups() {
  local file count=0
  for file in "$home/.claude"/settings.json.bak-*; do
    [ -e "$file" ] && count=$((count + 1))
  done
  printf '%s' "$count"
}

run_installer() {
  env -i HOME="$home" TMPDIR="$sb/tmp" PATH="$sb/bin" FAKE_LOG="$sb/log" \
    FAKE_RELEASE_DIR="$sb/release" FAKE_DIR="$root/tests/fakes" FAKE_CSWAP_DIR="$sb/cswap" \
    FAKE_UNAME="${FAKE_UNAME:-Linux}" FAKE_FAIL="${FAKE_FAIL:-}" \
    "$BASH" "$root/install.sh" --yes "$@" < /dev/null > "$sb/out" 2>&1
}

has_log() { grep -qF -- "$1" "$sb/log"; }

fail() {
  printf 'FEHLER install %s\n' "$1"
  sed 's/^/    /' "$sb/out"
  failed=1
}

ok() { printf 'ok     install (%s)\n' "$1"; }

check_fresh_install() {
  new_sandbox
  if ! run_installer; then fail "frische Installation endet mit Fehler"
  elif [ ! -x "$home/.claude/statusline.sh" ]; then fail "statusline.sh fehlt oder ist nicht ausführbar"
  elif ! cmp -s "$home/.claude/statusline.sh" "$root/statusline.sh"; then fail "statusline.sh ist nicht die Release-Datei"
  elif [ "$(jq -r '.statusLine.command' "$home/.claude/settings.json")" != "$managed_command" ]; then
    fail "statusLine.command nicht gesetzt"
  elif [ -n "$(ls -A "$sb/tmp")" ]; then fail "Temp-Ordner nicht aufgeräumt"
  else ok "frische Installation"
  fi
  drop_sandbox
}

check_keeps_foreign_keys() {
  new_sandbox
  mkdir -p "$home/.claude" "$home/old"
  cp "$root/statusline.sh" "$home/old/statusline.sh"
  cat > "$home/.claude/settings.json" <<'JSON'
{"env":{"FOO":"1"},"hooks":{"Stop":[]},"theme":"dark",
 "statusLine":{"type":"command","command":"~/old/statusline.sh","refreshInterval":2}}
JSON
  cp "$home/.claude/settings.json" "$sb/original.json"
  run_installer
  local settings="$home/.claude/settings.json" backups
  backups=$(count_backups)
  if ! jq -e '.env.FOO == "1" and .hooks.Stop == [] and .theme == "dark"
      and .statusLine == {"type":"command","command":"~/.claude/statusline.sh","refreshInterval":2}' \
      "$settings" >/dev/null; then
    fail "fremde Schlüssel oder statusLine-Felder verändert"
  elif [ "$backups" != 1 ]; then fail "erwartet genau eine Sicherung, gefunden $backups"
  elif ! cmp -s "$home/.claude/"settings.json.bak-* "$sb/original.json"; then fail "Sicherung ist nicht das Original"
  elif ! cmp -s "$home/old/statusline.sh" "$root/statusline.sh"; then fail "alte Kopie wurde angefasst"
  elif ! grep -q 'Your previous copy at ~/old/statusline.sh was left in place' "$sb/out"; then fail "kein Hinweis auf die alte Kopie"
  else ok "fremde Schlüssel bleiben, alte Kopie wird umgehängt und bleibt liegen"
  fi
  drop_sandbox
}

# Steht die verwaltete Kopie mit absolutem Pfad drin, ist das keine andere Kopie: kein
# Hinweis, sie zu löschen.
check_absolute_managed_path() {
  new_sandbox
  run_installer
  jq --arg c "$home/.claude/statusline.sh" '.statusLine.command = $c' "$home/.claude/settings.json" > "$sb/s.json"
  mv "$sb/s.json" "$home/.claude/settings.json"
  run_installer
  if grep -q 'previous copy' "$sb/out"; then fail "verwaltete Kopie mit absolutem Pfad gilt als andere Kopie"
  elif [ "$(jq -r '.statusLine.command' "$home/.claude/settings.json")" != "$managed_command" ]; then
    fail "absoluter Pfad nicht auf die Tilde-Form gebracht"
  elif [ ! -e "$home/.claude/statusline.sh" ]; then fail "verwaltete Kopie fehlt"
  else ok "absoluter Pfad der verwalteten Kopie"
  fi
  drop_sandbox
}

check_foreign_statusline_kept() {
  new_sandbox
  mkdir -p "$home/.claude"
  printf '#!/bin/sh\necho other\n' > "$home/other.sh"
  printf '{"statusLine":{"type":"command","command":"~/other.sh"}}\n' > "$home/.claude/settings.json"
  cp "$home/.claude/settings.json" "$sb/original.json"
  if ! run_installer; then fail "fremde Statusline führt zum Abbruch"
  elif ! cmp -s "$home/.claude/settings.json" "$sb/original.json"; then fail "fremde Statusline wurde ohne Nachfrage ersetzt"
  elif ! grep -q 'Kept your status line' "$sb/out"; then fail "kein Hinweis auf die behaltene Statusline"
  else ok "fremde Statusline bleibt bei --yes"
  fi
  drop_sandbox
}

# settings.json kann Tokens in env tragen. Ihre Rechte bleiben, wie sie waren.
check_settings_mode_kept() {
  new_sandbox
  mkdir -p "$home/.claude"
  printf '{"env":{"TOKEN":"x"}}\n' > "$home/.claude/settings.json"
  chmod 600 "$home/.claude/settings.json"
  if ! run_installer; then fail "Installer endet mit Fehler"
  elif ! jq -e '.statusLine.command == "~/.claude/statusline.sh" and .env.TOKEN == "x"' \
      "$home/.claude/settings.json" >/dev/null; then fail "settings.json nicht geschrieben oder Token verloren"
  elif [ -z "$(find "$home/.claude/settings.json" -perm 600)" ]; then
    fail "settings.json hat ihre Rechte 600 verloren"
  else ok "Rechte von settings.json bleiben"
  fi
  drop_sandbox
}

# Ein Symlink, etwa in ein Dotfiles-Repo, bleibt ein Symlink; geschrieben wird ins Ziel.
check_settings_symlink_kept() {
  new_sandbox
  mkdir -p "$home/.claude" "$home/dotfiles"
  printf '{"theme":"dark"}\n' > "$home/dotfiles/settings.json"
  ln -s "$home/dotfiles/settings.json" "$home/.claude/settings.json"
  run_installer
  if [ ! -L "$home/.claude/settings.json" ]; then fail "Symlink auf settings.json wurde ersetzt"
  elif ! jq -e '.theme == "dark" and .statusLine.command == "~/.claude/statusline.sh"' \
      "$home/dotfiles/settings.json" >/dev/null; then fail "Ziel des Symlinks nicht richtig beschrieben"
  else ok "settings.json als Symlink"
  fi
  drop_sandbox
}

# Eine leere settings.json (touch) gilt wie eine fehlende.
check_empty_settings() {
  new_sandbox
  mkdir -p "$home/.claude"
  : > "$home/.claude/settings.json"
  if ! run_installer; then fail "leere settings.json bricht ab"
  elif ! jq -e '.statusLine.command == "~/.claude/statusline.sh"' "$home/.claude/settings.json" >/dev/null; then
    fail "leere settings.json nicht befüllt"
  else ok "leere settings.json"
  fi
  drop_sandbox
}

# Eine vorhandene verwaltete Kopie wird vor dem Ersetzen gesichert; ein Symlink an ihrer
# Stelle (etwa in einen Checkout) bleibt unangetastet.
check_existing_statusline_backed_up() {
  new_sandbox
  mkdir -p "$home/.claude"
  printf '# angepasst\n' > "$home/.claude/statusline.sh"
  run_installer
  if [ "$(cat "$home/.claude/statusline.sh.bak" 2>/dev/null)" != '# angepasst' ]; then
    fail "vorhandene statusline.sh nicht gesichert"
  elif ! cmp -s "$home/.claude/statusline.sh" "$root/statusline.sh"; then fail "statusline.sh nicht ersetzt"
  else ok "vorhandene statusline.sh wird gesichert"
  fi
  drop_sandbox
  new_sandbox
  mkdir -p "$home/.claude" "$home/checkout"
  printf '# checkout\n' > "$home/checkout/statusline.sh"
  ln -s "$home/checkout/statusline.sh" "$home/.claude/statusline.sh"
  run_installer
  if [ ! -L "$home/.claude/statusline.sh" ]; then fail "Symlink auf statusline.sh wurde ersetzt"
  elif [ "$(cat "$home/checkout/statusline.sh")" != '# checkout' ]; then fail "Ziel des Symlinks wurde überschrieben"
  elif ! grep -q 'is a symlink' "$sb/out"; then fail "kein Hinweis auf den Symlink"
  else ok "statusline.sh als Symlink bleibt"
  fi
  drop_sandbox
}

check_bad_checksum_keeps_old_file() {
  new_sandbox
  mkdir -p "$home/.claude"
  printf 'OLD\n' > "$home/.claude/statusline.sh"
  printf '%064d  statusline.sh\n' 0 > "$sb/release/SHA256SUMS"
  if run_installer; then fail "falsche Prüfsumme endet ohne Fehler"
  elif ! grep -q 'checksum mismatch for statusline.sh' "$sb/out"; then fail "Abbruch nicht wegen der Prüfsumme"
  elif ! has_log 'SHA256SUMS'; then fail "SHA256SUMS wurde nie geladen"
  elif [ "$(cat "$home/.claude/statusline.sh")" != OLD ]; then fail "alte statusline.sh wurde überschrieben"
  elif [ -e "$home/.claude/settings.json" ]; then fail "settings.json trotz Abbruch angelegt"
  else ok "falsche Prüfsumme lässt alte Datei stehen"
  fi
  drop_sandbox
}

check_missing_checksum_line_fails() {
  new_sandbox
  printf '%s  other.sh\n' "$(printf '%064d' 1)" > "$sb/release/SHA256SUMS"
  if run_installer; then fail "fehlende Prüfsummenzeile endet ohne Fehler"
  elif ! grep -q 'checksum mismatch for statusline.sh' "$sb/out"; then fail "Abbruch nicht wegen der Prüfsumme"
  elif ! has_log 'SHA256SUMS'; then fail "SHA256SUMS wurde nie geladen"
  elif [ -e "$home/.claude/statusline.sh" ]; then fail "statusline.sh ohne Prüfsumme installiert"
  else ok "fehlende Prüfsummenzeile bricht ab"
  fi
  drop_sandbox
}

check_invalid_settings_aborts() {
  new_sandbox
  mkdir -p "$home/.claude"
  printf '{ kaputt' > "$home/.claude/settings.json"
  if run_installer; then fail "ungültiges JSON endet ohne Fehler"
  elif ! grep -q 'is not a valid JSON object' "$sb/out"; then fail "Abbruch nicht wegen ungültigem JSON"
  elif [ "$(cat "$home/.claude/settings.json")" != '{ kaputt' ]; then fail "ungültige settings.json verändert"
  elif [ "$(count_backups)" != 0 ]; then fail "Sicherung trotz Abbruch angelegt"
  elif [ -e "$home/.claude/statusline.sh" ]; then fail "statusline.sh trotz Abbruch installiert"
  else ok "ungültiges JSON bricht vor jeder Änderung ab"
  fi
  drop_sandbox
}

check_release_tag() {
  new_sandbox
  run_installer
  has_log 'releases/latest/download/statusline.sh' || fail "ohne --version nicht das neueste Release"
  : > "$sb/log"
  run_installer --version v1.6.0
  if has_log 'releases/download/v1.6.0/statusline.sh'; then ok "--version wählt das Release"
  else fail "--version v1.6.0 lädt nicht aus diesem Release"
  fi
  if run_installer --version 'v1.6.0/../x'; then fail "unsinniger Tag wird angenommen"
  elif ! grep -q -- '--version expects a tag' "$sb/out"; then fail "unsinniger Tag aus falschem Grund abgewiesen"
  fi
  drop_sandbox
}

check_windows_refused() {
  new_sandbox
  if FAKE_UNAME=MINGW64_NT-10.0 run_installer; then fail "Windows endet ohne Fehler"
  elif ! grep -q 'Windows is not supported yet' "$sb/out"; then fail "kein Hinweis auf Windows"
  else ok "Windows wird abgewiesen"
  fi
  drop_sandbox
}

check_jq_missing() {
  new_sandbox
  rm -f "$sb/bin/jq"
  if run_installer; then fail "fehlendes jq endet ohne Fehler"
  elif ! grep -q 'jq is required' "$sb/out"; then fail "kein Hinweis auf jq"
  else ok "fehlendes jq bricht mit Hinweis ab"
  fi
  drop_sandbox
}

# Leer, /, relativ, und Pfade, die sich erst aufgelöst als / erweisen.
check_home_guard() {
  local bad before=$failed
  new_sandbox
  for bad in "" "/" "relativ/pfad" "//" "/.."; do
    # Im Sandbox-Ordner gestartet: ein Rückfall des Wächters mit relativem HOME legt seine
    # Dateien hier an und nicht im Checkout.
    if (cd "$sb" && env -i HOME="$bad" TMPDIR="$sb/tmp" PATH="$sb/bin" FAKE_LOG="$sb/log" \
        FAKE_RELEASE_DIR="$sb/release" "$BASH" "$root/install.sh" --yes < /dev/null > "$sb/out" 2>&1); then
      fail "HOME='$bad' wird angenommen"
    elif ! grep -q 'HOME must' "$sb/out"; then
      fail "HOME='$bad': Abbruch nicht durch den HOME-Wächter"
    fi
  done
  [ -s "$sb/log" ] && fail "bei unbrauchbarem HOME wurde trotzdem etwas aufgerufen"
  [ "$failed" = "$before" ] && ok "unbrauchbares HOME bricht vor allem anderen ab"
  drop_sandbox
}

# Statischer Wächter: rekursives Löschen gibt es nur an einer Stelle, in safe_remove_tree.
check_single_recursive_delete() {
  local count others
  count=$(grep -cE 'rm([[:space:]]+-[a-zA-Z]*)*[[:space:]]+(-[a-zA-Z]*[rR]|--recursive)' "$root/install.sh")
  others=$(grep -nE 'find .*-delete|rmtree' "$root/install.sh")
  if [ "$count" != 1 ] || [ -n "$others" ]; then
    printf 'FEHLER install rekursives Löschen an %s Stellen\n%s\n' "$count" "$others"
    failed=1
  else
    printf 'ok     install (rekursives Löschen nur in safe_remove_tree)\n'
  fi
}

# TMP_DIR ist die Positivliste von safe_remove_tree. Nach make_tmp_dir darf eine
# Zuweisung sie nicht mehr verbiegen können. Die Bibliothek ist install.sh ohne die
# letzte Zeile, so läuft keine main.
check_tmp_dir_readonly() {
  new_sandbox
  mkdir -p "$sb/other"
  : > "$sb/other/sentinel"
  sed '$d' "$root/install.sh" > "$sb/lib.sh"
  cat > "$sb/probe.sh" <<PROBE
. "$sb/lib.sh"
init_paths
make_tmp_dir
( TMP_DIR="$sb/other"; safe_remove_tree "$sb/other" ) 2>/dev/null
exit "\$?"
PROBE
  if env -i HOME="$home" TMPDIR="$sb/tmp" PATH="$sb/bin" "$BASH" "$sb/probe.sh" > "$sb/out" 2>&1; then fail "TMP_DIR lässt sich nach make_tmp_dir neu zuweisen"
  elif [ ! -e "$sb/other/sentinel" ]; then fail "fremder Ordner wurde gelöscht"
  else ok "TMP_DIR ist nach make_tmp_dir schreibgeschützt"
  fi
  drop_sandbox
}

# Ein Ordner an der Stelle der verwalteten Kopie darf nicht dazu führen, dass mv die Datei
# hineinschiebt.
check_statusline_is_directory() {
  new_sandbox
  mkdir -p "$home/.claude/statusline.sh"
  if run_installer; then fail "Ordner statt statusline.sh endet ohne Fehler"
  elif ! grep -q 'is not a regular file' "$sb/out"; then fail "kein Hinweis auf den Ordner"
  elif [ -e "$home/.claude/statusline.sh/statusline.sh" ]; then fail "Datei in den Ordner geschoben"
  else ok "Ordner statt statusline.sh bricht ab"
  fi
  drop_sandbox
}

unmanaged_status() {
  printf '{"schemaVersion":1,"active":{"email":"a@example.com","managed":false}}\n' > "$sb/cswap/status.json"
}

check_default_is_swap_off() {
  new_sandbox
  run_installer
  if [ "$(grep '^swap=' "$home/.claude/statusline/config")" != swap=off ]; then fail "--yes ohne Flag speichert nicht swap=off"
  elif has_log 'uv ' || has_log 'cswap '; then fail "swap=off ruft trotzdem uv oder cswap"
  elif [ -e "$home/.claude/statusline/switch-handler" ]; then fail "Marker trotz swap=off"
  else ok "Vorgabe ist swap=off"
  fi
  drop_sandbox
}

check_swap_macos() {
  new_sandbox
  unmanaged_status
  local app="$home/Applications/Claude Statusline Switch.app"
  if ! FAKE_UNAME=Darwin run_installer --swap; then fail "macOS --swap endet mit Fehler"
  elif ! has_log 'uv tool install claude-swap'; then fail "cswap nicht über uv installiert"
  elif ! has_log 'cswap add'; then fail "ungemanagtes Konto nicht aufgenommen"
  elif ! has_log "osacompile -o $app"; then fail "App nicht gebaut"
  elif ! has_log 'CFBundleURLSchemes:0 string claude-statusline'; then fail "URL-Schema nicht eingetragen"
  elif ! has_log 'LSUIElement bool true'; then fail "App nicht als Hintergrund-App markiert"
  elif ! has_log "codesign --force --sign - $app"; then fail "App nicht neu signiert"
  elif ! has_log "lsregister -f $app"; then fail "App nicht registriert"
  elif [ "$(awk '/^codesign /{print NR; exit}' "$sb/log")" -le "$(awk '/^PlistBuddy /{n=NR} END{print n+0}' "$sb/log")" ]; then
    fail "codesign läuft vor der letzten Plist-Änderung, die Signatur wäre ungültig"
  elif [ "$(awk '/^lsregister -f /{print NR; exit}' "$sb/log")" -le "$(awk '/^codesign /{print NR; exit}' "$sb/log")" ]; then
    fail "lsregister läuft vor codesign"
  elif ! grep -q 'on open location' "$app/Contents/source.applescript"; then fail "AppleScript ohne open location"
  elif ! grep -q '.claude/statusline/switch-handler.sh' "$app/Contents/source.applescript"; then fail "AppleScript ruft den Handler nicht"
  elif ! grep -qF "CSWAP_BIN=$home/.local/bin/cswap" "$home/.claude/statusline/switch-handler.sh"; then fail "Handler kennt cswap nicht"
  elif [ ! -x "$home/.claude/statusline/switch-handler.sh" ]; then fail "Handler nicht ausführbar"
  elif [ ! -e "$home/.claude/statusline/switch-handler" ]; then fail "Marker fehlt"
  elif [ "$(grep '^swap=' "$home/.claude/statusline/config")" != swap=on ]; then fail "swap=on nicht gespeichert"
  else ok "macOS: cswap, App, Registrierung, Marker"
  fi
  drop_sandbox
}

check_swap_linux() {
  new_sandbox
  unmanaged_status
  local desktop="$home/.local/share/applications/claude-statusline-switch.desktop"
  if ! FAKE_UNAME=Linux run_installer --swap; then fail "Linux --swap endet mit Fehler"
  elif ! grep -qx 'MimeType=x-scheme-handler/claude-statusline;' "$desktop"; then fail "Desktop-Datei ohne MimeType"
  elif ! grep -qxF "Exec=\"$home/.claude/statusline/switch-handler.sh\" %u" "$desktop"; then fail "Desktop-Datei ohne Exec"
  elif ! has_log 'xdg-mime default claude-statusline-switch.desktop x-scheme-handler/claude-statusline'; then fail "xdg-mime nicht gesetzt"
  elif has_log 'osacompile'; then fail "Linux baut eine macOS-App"
  elif [ ! -e "$home/.claude/statusline/switch-handler" ]; then fail "Marker fehlt"
  else ok "Linux: Desktop-Datei, xdg-mime, Marker"
  fi
  drop_sandbox
}

check_managed_account_not_readded() {
  new_sandbox
  printf '{"schemaVersion":1,"active":{"email":"a@example.com","managed":true}}\n' > "$sb/cswap/status.json"
  if ! run_installer --swap; then fail "--swap mit gemanagtem Konto endet mit Fehler"
  elif ! has_log 'cswap status --json'; then fail "Kontostand nie abgefragt"
  elif has_log 'cswap add'; then fail "gemanagtes Konto erneut aufgenommen"
  elif [ ! -e "$home/.claude/statusline/switch-handler" ]; then fail "Marker fehlt"
  else ok "gemanagtes Konto bleibt"
  fi
  drop_sandbox
}

check_not_logged_in() {
  new_sandbox
  if ! run_installer --swap; then fail "ohne Login endet --swap mit Fehler"
  elif has_log 'cswap add'; then fail "ohne Login cswap add aufgerufen"
  elif ! grep -q 'not logged in' "$sb/out"; then fail "keine Anleitung ohne Login"
  else ok "ohne Login nur Anleitung"
  fi
  drop_sandbox
}

check_swap_off_respected_on_update() {
  new_sandbox
  mkdir -p "$home/.claude/statusline"
  printf 'swap=off\n' > "$home/.claude/statusline/config"
  if ! run_installer; then fail "Update mit swap=off endet mit Fehler"
  elif has_log 'uv ' || has_log 'cswap ' || has_log 'xdg-mime'; then fail "Update ignoriert swap=off"
  elif ! grep -q 'Click-to-switch is off' "$sb/out"; then fail "kein Hinweis auf swap=off"
  elif [ "$(grep '^swap=' "$home/.claude/statusline/config")" != swap=off ]; then fail "swap=off nicht erhalten"
  else ok "Update respektiert swap=off"
  fi
  drop_sandbox
}

check_no_swap_removes_handler() {
  new_sandbox
  unmanaged_status
  local desktop="$home/.local/share/applications/claude-statusline-switch.desktop"
  if ! FAKE_UNAME=Linux run_installer --swap; then fail "Vorbedingung: --swap endet mit Fehler"
  elif [ ! -e "$home/.claude/statusline/switch-handler" ] || [ ! -e "$desktop" ]; then
    fail "Vorbedingung: --swap legt Marker und Desktop-Datei nicht an"
  elif ! FAKE_UNAME=Linux run_installer --no-swap; then fail "--no-swap endet mit Fehler"
  elif [ -e "$home/.claude/statusline/switch-handler" ]; then fail "--no-swap lässt den Marker stehen"
  elif [ -e "$home/.claude/statusline/switch-handler.sh" ]; then fail "--no-swap lässt den Handler stehen"
  elif [ -e "$home/.local/share/applications/claude-statusline-switch.desktop" ]; then fail "--no-swap lässt die Desktop-Datei stehen"
  elif [ "$(grep '^swap=' "$home/.claude/statusline/config")" != swap=off ]; then fail "--no-swap speichert nicht swap=off"
  else ok "--no-swap baut den Handler ab"
  fi
  drop_sandbox
}

check_update_upgrades_cswap() {
  new_sandbox
  unmanaged_status
  run_installer --swap
  : > "$sb/log"
  run_installer
  if ! has_log 'uv tool upgrade claude-swap'; then fail "Update aktualisiert cswap nicht"
  elif has_log 'uv tool install claude-swap'; then fail "Update installiert cswap neu"
  else ok "Update aktualisiert cswap"
  fi
  drop_sandbox
}

check_registration_failure_leaves_no_marker() {
  new_sandbox
  unmanaged_status
  if ! FAKE_UNAME=Darwin FAKE_FAIL=lsregister run_installer --swap; then fail "gescheiterte Registrierung bricht den Installer ab"
  elif [ -e "$home/.claude/statusline/switch-handler" ]; then fail "Marker trotz gescheiterter Registrierung"
  elif ! grep -q 'Click-to-switch is not active' "$sb/out"; then fail "kein Hinweis auf die gescheiterte Registrierung"
  else ok "gescheiterte Registrierung schreibt keinen Marker"
  fi
  drop_sandbox
}

check_without_uv_or_pipx() {
  new_sandbox
  rm -f "$sb/bin/uv"
  if ! run_installer --swap; then fail "ohne uv und pipx endet --swap mit Fehler"
  elif has_log 'astral'; then fail "uv-Installer ohne ausdrückliches Ja aufgerufen"
  elif [ -e "$home/.claude/statusline/switch-handler" ]; then fail "Marker ohne cswap"
  elif ! grep -q 'uv or pipx' "$sb/out"; then fail "kein Hinweis auf uv oder pipx"
  else ok "ohne uv und pipx nur Hinweis"
  fi
  drop_sandbox
}

check_pipx_fallback() {
  new_sandbox
  unmanaged_status
  rm -f "$sb/bin/uv"
  ln -s "$root/tests/fakes/pipx" "$sb/bin/pipx"
  run_installer --swap
  if has_log 'pipx install claude-swap' && [ -e "$home/.claude/statusline/switch-handler" ]; then ok "pipx als Ersatz für uv"
  else fail "pipx-Weg installiert cswap nicht"
  fi
  drop_sandbox
}

check_switch_url_note() {
  new_sandbox
  unmanaged_status
  mkdir -p "$home/.claude"
  printf '{"env":{"CLAUDE_STATUSLINE_SWITCH_URL":"http://localhost:7373/x"}}\n' > "$home/.claude/settings.json"
  run_installer --swap
  if grep -q 'CLAUDE_STATUSLINE_SWITCH_URL is set' "$sb/out"; then ok "Hinweis auf gesetzte Link-Variable"
  else fail "kein Hinweis auf CLAUDE_STATUSLINE_SWITCH_URL"
  fi
  drop_sandbox
}

check_swap_off_macos_touches_nothing() {
  new_sandbox
  if ! FAKE_UNAME=Darwin run_installer; then fail "macOS ohne Swap endet mit Fehler"
  elif has_log 'osacompile' || has_log 'PlistBuddy' || has_log 'codesign' || has_log 'lsregister'; then
    fail "macOS mit swap=off ruft Registrierungswerkzeuge"
  else ok "macOS mit swap=off rührt nichts an"
  fi
  drop_sandbox
}

check_no_swap_macos_removes_app() {
  new_sandbox
  unmanaged_status
  local app="$home/Applications/Claude Statusline Switch.app"
  FAKE_UNAME=Darwin run_installer --swap
  if [ ! -d "$app" ]; then fail "Vorbedingung: --swap baut keine App"
  elif ! FAKE_UNAME=Darwin run_installer --no-swap; then fail "macOS --no-swap endet mit Fehler"
  elif ! has_log "lsregister -u $app"; then fail "App nicht bei LaunchServices abgemeldet"
  elif [ -e "$app" ]; then fail "App bleibt nach --no-swap"
  else ok "macOS --no-swap entfernt die App"
  fi
  drop_sandbox
}

# Scheitert die Registrierung mittendrin, bleibt nichts Halbfertiges liegen.
check_partial_registration_cleaned_up() {
  new_sandbox
  unmanaged_status
  FAKE_UNAME=Darwin FAKE_FAIL=codesign run_installer --swap
  if [ -e "$home/Applications/Claude Statusline Switch.app" ]; then fail "unsignierte App bleibt liegen"
  elif [ -e "$home/.claude/statusline/switch-handler" ]; then fail "Marker trotz gescheiterter Signatur"
  else ok "gescheiterte Signatur räumt die App weg"
  fi
  drop_sandbox
  new_sandbox
  unmanaged_status
  FAKE_UNAME=Linux FAKE_FAIL=xdg-mime run_installer --swap
  if [ -e "$home/.local/share/applications/claude-statusline-switch.desktop" ]; then fail "Desktop-Datei ohne Zuordnung bleibt liegen"
  elif [ -e "$home/.claude/statusline/switch-handler" ]; then fail "Marker trotz gescheitertem xdg-mime"
  else ok "gescheitertes xdg-mime räumt die Desktop-Datei weg"
  fi
  drop_sandbox
}

check_fresh_install
check_keeps_foreign_keys
check_absolute_managed_path
check_foreign_statusline_kept
check_settings_mode_kept
check_settings_symlink_kept
check_empty_settings
check_existing_statusline_backed_up
check_bad_checksum_keeps_old_file
check_missing_checksum_line_fails
check_invalid_settings_aborts
check_release_tag
check_windows_refused
check_jq_missing
check_home_guard
check_tmp_dir_readonly
check_statusline_is_directory
check_default_is_swap_off
check_swap_macos
check_swap_linux
check_managed_account_not_readded
check_not_logged_in
check_swap_off_respected_on_update
check_no_swap_removes_handler
check_update_upgrades_cswap
check_registration_failure_leaves_no_marker
check_without_uv_or_pipx
check_pipx_fallback
check_switch_url_note
check_swap_off_macos_touches_nothing
check_no_swap_macos_removes_app
check_partial_registration_cleaned_up
check_single_recursive_delete
exit "$failed"
