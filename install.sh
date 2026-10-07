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
# Eine Schlüssel=Wert-Zeile je Einstellung. Gelesen wird zeilenweise, nie per source:
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
resolve_dir() { (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P); }

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
  # Schreibgeschützt: TMP_DIR ist die Positivliste von safe_remove_tree, eine spätere
  # Zuweisung dürfte sie nicht auf einen anderen Ordner umbiegen.
  readonly TMP_DIR
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
  if [ -e "$STATUSLINE_PATH" ] && [ ! -f "$STATUSLINE_PATH" ]; then
    die "$STATUSLINE_PATH is not a regular file. Move it away and run the installer again."
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

# --- Klick-Handler ---
# Der Rumpf steht hier als Heredoc, damit das Release eine einzige Installer-Datei
# bleibt. write_switch_handler setzt davor die absoluten Pfade von cswap und jq: vom
# Betriebssystem aufgerufen hat der Handler keinen verlässlichen PATH.
handler_body() {
  cat <<'SWITCH_HANDLER'
# shellcheck shell=bash
# Klick-Handler für claude-statusline://switch, erzeugt von install.sh.
#
# Erlaubt ist nur claude-statusline://switch, optional mit ?to=<mail>. Ein Ziel gilt nur,
# wenn cswap genau ein Konto mit dieser Mail verwaltet; gewechselt wird dann über dessen
# Nummer, damit genau das geprüfte Konto getroffen wird. So kann auch eine Webseite, die
# das Schema aufruft, nur zwischen den eigenen Konten wechseln.
# cswap switch läuft ohne Timeout und wird nie abgebrochen: cswap rollt einen
# abgebrochenen Tausch nicht zurück, ein halber Login wäre die Folge.
set -u
: "${CSWAP_BIN:?}" "${JQ_BIN:?}"

notify() {
  local title="Claude Statusline" body=$1
  case "$(uname -s)" in
    Darwin)
      osascript -e 'on run argv' \
        -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
        -e 'end run' "$title" "$body" >/dev/null 2>&1 && return 0 ;;
    *)
      command -v notify-send >/dev/null 2>&1 \
        && notify-send -- "$title" "$body" >/dev/null 2>&1 && return 0 ;;
  esac
  printf '%s: %s\n' "$title" "$body" >&2
}

reject() {
  notify "$1"
  exit 2
}

# Gibt die Mail aus ?to= dekodiert aus. Kodiert erlaubt sind nur die Zeichen, die jq @uri
# für eine Mail erzeugt (%40 für @, %2B für +, %25 für %), dekodiert nur eine Mail-Adresse.
decode_target() {
  local raw=$1 decoded
  local raw_re='^([A-Za-z0-9._~-]|%40|%2[Bb5])+$'
  local mail_re='^[A-Za-z0-9._%+~-]+@[A-Za-z0-9.-]+$'
  [[ $raw =~ $raw_re ]] || return 1
  printf -v decoded '%b' "${raw//%/\\x}"
  [[ $decoded =~ $mail_re ]] || return 1
  printf '%s' "$decoded"
}

# Die Nummer des einen Kontos mit dieser Mail, "none" oder "ambiguous". Eine andere
# schemaVersion als 1 ergibt "unsupported", das der Aufrufer wie eine gescheiterte Liste behandelt.
account_number() {
  # shellcheck disable=SC2016  # $mail ist eine jq-Variable, die Shell soll sie nicht sehen
  printf '%s' "$2" | "$JQ_BIN" -r --arg mail "$1" '
    if .schemaVersion != 1 then "unsupported" else
    [.accounts[]? | select((.email // "" | ascii_downcase) == ($mail | ascii_downcase)) | .number]
    | if length == 1 then .[0] | tostring
      elif length == 0 then "none"
      else "ambiguous" end
    end' 2>/dev/null
}

main() {
  local url=${1:-} target="" mail list number result message
  case "$url" in
    "claude-statusline://switch") ;;
    "claude-statusline://switch?to="*) target=${url#*\?to=} ;;
    *) reject "Ignored a link that is not a claude-statusline switch link." ;;
  esac
  if [ -z "$target" ] && [ "$url" != "claude-statusline://switch" ]; then
    reject "Ignored a switch link without an account."
  fi
  if [ -n "$target" ]; then
    mail=$(decode_target "$target") || reject "Ignored a switch link with an invalid account."
    list=$("$CSWAP_BIN" list --json 2>/dev/null) || reject "Could not read the accounts from cswap."
    number=$(account_number "$mail" "$list")
    case "$number" in
      none) reject "$mail is not an account managed by cswap." ;;
      ambiguous) reject "$mail matches more than one cswap account. Switch with cswap in a terminal." ;;
      ""|*[!0-9]*) reject "Could not read the accounts from cswap." ;;
    esac
    trap '' HUP INT TERM
    result=$("$CSWAP_BIN" switch "$number" --json 2>/dev/null)
  else
    trap '' HUP INT TERM
    result=$("$CSWAP_BIN" switch --json 2>/dev/null)
  fi
  message=$(printf '%s' "$result" | "$JQ_BIN" -r '.message // .error.message // empty' 2>/dev/null)
  notify "${message:-cswap did not report a result.}"
  return 0
}

