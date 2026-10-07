#!/usr/bin/env bash
# Installer und Updater für claude-code-statusline.
#
#   curl -fsSL https://github.com/Dakaric/claude-code-statusline/releases/latest/download/install.sh | bash
#
# Ein erneuter Lauf ist das Update. Der ganze Ablauf steht in Funktionen, ausgeführt wird
# erst mit der letzten Zeile: reißt der Download mittendrin ab, läuft kein halbes Skript.
# Läuft unter bash 3.2, der Shell von macOS.
set -u

REPO="Dakaric/claude-code-statusline"
APP_NAME="Claude Statusline Switch.app"
URL_SCHEME="claude-statusline"
DESKTOP_NAME="claude-statusline-switch.desktop"
BUNDLE_ID="io.github.dakaric.claude-statusline-switch"
# Bleibt bewusst unexpandiert: Claude Code löst die Tilde selbst auf, und der Eintrag
# in settings.json bleibt so auch nach einem Umzug des Home-Ordners richtig.
# shellcheck disable=SC2088
STATUSLINE_COMMAND="~/.claude/statusline.sh"
# Werkzeuge von macOS außerhalb des PATH. Angehängt statt vorangestellt: ein Werkzeug
# gleichen Namens weiter vorn im PATH gewinnt, darauf bauen die Tests.
MACOS_TOOL_DIRS="/usr/libexec:/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support"

ASSUME_YES=0
SWAP_FLAG=""
UNINSTALL=0
RELEASE_TAG=""
TMP_DIR=""
OS=""

die() { printf 'claude-code-statusline: %s\n' "$*" >&2; exit 1; }
warn() { printf 'claude-code-statusline: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

print_usage() {
  cat <<'USAGE'
Usage: install.sh [--yes] [--swap | --no-swap] [--version vX.Y.Z] [--uninstall]

  --yes          answer every question with its default
  --swap         set up click-to-switch between accounts
  --no-swap      turn click-to-switch off
  --version TAG  install this release instead of the latest
  --uninstall    remove everything this installer added
USAGE
}

parse_args() {
  local tag_re='^v[0-9]+\.[0-9]+\.[0-9]+$'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes|-y) ASSUME_YES=1 ;;
      --swap) SWAP_FLAG=on ;;
      --no-swap) SWAP_FLAG=off ;;
      --uninstall) UNINSTALL=1 ;;
      --version)
        [ "$#" -ge 2 ] || die "--version needs a tag, for example --version v1.6.0"
        RELEASE_TAG=$2
        shift ;;
      -h|--help) print_usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  if [ -n "$RELEASE_TAG" ] && ! [[ $RELEASE_TAG =~ $tag_re ]]; then
    die "--version expects a tag like v1.6.0, got '$RELEASE_TAG'"
  fi
}

# Alle Pfade hängen an HOME. Ein leeres, relatives oder auf / zeigendes HOME bricht ab,
# bevor irgendetwas angefasst wird.
init_paths() {
  case "${HOME:-}" in
    /?*) ;;
    *) die "HOME must be an absolute path other than /, got '${HOME:-}'" ;;
  esac
  # bash 3.2 meldet das Wurzelverzeichnis über // als "//", beides ist /.
  case "$(resolve_dir "$HOME")" in
    /|//) die "HOME must not resolve to /, got '$HOME'" ;;
  esac
  CLAUDE_DIR="$HOME/.claude"
  STATUSLINE_PATH="$CLAUDE_DIR/statusline.sh"
  SETTINGS_PATH="$CLAUDE_DIR/settings.json"
  STATE_DIR="$CLAUDE_DIR/statusline"
  CONFIG_PATH="$STATE_DIR/config"
  HANDLER_PATH="$STATE_DIR/switch-handler.sh"
  MARKER_PATH="$STATE_DIR/switch-handler"
  APP_PATH="$HOME/Applications/$APP_NAME"
  DESKTOP_PATH="$HOME/.local/share/applications/$DESKTOP_NAME"
}

detect_os() {
  case "$(uname -s)" in
    Darwin)
      OS=macos
      PATH="$PATH:$MACOS_TOOL_DIRS" ;;
    Linux) OS=linux ;;
    *) die "this installer supports macOS and Linux. Windows is not supported yet." ;;
  esac
}