main "$@"
SWITCH_HANDLER
}

write_switch_handler() {
  local cswap_bin=$1 jq_bin=$2 tmp="$HANDLER_PATH.tmp.$$"
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  if ! {
    printf '#!/usr/bin/env bash\n'
    printf 'CSWAP_BIN=%q\nJQ_BIN=%q\n' "$cswap_bin" "$jq_bin"
    handler_body
  } > "$tmp" || ! chmod 755 "$tmp" || ! mv -f "$tmp" "$HANDLER_PATH"; then
    rm -f "$tmp"
    die "cannot write $HANDLER_PATH"
  fi
}

# --- cswap ---
# Bevorzugt uv, sonst pipx. Ein cswap, das auf anderem Weg kam, bleibt unangetastet.
# Setzt CSWAP_BIN auf den absoluten Pfad oder endet mit 1.
CSWAP_BIN=""

find_cswap() {
  local uv_bin=""
  command -v uv >/dev/null 2>&1 && uv_bin=$(uv tool dir --bin 2>/dev/null)
  if command -v cswap >/dev/null 2>&1; then
    CSWAP_BIN=$(command -v cswap)
  elif [ -n "$uv_bin" ] && [ -x "$uv_bin/cswap" ]; then
    # uv legt Werkzeuge ab, wo UV_TOOL_BIN_DIR oder XDG_BIN_HOME es sagen.
    CSWAP_BIN="$uv_bin/cswap"
  elif [ -x "$HOME/.local/bin/cswap" ]; then
    CSWAP_BIN="$HOME/.local/bin/cswap"
  else
    return 1
  fi
}

install_cswap() {
  if command -v uv >/dev/null 2>&1; then
    if uv tool list 2>/dev/null | grep -q '^claude-swap '; then
      uv tool upgrade claude-swap || warn "could not update cswap, keeping the installed version"
    elif ! find_cswap; then
      uv tool install claude-swap || return 1
    fi
  elif command -v pipx >/dev/null 2>&1; then
    if pipx list --short 2>/dev/null | grep -q '^claude-swap '; then
      pipx upgrade claude-swap || warn "could not update cswap, keeping the installed version"
    elif ! find_cswap; then
      pipx install claude-swap || return 1
    fi
  elif ! find_cswap; then
    info "cswap is installed with uv or pipx, and neither was found."
    ask_yes_no "Install uv with the official installer from astral.sh?" n || return 1
    curl -LsSf https://astral.sh/uv/install.sh | sh || return 1
    "$HOME/.local/bin/uv" tool install claude-swap || return 1
  fi
  find_cswap
}

# Nimmt das angemeldete Konto in cswap auf, wenn es dort noch fehlt.
adopt_current_account() {
  local status email managed
  status=$("$CSWAP_BIN" status --json 2>/dev/null) || status=""
  if [ -z "$status" ]; then
    warn "could not read the account status from cswap. Add the account yourself with: cswap add"
    return 0
  fi
  email=$(printf '%s' "$status" | jq -r '.active.email // ""' 2>/dev/null)
  managed=$(printf '%s' "$status" | jq -r '.active.managed // false' 2>/dev/null)
  if [ -z "$email" ]; then
    info "Claude Code is not logged in. Log in, then add the account with: cswap add"
    return 0
  fi
  [ "$managed" = true ] && return 0
  "$CSWAP_BIN" add < /dev/null || warn "cswap add failed. Add the account yourself with: cswap add"
}