# Unter sh (dash) liefe das Skript halb: [[ und local gibt es dort nicht verlässlich.
require_bash() {
  [ -n "${BASH_VERSION:-}" ] && return 0
  printf 'claude-code-statusline: run this installer with bash, for example: curl -fsSL <url> | bash\n' >&2
  exit 1
}

require_jq() {
  local hint="install it with your package manager"
  command -v jq >/dev/null 2>&1 && return 0
  if command -v brew >/dev/null 2>&1; then hint="brew install jq"
  elif command -v apt-get >/dev/null 2>&1; then hint="sudo apt-get install jq"
  elif command -v dnf >/dev/null 2>&1; then hint="sudo dnf install jq"
  elif command -v pacman >/dev/null 2>&1; then hint="sudo pacman -S jq"
  fi
  die "jq is required. Install it first: $hint"
}

# Antworten kommen nie von stdin: bei curl | bash ist stdin das Skript selbst. Gefragt
# wird über /dev/tty. Gibt es keins, gilt --yes.
init_prompt() {
  [ "$ASSUME_YES" = 1 ] && return 0
  if ! { : < /dev/tty; } 2>/dev/null; then
    info "No terminal to ask on, continuing with the defaults (--yes)."
    ASSUME_YES=1
  fi
}

# ask_yes_no FRAGE VORGABE: VORGABE ist y oder n. Rückgabe 0 heißt Ja.
ask_yes_no() {
  local question=$1 default=$2 hint="[y/N]" reply=""
  [ "$default" = y ] && hint="[Y/n]"
  if [ "$ASSUME_YES" = 1 ]; then
    [ "$default" = y ]
    return
  fi
  printf '%s %s ' "$question" "$hint" > /dev/tty
  IFS= read -r reply < /dev/tty || reply=""
  case "$reply" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    [Nn]|[Nn][Oo]) return 1 ;;
    *) [ "$default" = y ] ;;
  esac
}