# --- Registrierung des Handlers ---
applescript_source() {
  cat <<'APPLESCRIPT'
on open location this_url
	set handler_path to (POSIX path of (path to home folder)) & ".claude/statusline/switch-handler.sh"
	try
		do shell script "/bin/bash " & quoted form of handler_path & " " & quoted form of this_url
	end try
end open location

on run
end run
APPLESCRIPT
}

# plist_put PLIST SCHLÜSSEL TYP WERT: setzt einen Schlüssel neu, egal ob er schon da war.
plist_put() {
  PlistBuddy -c "Delete :$2" "$1" >/dev/null 2>&1
  PlistBuddy -c "Add :$2 $3 $4" "$1"
}

register_macos_app() {
  local script="$TMP_DIR/switch.applescript" plist="$APP_PATH/Contents/Info.plist"
  applescript_source > "$script" || return 1
  mkdir -p "$HOME/Applications" || return 1
  safe_remove_tree "$APP_PATH"
  osacompile -o "$APP_PATH" "$script" || return 1
  plist_put "$plist" CFBundleIdentifier string "$BUNDLE_ID" || return 1
  plist_put "$plist" LSUIElement bool true || return 1
  PlistBuddy -c "Delete :CFBundleURLTypes" "$plist" >/dev/null 2>&1
  PlistBuddy -c "Add :CFBundleURLTypes array" "$plist" \
    && PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$plist" \
    && PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string $BUNDLE_ID" "$plist" \
    && PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$plist" \
    && PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $URL_SCHEME" "$plist" \
    || return 1
  # Die geänderte Info.plist bricht die Signatur von osacompile. Neu ad hoc signieren,
  # sonst startet macOS die App auf Apple Silicon nicht.
  codesign --force --sign - "$APP_PATH" || return 1
  lsregister -f "$APP_PATH"
}

# Desktop-Einträge zitieren Exec nach eigenen Regeln. Ein Pfad mit Zeichen, die dort
# zusätzlich maskiert werden müssten, wird abgewiesen statt halb richtig geschrieben.
register_linux_desktop() {
  local dir=${DESKTOP_PATH%/*} tmp="$DESKTOP_PATH.tmp.$$"
  case "$HANDLER_PATH" in
    *[\"\`\$\\%]*) warn "the path $HANDLER_PATH cannot be written into a desktop entry"; return 1 ;;
  esac
  command -v xdg-mime >/dev/null 2>&1 || { warn "xdg-mime was not found (package xdg-utils)"; return 1; }
  mkdir -p "$dir" || return 1
  if ! {
    printf '[Desktop Entry]\nType=Application\nName=Claude Statusline Switch\n'
    printf 'Exec="%s" %%u\n' "$HANDLER_PATH"
    printf 'MimeType=x-scheme-handler/%s;\nNoDisplay=true\nTerminal=false\n' "$URL_SCHEME"
  } > "$tmp" || ! mv -f "$tmp" "$DESKTOP_PATH"; then
    rm -f "$tmp"
    return 1
  fi
  xdg-mime default "$DESKTOP_NAME" "x-scheme-handler/$URL_SCHEME" || return 1
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$dir" >/dev/null 2>&1
  fi
  return 0
}

register_url_handler() {
  case "$OS" in
    macos) register_macos_app ;;
    linux) register_linux_desktop ;;
  esac
}

# Der Marker kommt zuletzt: erst wenn Handler und Registrierung stehen, zeigt die
# Statusline den Link. Scheitert die Registrierung, bleibt er weg.
install_switch_handler() {
  write_switch_handler "$CSWAP_BIN" "$(command -v jq)"
  if ! register_url_handler; then
    # Halbfertiges (unsignierte App, Desktop-Datei ohne Zuordnung) bleibt nicht liegen.
    remove_switch_handler
    warn "Click-to-switch is not active: the link handler could not be registered. You can still switch with: cswap switch"
    return 1
  fi
  : > "$MARKER_PATH" || die "cannot write $MARKER_PATH"
}

# Marker zuerst: ab dann zeigt keine Statusline mehr einen Link auf den Handler.
remove_switch_handler() {
  rm -f "$MARKER_PATH" "$HANDLER_PATH"
  case "$OS" in
    macos)
      if [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; then
        # Erst prüfen, dann abmelden: ein Symlink auf eine fremde App darf nicht bei
        # LaunchServices abgemeldet werden, bevor der Löschwächter ihn abweist.
        [ -L "$APP_PATH" ] && die "refusing to delete $APP_PATH: it is a symlink"
        [ -d "$APP_PATH" ] || die "refusing to delete $APP_PATH: not a directory"
        lsregister -u "$APP_PATH" >/dev/null 2>&1
        safe_remove_tree "$APP_PATH"
      fi ;;
    linux)
      if [ -e "$DESKTOP_PATH" ]; then
        rm -f "$DESKTOP_PATH"
        if command -v update-desktop-database >/dev/null 2>&1; then
          update-desktop-database "${DESKTOP_PATH%/*}" >/dev/null 2>&1
        fi
      fi ;;
  esac
  return 0
}

# Die Link-Variable gewinnt gegen den Handler, aus settings.json wie aus der Shell.
note_switch_url_override() {
  local url=""
  [ -s "$SETTINGS_PATH" ] && url=$(jq -r '.env.CLAUDE_STATUSLINE_SWITCH_URL // empty' "$SETTINGS_PATH" 2>/dev/null)
  if [ -n "$url" ]; then
    info "Note: CLAUDE_STATUSLINE_SWITCH_URL is set in settings.json ($url). Clicks go there, not to the handler, until you remove it."
  elif [ -n "${CLAUDE_STATUSLINE_SWITCH_URL:-}" ]; then
    info "Note: CLAUDE_STATUSLINE_SWITCH_URL is set in your shell (${CLAUDE_STATUSLINE_SWITCH_URL}). Clicks go there, not to the handler, until you remove it."
  fi
  return 0
}

print_swap_guide() {
  cat <<'GUIDE'

Click-to-switch is set up.
  Add another account: run /login in Claude Code (no /logout before it), then: cswap add
  Switch: Cmd+click (Ctrl+click on most Linux terminals) the "-> B" or the arrows at the
  end of the limits line. Your terminal needs to support OSC 8 hyperlinks.
GUIDE
}

setup_swap() {
  local swap=$SWAP_FLAG
  [ -n "$swap" ] || swap=$(config_get swap)
  if [ -z "$swap" ]; then
    if ask_yes_no "Do you use more than one Claude account?" n; then swap=on; else swap=off; fi
  fi
  config_set swap "$swap"
  if [ "$swap" = off ]; then
    remove_switch_handler
    info "Click-to-switch is off. Turn it on later by running the installer with --swap."
    return 0
  fi
  if ! install_cswap; then
    warn "cswap could not be installed, so click-to-switch is not set up. Install uv or pipx and run the installer with --swap again."
    return 0
  fi
  adopt_current_account
  install_switch_handler || return 0
  note_switch_url_override
  print_swap_guide
}

# --- Deinstallation ---
# cswap und seine Konten bleiben: sie gehören einem eigenen Werkzeug, das auch ohne diese
# Statusline nützt. Die Verbrauchshistorie in statusline-accounts bleibt ebenfalls.
uninstall() {
  local current
  remove_switch_handler
  rm -f "$CONFIG_PATH"
  current=$(current_statusline_command)
  # Nur die verwaltete Kopie hat der Installer eingehängt, also nimmt er nur sie heraus.
  # is_managed_command braucht die Datei, deshalb steht das vor dem Löschen.
  if is_managed_command "$current"; then
    write_settings 'del(.statusLine)'
    info "Removed statusLine from $SETTINGS_PATH."
  elif [ -n "$current" ] && points_to_this_statusline "$current"; then
    info "statusLine still points at your other copy ($current). It was left in place."
  fi
  rm -f "$STATUSLINE_PATH" "$STATUSLINE_PATH.bak"
  rmdir "$STATE_DIR" 2>/dev/null
  info "Removed claude-code-statusline."
  info "cswap and its accounts were kept. To remove them: cswap purge, then uv tool uninstall claude-swap (or pipx uninstall claude-swap)"
  info "Usage history stays in $CLAUDE_DIR/statusline-accounts. Delete that folder if you no longer need it."
}

main() {
  require_bash
  parse_args "$@"
  init_paths
  detect_os
  require_jq
  check_settings_readable
  if [ "$UNINSTALL" = 1 ]; then
    uninstall
    return 0
  fi
  init_prompt
  make_tmp_dir
  install_statusline
  wire_settings
  setup_swap
  info "Done. Start a new Claude Code session to see the status line."
}

main "$@"