# --- Antworten merken ---
# Eine schluessel=wert-Zeile je Einstellung. Gelesen wird zeilenweise, nie per source:
# die Datei ist Text, kein Code.
config_get() {
  local line
  [ -f "$CONFIG_PATH" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$1="*) printf '%s' "${line#*=}"; return 0 ;; esac
  done < "$CONFIG_PATH"
}

config_set() {
  local key=$1 value=$2 line tmp
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  tmp="$CONFIG_PATH.tmp.$$"
  if {
    if [ -f "$CONFIG_PATH" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$key="*) ;; *) printf '%s\n' "$line" ;; esac
      done < "$CONFIG_PATH"
    fi
    printf '%s=%s\n' "$key" "$value"
  } > "$tmp" && mv -f "$tmp" "$CONFIG_PATH"; then
    return 0
  fi
  rm -f "$tmp"
  die "cannot write $CONFIG_PATH"
}

# --- Löschen nur innerhalb einer Positivliste ---
# Rekursiv gelöscht wird nur das eigene mktemp -d dieses Laufs und genau der App-Pfad.
# Verglichen wird der aufgelöste Pfad: ein Symlink, auf dem Weg oder am Ende, darf das
# Löschen nicht nach außen umlenken. Alles andere bricht ab, statt zu löschen.
resolve_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

safe_remove_tree() {
  local path=$1 resolved home_resolved allowed_tmp=""
  [ -e "$path" ] || [ -L "$path" ] || return 0
  [ -L "$path" ] && die "refusing to delete $path: it is a symlink"
  resolved=$(resolve_dir "$path") || die "refusing to delete $path: cannot resolve it"
  home_resolved=$(resolve_dir "$HOME") || die "refusing to delete $path: cannot resolve HOME"
  [ -n "$TMP_DIR" ] && allowed_tmp=$(resolve_dir "$TMP_DIR")
  if [ "$resolved" != "$home_resolved/Applications/$APP_NAME" ] \
    && { [ -z "$allowed_tmp" ] || [ "$resolved" != "$allowed_tmp" ]; }; then
    die "refusing to delete $resolved: not on the list of paths this installer may delete"
  fi
  rm -rf -- "$resolved"
}

make_tmp_dir() {
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline.XXXXXX") \
    || die "cannot create a temporary directory"
  trap 'safe_remove_tree "$TMP_DIR"' EXIT
}

# --- Release laden und prüfen ---
release_url() {
  if [ -n "$RELEASE_TAG" ]; then
    printf 'https://github.com/%s/releases/download/%s/%s' "$REPO" "$RELEASE_TAG" "$1"
  else
    printf 'https://github.com/%s/releases/latest/download/%s' "$REPO" "$1"
  fi
}

# download DATEI ZIEL. Die Form -fsSL -o ZIEL URL ist fest, der Test-Fake verlässt sich darauf.
download() { curl -fsSL -o "$2" "$(release_url "$1")"; }

sha256_of() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$1") || return 1
  else
    out=$(shasum -a 256 "$1") || return 1
  fi
  printf '%s' "${out%% *}"
}

# Die Prüfsumme einer Datei aus SHA256SUMS. Fehlt ihre Zeile, ist das Ergebnis leer und
# die Prüfung scheitert, statt wie bei --ignore-missing still durchzugehen.
expected_sum() {
  awk -v f="$2" '$2 == f || $2 == ("*" f) { print $1; exit }' "$1"
}

install_statusline() {
  local new="$TMP_DIR/statusline.sh" sums="$TMP_DIR/SHA256SUMS" want got staged
  command -v curl >/dev/null 2>&1 || die "curl is required"
  download statusline.sh "$new" || die "could not download statusline.sh"
  download SHA256SUMS "$sums" || die "could not download SHA256SUMS"
  want=$(expected_sum "$sums" statusline.sh)
  got=$(sha256_of "$new")
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    die "checksum mismatch for statusline.sh. Your installed copy was left untouched."
  fi
  mkdir -p "$CLAUDE_DIR" || die "cannot create $CLAUDE_DIR"
  # Ein Symlink an dieser Stelle zeigt meist in einen Checkout. Den überschreibt kein Update.
  if [ -L "$STATUSLINE_PATH" ]; then
    warn "$STATUSLINE_PATH is a symlink, left it alone. Update its target yourself, or remove the link and run the installer again."
    return 0
  fi
  # Eine vorhandene Datei kann von Hand angepasst sein. Sie wird gesichert, die Sicherung
  # des vorigen Laufs dabei ersetzt.
  if [ -f "$STATUSLINE_PATH" ] && ! cmp -s "$new" "$STATUSLINE_PATH"; then
    cp -p "$STATUSLINE_PATH" "$STATUSLINE_PATH.bak" || die "cannot back up $STATUSLINE_PATH"
    info "Saved your previous $STATUSLINE_PATH as $STATUSLINE_PATH.bak"
  fi
  staged="$CLAUDE_DIR/.statusline.sh.new.$$"
  if ! { cp "$new" "$staged" && chmod 755 "$staged" && mv -f "$staged" "$STATUSLINE_PATH"; }; then
    rm -f "$staged"
    die "cannot write $STATUSLINE_PATH"
  fi
  info "Installed $("$STATUSLINE_PATH" --version) to $STATUSLINE_PATH"
}

# --- settings.json ---
# Eine leere settings.json (etwa nach touch) gilt wie eine fehlende.
check_settings_readable() {
  [ -s "$SETTINGS_PATH" ] || return 0
  jq -e 'type == "object"' "$SETTINGS_PATH" >/dev/null 2>&1 \
    || die "$SETTINGS_PATH is not a valid JSON object. Nothing was changed."
}

current_statusline_command() {
  [ -s "$SETTINGS_PATH" ] || return 0
  jq -r '.statusLine.command // "" | tostring' "$SETTINGS_PATH"
}

# Der Dateipfad hinter einem statusLine-Befehl: ein einzelner Pfad, mit ~/ am Anfang oder
# absolut. Alles andere, etwa ein Befehl mit Argumenten, ergibt keinen Pfad.
command_path() {
  case "$1" in
    ""|*[[:space:]]*) return 1 ;;
    \~/*) printf '%s' "$HOME/${1#\~/}" ;;
    /*) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

# Zeigt ein Befehl auf diese Statusline, also auf eine Datei mit der Versionskennung
# dieses Projekts?
points_to_this_statusline() {
  local path
  path=$(command_path "$1") || return 1
  [ -f "$path" ] && grep -q 'claude-code-statusline v' "$path" 2>/dev/null
}

# Zeigt ein Befehl auf die verwaltete Kopie, gleich ob mit Tilde, absolut oder über einen
# Symlink? Dann ist er keine andere Kopie, und kein Hinweis darf zum Löschen raten.
is_managed_command() {
  local path
  [ "$1" = "$STATUSLINE_COMMAND" ] && return 0
  path=$(command_path "$1") || return 1
  [ -e "$path" ] && [ "$path" -ef "$STATUSLINE_PATH" ]
}

# write_settings FILTER [JQ-ARGUMENTE]: wendet FILTER auf settings.json an. Vorher eine
# Sicherung daneben, geschrieben über eine Temp-Datei, damit ein Fehler nie eine halbe
# Datei hinterlässt. Ein Symlink (etwa in ein Dotfiles-Repo) bleibt ein Symlink.
write_settings() {
  local filter=$1 tmp backup
  shift
  mkdir -p "$CLAUDE_DIR" || die "cannot create $CLAUDE_DIR"
  tmp="$SETTINGS_PATH.tmp.$$"
  if [ -s "$SETTINGS_PATH" ]; then
    backup="$SETTINGS_PATH.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$SETTINGS_PATH" "$backup" || die "cannot back up $SETTINGS_PATH"
    # Die Temp-Datei übernimmt zuerst die Rechte des Originals: settings.json kann Tokens
    # tragen, und eine 600 darf nicht zur 644 werden. Das Überschreiben behält den Modus.
    cp -p "$SETTINGS_PATH" "$tmp" && jq "$@" "$filter" "$SETTINGS_PATH" > "$tmp"
  else
    jq -n "$@" "$filter" > "$tmp"
  fi || { rm -f "$tmp"; die "cannot update $SETTINGS_PATH"; }
  if [ -L "$SETTINGS_PATH" ]; then
    cat "$tmp" > "$SETTINGS_PATH" || { rm -f "$tmp"; die "cannot write $SETTINGS_PATH"; }
    rm -f "$tmp"
  else
    mv -f "$tmp" "$SETTINGS_PATH" || { rm -f "$tmp"; die "cannot write $SETTINGS_PATH"; }
  fi
}

# Steht schon die verwaltete Kopie drin, bleibt alles still. Eine andere Kopie dieser
# Statusline wird mit Vorgabe Ja umgehängt, ein fremdes Skript nur nach ausdrücklichem
# Ja. Die bisherige Datei fasst der Installer in keinem Fall an.
wire_settings() {
  local current
  current=$(current_statusline_command)
  [ "$current" = "$STATUSLINE_COMMAND" ] && return 0
  if is_managed_command "$current"; then
    : # die verwaltete Kopie unter anderem Namen: still auf die Tilde-Form bringen
  elif [ -n "$current" ] && points_to_this_statusline "$current"; then
    if ! ask_yes_no "settings.json points at another copy of this status line ($current). Switch to the managed copy at $STATUSLINE_COMMAND?" y; then
      info "Kept $current. The managed copy at $STATUSLINE_COMMAND is installed but not in use."
      return 0
    fi
    info "Your previous copy at $current was left in place. Delete it if you no longer need it."
  elif [ -n "$current" ]; then
    if ! ask_yes_no "settings.json uses another status line ($current). Replace it?" n; then
      info "Kept your status line. To use this one, set statusLine.command to $STATUSLINE_COMMAND in $SETTINGS_PATH."
      return 0
    fi
  fi
  # shellcheck disable=SC2016  # $cmd ist eine jq-Variable, die Shell soll sie nicht sehen
  write_settings '.statusLine = ((if (.statusLine | type) == "object" then .statusLine else {} end)
    + {type: "command", command: $cmd})' --arg cmd "$STATUSLINE_COMMAND"
  info "Set statusLine in $SETTINGS_PATH."
}

main() {
  require_bash
  parse_args "$@"
  init_paths
  detect_os
  require_jq
  check_settings_readable
  init_prompt
  make_tmp_dir
  install_statusline
  wire_settings
  info "Done. Start a new Claude Code session to see the status line."
}

main "$@"
