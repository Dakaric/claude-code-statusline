#!/usr/bin/env bash
# Claude Code – farbige Statusline
# Zeilen: Ort | Werkzeug | Sitzung | Limits (je Zeile nur, was Daten hat)

# Single Source of Truth für die Version. Der Release-Workflow prüft, dass der
# gepushte Tag (v<X>) exakt hierzu passt -> kein Drift zwischen Tag und Skript.
VERSION="1.3.4"

# --version / -v / version: nur ausgeben und raus, bevor von stdin gelesen wird.
# Im Normalbetrieb ruft Claude Code das Skript ohne Argumente auf ($1 leer).
case "${1:-}" in
  --version|-v|version)
    echo "claude-code-statusline v${VERSION}"
    exit 0
    ;;
esac

# Unter Locales mit Komma als Dezimaltrenner (de_DE, fr_FR, ...) formatieren printf und
# awk "280.0k" als "280,0k" und "3.1d" als "3,1d". Einmal zentral neutralisiert, damit
# nicht jede neue Rechenstelle daran denken muss -- exportiert, weil awk als Kindprozess
# laeuft. Betrifft nur Zahlformate, nicht die Zeichenkodierung (das waere LC_CTYPE).
export LC_NUMERIC=C

# Ein Zeitpunkt fuer den ganzen Lauf. Ueber STATUSLINE_NOW stellbar, damit Tests
# Zeitpunkte setzen koennen, statt auf die Uhr zu warten. Im Normalbetrieb ist die
# Variable nicht gesetzt.
NOW="${STATUSLINE_NOW:-$(date +%s)}"

# Liest stdin ohne cat: read gibt am Ende 1 zurueck, weil kein NUL kommt, der Inhalt
# steht trotzdem vollstaendig in input.
IFS= read -r -d '' input

# Jede offene Session ruft das Skript jede Sekunde auf, und jeder jq-Aufruf ist ein
# eigener Prozess. Deshalb liefert ein jq-Lauf viele Werte auf einmal, getrennt durch
# das Steuerzeichen 0x1F, das in keinem Wert vorkommt. Anders als bei Tab oder
# Leerzeichen faltet read aufeinanderfolgende Trenner nicht zusammen: ein leeres Feld
# bleibt an seinem Platz, statt die folgenden zu verschieben.
FIELD_SEP=$'\x1f'

# Ein Glob ohne Treffer liefert eine leere Liste statt seines eigenen Musters. jq bekaeme
# sonst einen Dateinamen mit Stern und braeche den ganzen Lauf ab.
shopt -s nullglob

# --- Daten aus JSON ---
# In jq runden (Werte kommen als Float wie 7.000000000000001): bash rechnet nur mit
# ganzen Zahlen. Fehlt current_usage, schaetzt used_tok aus Prozent und Gesamtgroesse.
# weekly/weekly_opus tragen je nach CLI-Version unter wechselnden Keys den echten Wert
# (z.B. weekly=0 neben seven_day=7) -> Maximum der vorhandenen Werte statt blinder Vorrang.
# Ablaufzeitpunkt und TTL des Prompt-Caches nennt der Payload direkt. Das ersetzt die
# Rechnung ueber das Transcript, die denselben Wert nur nachbaut.
# opt faengt Fehler je Feld ab: Aendert Claude Code den Typ eines Feldes, fehlt nur
# dieses, statt dass der ganze Lauf leer ausgeht. Felder, mit denen bash rechnet, laufen
# durch numbers: ein String in einer bash-Rechnung braeche das ganze Segment ab. Zeilenumbruch und Trenner im Wert
# wuerden alle folgenden Felder verschieben und werden zu Leerzeichen.
IFS="$FIELD_SEP" read -r rate_limits_json captured_at cwd model total_tok used_pct used_tok \
  five_h five_h_reset weekly weekly_opus weekly_reset vim_mode worktree effort \
  cache_expires cache_ttl_lbl transcript <<< "$(echo "$input" | jq -r '
  def opt(f): (try [f][0] catch null) // "" | tostring | gsub("[\n\u001f]"; " ");
  def max_of(f): [f] | map(select(type == "number")) | max | values;
  [ (.rate_limits // {} | tojson),
    (now | tostring),
    opt(.workspace.current_dir // .cwd),
    opt(.model.display_name),
    opt(.context_window.context_window_size // .context_window.total_tokens
        // .context_window.max_tokens | numbers),
    opt(.context_window.used_percentage | round),
    opt(.context_window as $cw
        | (($cw.current_usage // {}) as $u
           | ($u.input_tokens // 0) + ($u.output_tokens // 0)
             + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)) as $sum
        | if $sum > 0 then $sum
          else $cw.used_percentage / 100
               * ($cw.context_window_size // $cw.total_tokens // $cw.max_tokens) | floor end),
    opt(.rate_limits.five_hour.used_percentage // empty | round),
    opt(.rate_limits.five_hour.resets_at | numbers),
    opt(max_of(.rate_limits.weekly.used_percentage, .rate_limits.seven_day.used_percentage) | round),
    opt(max_of(.rate_limits.weekly_opus.used_percentage, .rate_limits.seven_day_opus.used_percentage) | round),
    opt(max_of(.rate_limits.weekly.resets_at, .rate_limits.seven_day.resets_at)),
    opt(.vim.mode),
    opt(.worktree.name // .workspace.git_worktree),
    opt(.effort.level),
    opt(.prompt_cache.expires_at | numbers),
    opt(.prompt_cache.ttl),
    opt(.transcript_path)
  ] | join("\u001f")' 2>/dev/null)"

# Jarvis-Cockpit: rate_limits-Snapshot rausschreiben. Das Agent-SDK liefert die
# Auslastung nicht, nur dieser Statusline-Payload hat sie -> Jarvis liest die Datei.
if [ -n "$rate_limits_json" ]; then
  [ -d ~/.claude ] || mkdir -p ~/.claude 2>/dev/null
  printf '{"rate_limits":%s,"captured_at":%s}\n' "$rate_limits_json" "$captured_at" \
    > ~/.claude/jarvis-rate-limits.json 2>/dev/null
fi

# --- Account-Identitaet und Snapshot ---
# Der Payload nennt den Account nicht, ~/.claude.json schon. Beides zusammen ergibt
# einen Stand pro Account, aus dem sich der gerade inaktive spaeter ablesen laesst.
# Ohne Limits im Payload wird nichts geschrieben, sonst wuerde eine Sitzung vor der
# ersten API-Antwort einen echten Stand mit einem leeren ueberschreiben.
#
# Der Login ist global, die Limits im Payload stammen aus der letzten Antwort dieser
# Session. Nach einem Umloggen liefern offene Sessions also noch den alten Account.
# Den verraet der Wochen-Reset: er ist je Account ein eigener Zeitpunkt. Passt er zu
# einem bekannten Snapshot, gehoert der Stand dorthin; passt er zu mehreren, gewinnt
# der Login. Passt er zu keinem, hat ein neues Fenster begonnen. Das kann nur das des
# Logins sein, wenn dessen bekanntes Fenster schon vorbei ist; sonst bleibt der Besitzer
# leer ("-"), und der Stand wird nirgends geschrieben.
# Ausnahme: Teilt der Login seinen Reset mit einem anderen Account, hat er frueher einen
# fremden Stand abbekommen, denn nur dem Login wird je etwas zugeschrieben. Dann ersetzt
# der neue Stand den Snapshot, statt mit ihm gemischt oder verworfen zu werden.
#
# Derselbe Lauf liefert first_seen und die bisherigen Limits des Besitzers, dazu ob der
# Snapshot des Logins gelesen wurde.
acct_dir="$HOME/.claude/statusline-accounts"

# Liest die Snapshots Datei fuer Datei. Eine leere, kaputte oder unlesbare Datei faellt
# einzeln raus, statt jq ganz abbrechen zu lassen. Beide Account-Laeufe unten nutzen
# diese Definition, jq braucht dafuer -R.
# shellcheck disable=SC2016  # $line ist eine jq-Variable, die Shell soll sie nicht sehen
SNAPSHOTS_JQ='def snapshots:
  reduce inputs as $line ({}; .[input_filename] += $line + "\n")
  | [.[] | try fromjson catch empty | select(type == "object" and .uuid)];'

snapshot_files=("$acct_dir"/*.json)
IFS="$FIELD_SEP" read -r login_read login_uuid acct_owner acct_replace first_seen old_limits \
  <<< "$(jq -n -R -r --slurpfile claude "$HOME/.claude.json" --arg r "$weekly_reset" \
    --argjson now "$NOW" "$SNAPSHOTS_JQ"'
  ($claude[0].oauthAccount.accountUuid // "") as $login
  | snapshots as $all
  | ($all | map(select(.uuid == $login)) | first | .rate_limits.seven_day.resets_at // 0) as $known
  | (if $login == "" or $r == "" then [$login, 0]
     else ($r | tonumber) as $reset
       | [$all[] | select(.rate_limits.seven_day.resets_at == $reset) | .uuid] as $hits
       | any($all[]; .uuid != $login and .rate_limits.seven_day.resets_at == $known) as $poisoned
       | if any($hits[]; . == $login) then [$login, 0]
         elif ($hits | length) > 0 then [$hits[0], 0]
         elif $poisoned then [$login, 1]
         elif $known > $now then ["-", 0]
         else [$login, 0] end
     end) as [$owner, $replace]
  | ($all | map(select(.uuid == $owner)) | first) as $snapshot
  | [any($all[]; .uuid == $login), $login, $owner, $replace, ($snapshot.first_seen // ""),
     ($snapshot.rate_limits // {} | tojson)]
  | map(tostring) | join("\u001f")' "${snapshot_files[@]}" < /dev/null 2>/dev/null)"
[ "$acct_owner" = "-" ] && acct_owner=""
acct_uuid="${acct_owner:-$login_uuid}"
acct_file="$acct_dir/${acct_uuid}.json"

# Geschrieben wird nur, wenn die Snapshots von Besitzer und Login gelesen wurden, soweit
# es sie gibt. Fehlt der des Logins, stimmt die Zuordnung ueber den Reset nicht mehr.
# Fehlt der des Besitzers, wuerde sein first_seen zu "jetzt": first_seen bestimmt die
# Reihenfolge der Labels, aus A wuerde B. Faellt ein Lauf unter Last mitten im Lesen
# aus, bleibt deshalb alles, wie es war.
if [ -n "$acct_owner" ] && [ -n "${five_h}${weekly}" ] \
  && { [ -n "$first_seen" ] || [ ! -e "$acct_file" ]; } \
  && { [ "$login_read" = true ] || [ ! -e "$acct_dir/${login_uuid}.json" ]; }; then
  [ -d "$acct_dir" ] || mkdir -p "$acct_dir"
  [ -n "$first_seen" ] || first_seen="$NOW"
  # Erst schreiben, dann umbenennen. Ein direktes "> $acct_file" leert die Datei vorab,
  # und eine parallel laufende Statusline (jede Session, jede Sekunde) liest sie in
  # diesem Moment leer: der Account fehlt fuer einen Frame, die Zeile springt.
  # Die Endung .tmp.PID faellt nicht unter das *.json-Glob beim Einlesen.
  # Pro Fenster gewinnt der spaetere Reset, bei gleichem Reset der hoehere Verbrauch:
  # innerhalb eines Fensters sinkt der Stand nie, ein niedrigerer stammt also aus einer
  # Session, deren letzte Antwort aelter ist als der Snapshot.
  acct_tmp="${acct_file}.tmp.$$"
  { [ "$acct_replace" = 1 ] || [ -z "$old_limits" ]; } && old_limits="{}"
  if echo "$input" | jq -c \
    --arg uuid "$acct_uuid" --argjson now "$NOW" --argjson seen "$first_seen" \
    --argjson old "$old_limits" '
    def later(a; b):
      if a == null then b elif b == null then a
      else [a, b] | max_by([.resets_at // 0, .used_percentage // 0]) end;
    (.rate_limits // {}) as $new
    | {uuid: $uuid, first_seen: $seen, captured_at: $now,
       rate_limits: (reduce (($old + $new) | keys[]) as $k
         ({}; .[$k] = later($old[$k]; $new[$k])))}' \
    > "$acct_tmp" 2>/dev/null; then
    mv -f "$acct_tmp" "$acct_file"
  else
    rm -f "$acct_tmp"
  fi
fi

# --- Alle bekannten Accounts und was die Zeile ueber sie zeigt ---
# Nach erstem Auftreten sortiert, der Index ist das Label: 0 ist A, 1 ist B, 2 ist C.
# Ein Fenster, dessen resets_at verstrichen ist, gilt als unbenutzt: Claude Code
# entfernt es dann aus dem Payload, und das naechste startet erst mit dem naechsten
# Prompt in diesem Account. Seine Restlaufzeit wk_days ist dann volle sieben Tage.
#
# others: 5h-Stand der uebrigen Accounts, "free", wenn ihr Fenster durch ist.
# rest/need: Runway, siehe Segment 5a2. switch_to: Wechselsignal, siehe Segment 5a3.
# wk_all: Wochenstand samt Restlaufzeit je Account. hist_u/hist_r: der eigene Stand fuer
# die Historie, aus dem Snapshot statt aus dem Payload, dort ist ein veralteter Stand
# schon aussortiert. my_fh_used/my_fh_reset: das eigene 5h-Fenster laut Snapshot,
# my_fh_reset leer, wenn der Account nie eines hatte.
snapshot_files=("$acct_dir"/*.json)
IFS="$FIELD_SEP" read -r acct_n acct_lbl others rest need switch_to wk_all hist_u hist_r \
  my_fh_used my_fh_reset \
  <<< "$(jq -n -R -r --arg u "$acct_uuid" --argjson now "$NOW" "$SNAPSHOTS_JQ"'
  def letter: ("ABCDEFGH" | split(""))[.];
  def window_open(w): (w.resets_at // 0) > $now;
  snapshots
  | sort_by(.first_seen)
  | map(.rate_limits.seven_day as $wk | .rate_limits.five_hour as $fh | . + {
      wk_used:  (if window_open($wk) then ($wk.used_percentage // 0) else 0 end),
      wk_reset: ($wk.resets_at // 0),
      wk_days:  (if window_open($wk) then ($wk.resets_at - $now) / 86400 else 7 end),
      fh_used:  (if window_open($fh) then ($fh.used_percentage // 0) else 0 end),
      fh_reset: ($fh.resets_at // 0)
    })
  | to_entries | map(.value + {lbl: (.key | letter)}) as $accts
  | (($accts | map(select(.uuid == $u)) | first) // {}) as $me
  | ($accts | map(select(.uuid != $u))) as $others
  | ((100 - ($me.wk_used // 0)) / ($me.wk_days // 7)) as $me_decay
  | ((($me.fh_used // 0) >= 95) or (($me.wk_used // 0) >= 95)) as $me_done
  | ($accts | sort_by(.wk_days)
     | reduce .[] as $a ({cum: 0, need: 0};
         .cum += (100 - $a.wk_used)
         | .need = ([.need, .cum / $a.wk_days] | max))) as $runway
  | [ ($accts | length),
      ($me.lbl // ""),
      ($others | map("\(.lbl) " + (if .fh_reset <= $now then "free" else "\(.fh_used)%" end))
       | join(" ")),
      $runway.cum,
      $runway.need,
      ($others
       | map((if .fh_reset <= $now then 0 else .fh_used end) as $fh
             | select($fh < 95)
             | ((100 - .wk_used) / .wk_days) as $decay
             | select($me_done or ($decay > $me_decay))
             | {lbl, decay: $decay})
       | sort_by(-.decay) | first | .lbl // ""),
      ($accts | map("\(.lbl) \(.wk_used)% (\((.wk_days * 10 | round) / 10)d)") | join(" ")),
      (if $me.uuid then ($me.wk_used | round) else "" end),
      (if $me.uuid then $me.wk_reset else "" end),
      (if $me.uuid then ($me.fh_used | round) else "" end),
      ($me.rate_limits.five_hour.resets_at | numbers) // ""
    ] | map(tostring) | join("\u001f")' "${snapshot_files[@]}" < /dev/null 2>/dev/null)"
acct_n="${acct_n:-0}"

# Claude Code nimmt ein abgelaufenes 5h-Fenster aus dem Payload und meldet das neue erst
# mit der naechsten Antwort dieser Session. Bis dahin gilt der Snapshot, den andere
# Sessions desselben Accounts schon aktualisiert haben; ist auch dort das Fenster vorbei,
# ist es frei. Ohne Wochenwert hat der Payload gar keine Limits, dann bleibt es leer.
# Ohne Besitzer gehoert der Wochenwert einem anderen Account als dem Snapshot, dann
# bleibt es ebenfalls leer.
five_h_free=0
if [ -z "$five_h" ] && [ -n "$weekly" ] && [ -n "$acct_owner" ] && [ -n "$my_fh_reset" ]; then
  if [ "${my_fh_reset%%.*}" -gt "$NOW" ]; then
    five_h="$my_fh_used"
    five_h_reset="$my_fh_reset"
  else
    five_h_free=1
  fi
fi

# Liest t, u und r der letzten Historienzeile ohne eigenen Prozess. Die Zeilen schreibt
# dieses Skript selbst mit printf, ihr Format ist fest; Zeilen aelterer Versionen haben
# kein r. Setzt last_t, last_u und last_r.
read_last_history_point() {
  local last_line="" line key pattern
  if [ -f "$1" ]; then
    while IFS= read -r line || [ -n "$line" ]; do last_line=$line; done < "$1"
  fi
  last_t=0 last_u=-1 last_r=0
  for key in t u r; do
    pattern="\"$key\":([0-9]+)"
    [[ $last_line =~ $pattern ]] && printf -v "last_$key" '%s' "${BASH_REMATCH[1]}"
  done
}

# --- Verbrauchs-Historie je Account ---
# Nur bei geaendertem Wert und hoechstens alle fuenf Minuten anhaengen, sonst waechst die
# Datei mit jedem Turn. Alles aelter als 48 Stunden faellt beim Schreiben raus.
# Der Reset r kennzeichnet das Fenster, zu dem der Wert gehoert.
if [ -n "$acct_owner" ] && [ -n "$weekly" ]; then
  hist_file="$acct_dir/${acct_uuid}.history"
  read_last_history_point "$hist_file"
  if [ -n "$hist_u" ] && [ "$hist_u $hist_r" != "$last_u $last_r" ] && [ $((NOW - last_t)) -ge 300 ]; then
    printf '{"t":%d,"u":%d,"r":%d}\n' "$NOW" "$hist_u" "$hist_r" >> "$hist_file"
    tmp_hist="${hist_file}.tmp.$$"
    if jq -c --argjson cut "$((NOW - 172800))" 'select(.t >= $cut)' "$hist_file" > "$tmp_hist" 2>/dev/null; then
      mv "$tmp_hist" "$hist_file"
    else
      rm -f "$tmp_hist"
    fi
  fi
fi

# --- Verbrauchstempo der letzten 24 Stunden ueber alle Accounts, und die Runway ---
# Je Account getrennt rechnen und erst dann summieren. Zusammengeworfen wuerden die
# Zeitreihen zweier Accounts ineinandersortiert, und jeder Wechsel erschiene als
# gewaltiger Sprung. Wechselt der Reset r, hat ein neues Fenster begonnen: dann zaehlt
# der neue Stand selbst als Verbrauch. Ein Rueckgang ohne neuen Reset ist kein Reset,
# sondern ein veralteter Stand: gezaehlt wird nur, was ueber den bisherigen Hoechststand
# im Fenster hinausgeht. Punkte ohne r stammen aus aelteren
# Versionen, die genau das nicht unterscheiden konnten, und bleiben aussen vor. Unter
# zwei Messpunkten bleibt das Tempo unbekannt statt null, sonst behauptete eine frische
# Installation, es werde nichts verbraucht. Eine abgerissene Zeile, etwa von einem
# abgebrochenen Lauf, faellt einzeln raus, statt die ganze Datei unbrauchbar zu machen.
#
# Runway: Das Budget fuellt sich mit N mal 100 Punkten pro sieben Tage nach. Liegt das
# Tempo darunter, laeuft nichts leer ("oo"). Darueber bleiben Rest / (Tempo -
# Nachfuellrate) Tage. Die Rechnung glaettet die einzelnen Resets zu einem
# gleichmaessigen Zufluss und liegt deshalb um Stunden daneben, wenn ein Reset
# unmittelbar bevorsteht.
# Dahinter steht die Luft "+N/d": so viele Punkte pro Tag mehr, bis bei jedem Reset
# nichts mehr uebrig ist. Das Soll-Tempo need ist die strengste Frist: nach Reset
# sortiert muss bis zu jedem Reset der Rest aller Fenster weg sein, die bis dahin enden.
# Das setzt voraus, dass zuerst der Account mit dem naechsten Reset verbraucht wird,
# also dem Wechselsignal gefolgt wird. runway_tier waehlt die Farbe: unter einem Tag
# warn, unter drei mid.
burn_24h=""
history_files=("$acct_dir"/*.history)
if [ "${#history_files[@]}" -gt 0 ]; then
  IFS="$FIELD_SEP" read -r burn_24h runway_days runway_tier runway_spare \
    <<< "$(jq -n -R -r --argjson from "$((NOW - 86400))" --argjson rest "${rest:-0}" \
    --argjson need "${need:-0}" --argjson accounts "$acct_n" '
    [inputs | (try fromjson catch null) as $point | select($point | type == "object")
     | $point + {file: input_filename}]
    | map(select(.t >= $from and .r))
    | group_by(.file)
    | map(sort_by(.t)
        | select(length >= 2)
        | reduce .[1:][] as $p ({r: .[0].r, top: .[0].u, sum: 0};
            if $p.r == .r then .sum += ([$p.u - .top, 0] | max) | .top = ([.top, $p.u] | max)
            else .sum += $p.u | .r = $p.r | .top = $p.u end)
        | .sum)
    | if length == 0 then ["", "", "", 0]
      else add as $rate
        | ($accounts * 100 / 7) as $refill
        | [$rate]
          + (if $rate <= $refill then ["oo", "ok"]
             else ($rest / ($rate - $refill)) as $days
               | [$days,
                  (if $days < 1 then "warn" elif $days < 3 then "mid" else "ok" end)]
             end)
          + [($need - $rate + 0.5 | floor)]
      end
    | map(tostring) | join("\u001f")' "${history_files[@]}" < /dev/null 2>/dev/null)"
fi

# --- git-Branch ---
# Aus HEAD gelesen, statt git zu starten: das kostete jede Sekunde einen Prozess je
# Session. Ein Worktree oder Submodul hat statt des Ordners .git eine Datei mit
# "gitdir: <pfad>". Ein losgeloester HEAD zeigt die ersten sieben Zeichen des Commits;
# git selbst nimmt in grossen Repos mehr, damit die Kurzform eindeutig bleibt.
# Ein relativer Pfad wird erst absolut: ohne Schraegstrich kaeme die Suche nie oben an.
# Ein Repo im Reftable-Format fuehrt in HEAD nur einen Platzhalter, dort fragt es git.
# Nicht erkannt werden ein nacktes Repo als Arbeitsverzeichnis und ein Symlink, dessen
# Ziel in einem Repo liegt.
read_git_branch() {
  local dir=$1 git_dir="" head_line
  branch=""
  case "$dir" in
    /*) ;;
    *)  dir="$PWD/$dir" ;;
  esac
  # Wie git -C: ein Ordner, den es nicht gibt, hat keinen Branch.
  [ -d "$dir" ] || return 0
  while :; do
    if [ -d "$dir/.git" ]; then
      git_dir="$dir/.git"
      break
    fi
    if [ -f "$dir/.git" ]; then
      read -r head_line < "$dir/.git"
      head_line=${head_line%$'\r'}
      git_dir=${head_line#gitdir: }
      [ "${git_dir#/}" = "$git_dir" ] && git_dir="$dir/$git_dir"
      break
    fi
    [ -z "$dir" ] && return 0
    dir=${dir%/*}
  done
  [ -f "$git_dir/HEAD" ] || return 0
  read -r head_line < "$git_dir/HEAD"
  head_line=${head_line%$'\r'}
  case "$head_line" in
    "ref: "*) branch=${head_line#ref: } branch=${branch#refs/heads/} ;;
    *)        branch=${head_line:0:7} ;;
  esac
  if [ "$branch" = ".invalid" ]; then
    branch=$(git -C "$dir" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
             || git -C "$dir" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  fi
}
read_git_branch "${cwd:-$PWD}"

# --- ANSI-Farben ---
RESET='\033[0m'
BOLD='\033[1m'
C_DIR='\033[96m'        # helles Cyan  – Verzeichnis
C_GIT='\033[92m'        # helles Grün  – git-Branch
C_MODEL='\033[95m'      # helles Magenta – Modell
C_CTX='\033[93m'        # Gelb         – Kontext
C_CTX_OK='\033[92m'     # Grün         – Kontext niedrig
C_WARN='\033[91m'       # helles Rot   – Warnung
C_SEP='\033[2;37m'      # Dim-Weiß     – Trennzeichen
C_CACHE='\033[36m'      # Cyan          – Prompt-Cache TTL
C_ORANGE='\033[38;5;208m' # Orange       – ctxQ im mittleren Bereich

SEP=" ${C_SEP}|${RESET} "

# NO_COLOR (https://no-color.org) leert alle Sequenzen. Die Tests vergleichen so reinen
# Text, statt ANSI-Codes mitzupflegen.
if [ -n "${NO_COLOR:-}" ]; then
  RESET='' BOLD='' C_DIR='' C_GIT='' C_MODEL='' C_CTX='' C_CTX_OK='' \
    C_WARN='' C_SEP='' C_CACHE='' C_ORANGE=''
  SEP=" | "
fi

# Die Hilfsfunktionen schreiben ihr Ergebnis in die Variable, deren Namen sie als erstes
# Argument bekommen. Ein "wert=$(funktion)" startete fuer jeden Aufruf eine Subshell.
# Gerechnet wird in ganzen Zahlen, das kann bash selbst, ohne awk. Die Zielvariablen
# sind hier vorab leer angelegt: shellcheck erkennt eine Zuweisung per printf -v nicht,
# und keine Funktion darf eine lokale Variable gleichen Namens haben, sonst landet das
# Ergebnis dort.
col="" bar="" used_fmt="" total_fmt="" line1="" line2="" line3="" line4=""

# --- Hilfsfunktion: Tokens hübsch formatieren (z.B. 48400 -> 48.4k, 1000000 -> 1M) ---
format_tokens() {
  local target=$1 tokens=$2 divisor unit scaled
  if [ -z "$tokens" ]; then
    printf -v "$target" '%s' ""
    return
  fi
  if   [ "$tokens" -ge 1000000 ]; then divisor=1000000 unit=M
  elif [ "$tokens" -ge 1000 ];    then divisor=1000    unit=k
  else
    printf -v "$target" '%d' "$tokens"
    return
  fi
  # %.1f auf den exakten Dezimalwert, damit Gleichstaende wie 1250 -> 1.2k so runden wie
  # bisher. Das printf ist eingebaut, es kostet keinen Prozess.
  printf -v scaled '%d.%0*d' $((tokens / divisor)) $((${#divisor} - 1)) $((tokens % divisor))
  printf -v scaled '%.1f' "$scaled"
  printf -v "$target" '%s%s' "${scaled%.0}" "$unit"
}

# --- Segment 1: Verzeichnis (Home als ~) ---
home="${HOME:-/Users/chris}"
short_cwd="${cwd/#$home/~}"
seg_dir="${C_DIR}${BOLD}${short_cwd}${RESET}"

# --- Segment 2: git-Branch ---
if [ -n "$branch" ]; then
  seg_git="${C_GIT} ${branch}${RESET}"
else
  seg_git=""
fi

# --- Segment 2b: Worktree ---
# Nur gesetzt, wenn die Sitzung in einem Worktree laeuft. Im Hauptbaum fehlt das Feld.
seg_worktree=""
if [ -n "$worktree" ]; then
  seg_worktree="${C_GIT}wt ${worktree}${RESET}"
fi

# --- Segment 3: Modell ---
seg_model="${C_MODEL}${model}${RESET}"

# --- Segment 3b: Effort-Stufe ---
# Der Payload nennt den Wert der laufenden Sitzung, also auch den nach einem /effort.
seg_effort=""
if [ -n "$effort" ]; then
  seg_effort="${C_MODEL}effort ${effort}${RESET}"
fi

# --- Hilfsfunktion: Progressbar (10 Segmente) ---
# Args: Zielvariable, percent (0-100)  -> "█████░░░░░"
make_bar() {
  local target=$1 filled=$(( ($2 + 5) / 10 )) cells="" i
  [ "$filled" -lt 0 ] && filled=0
  [ "$filled" -gt 10 ] && filled=10
  for ((i = 0; i < 10; i++)); do
    if [ "$i" -lt "$filled" ]; then cells="${cells}█"; else cells="${cells}░"; fi
  done
  printf -v "$target" '%s' "$cells"
}

# --- Farbauswahl nach Prozent ---
# Args: Zielvariable percent [warn_at] [caution_at] -- Schwellen überschreibbar, weil
# nicht jedes Budget gleich frueh alarmiert: beim Wochenlimit ist 80% noch normaler
# Verbrauch.
pct_color() {
  local target=$1 percent=$2 warn_at=${3:-80} caution_at=${4:-50}
  if [ "$percent" -ge "$warn_at" ]; then
    printf -v "$target" '%s' "$C_WARN"
  elif [ "$percent" -ge "$caution_at" ]; then
    printf -v "$target" '%s' "$C_CTX"
  else
    printf -v "$target" '%s' "$C_CTX_OK"
  fi
}

# --- Segment 4: Kontext (Progressbar + Tokens + Prozent) ---
seg_ctx=""
if [ -n "$used_tok" ]; then
  format_tokens used_fmt "$used_tok"
  format_tokens total_fmt "$total_tok"
  pct_int="${used_pct:-0}"
  pct_color col "$pct_int"
  make_bar bar "$pct_int"
  if [ -n "$total_fmt" ]; then
    seg_ctx="${col}ctx ${bar} ${pct_int}% (${used_fmt}/${total_fmt})${RESET}"
  else
    seg_ctx="${col}ctx ${bar} ${pct_int}% (${used_fmt})${RESET}"
  fi
fi

# --- Segment 5: 5h-Rate-Limit (immer wenn vorhanden) ---
seg_rate=""
if [ "$five_h_free" = 1 ]; then
  seg_rate="${C_CTX_OK}5h free${RESET}"
  if [ "$acct_n" -ge 2 ]; then
    seg_rate="${C_CTX_OK}5h ${acct_lbl} free${RESET}"
    [ -n "$others" ] && seg_rate="${seg_rate} ${C_SEP}${others}${RESET}"
  fi
elif [ -n "$five_h" ]; then
  pct_color col "$five_h"
  # Restzeit bis Reset in Klammern: "1h58m" bzw. "<1h -> 42m"
  cd=""
  if [ -n "$five_h_reset" ]; then
    reset_left=$(( ${five_h_reset%%.*} - NOW ))
    [ "$reset_left" -lt 0 ] && reset_left=0
    if [ "$reset_left" -ge 3600 ]; then
      printf -v cd ' (%dh%02dm)' $((reset_left / 3600)) $((reset_left % 3600 / 60))
    else
      printf -v cd ' (%dm)' $((reset_left / 60))
    fi
  fi
  seg_rate="${col}5h ${five_h}%${cd}${RESET}"
  # Ab zwei Accounts bekommt der aktive seinen Buchstaben, die uebrigen haengen dahinter:
  # "frei", wenn ihr 5h-Fenster durch ist, sonst ihr letzter bekannter Stand.
  if [ "$acct_n" -ge 2 ]; then
    seg_rate="${col}5h ${acct_lbl} ${five_h}%${cd}${RESET}"
    [ -n "$others" ] && seg_rate="${seg_rate} ${C_SEP}${others}${RESET}"
  fi
fi

# --- Segment 5a: Daily-Pacing-Delta (zwischen 5h und wk) ---
# Die Woche ist das 100%-Budget (wk). Bei gleichmäßigem Verbrauch "darf" man pro
# verstrichenem Tag 1/7 (~14,29%) ausgeben. delta = Soll(Zeit) - Ist(wk):
#   delta > 0  -> unter Budget, "im Plus"  (grün)
#   delta < 0  -> über Budget, zu schnell verbrannt, "im Minus" (gelb/rot)
# In Sekunden gerechnet: 604800 sind sieben Tage, 6048 Sekunden ein Prozent davon.
seg_daily=""
if [ -n "$weekly" ] && [ -n "$weekly_reset" ]; then
  week_left=$(( ${weekly_reset%%.*} - NOW ))
  [ "$week_left" -lt 0 ] && week_left=0
  [ "$week_left" -gt 604800 ] && week_left=604800
  # Soll minus Ist in 6048steln Prozent, kaufmaennisch gerundet, kein "-0"
  delta_parts=$(( 604800 - week_left - weekly * 6048 ))
  if [ "$delta_parts" -ge 0 ]; then
    d_val=$(( (delta_parts + 3024) / 6048 ))
  else
    d_val=$(( -((3024 - delta_parts) / 6048) ))
  fi
  days_left_tenths=$(( (week_left * 10 + 43200) / 86400 ))
  d_days_left="$((days_left_tenths / 10)).$((days_left_tenths % 10))"
  # Farbe nach Pacing: Plus grün, Minus < 1 Tag gelb, Minus >= 1 Tag (14%) rot
  if   [ "$d_val" -ge 0 ];   then dcol="$C_CTX_OK"
  elif [ "$d_val" -gt -14 ]; then dcol="$C_CTX"
  else                            dcol="$C_WARN"
  fi
  sign=""; [ "$d_val" -ge 0 ] && sign="+"   # Vorzeichen explizit -> als Delta lesbar
  seg_daily="${dcol}d ${sign}${d_val}% (${d_days_left}d)${RESET}"
fi

# --- Segment 5a2: Runway ueber das Gesamtbudget (ersetzt das Delta ab zwei Accounts) ---
# Die Rechnung steht beim Verbrauchstempo, hier wird nur formatiert.
if [ "$acct_n" -ge 2 ]; then
  if [ -z "$burn_24h" ]; then
    seg_daily="${C_SEP}rw ?${RESET}"
  else
    case "$runway_tier" in
      warn) rcol="$C_WARN" ;;
      mid)  rcol="$C_CTX" ;;
      *)    rcol="$C_CTX_OK" ;;
    esac
    extra=""
    [ "$runway_spare" -gt 0 ] && extra=" +${runway_spare}/d"
    runway_label="$runway_days"
    [ "$runway_days" = oo ] || printf -v runway_label '%.1fd' "$runway_days"
    seg_daily="${rcol}rw ${runway_label}${extra}${RESET}"
  fi
fi

# --- Segment 5a3: Wechselsignal ---
# Zwei Gruende, den Account zu wechseln. Erstens Erschoepfung: hier ist Schluss, woanders
# nicht. Zweitens Verfall: dort laeuft mehr Budget pro Tag ab als hier, es geht also
# verloren, wenn es liegen bleibt. Beides zaehlt nur, wenn im Ziel ueberhaupt
# 5h-Kapazitaet frei ist, sonst bringt der Wechsel nichts.
# Der Verfallsgrund allein wuerde den haeufigsten Fall verpassen: ein frisch
# zurueckgesetzter Account hat sieben Tage fuer 100 Punkte und damit fast immer die
# niedrigere Verfallsrate, obwohl genau dorthin zu wechseln waere.
seg_switch=""
if [ "$acct_n" -ge 2 ] && [ -n "$acct_uuid" ]; then
  if [ -n "$switch_to" ]; then
    seg_switch="${C_WARN}-> ${switch_to}${RESET}"
  fi
fi

# --- Segment 5b: Weekly-Rate-Limit (immer wenn vorhanden) ---
seg_weekly=""
if [ -n "$weekly" ]; then
  pct_color col "$weekly" 90
  seg_weekly="${col}wk ${weekly}%${RESET}"
  # Ab zwei Accounts steht hinter jedem Wert die Restlaufzeit seines Fensters. Damit
  # laesst sich das Wechselsignal nachrechnen, statt ihm glauben zu muessen.
  if [ "$acct_n" -ge 2 ]; then
    seg_weekly="${col}wk ${wk_all}${RESET}"
  fi
fi

# --- Segment 5c: Weekly-Opus-Rate-Limit (falls vorhanden) ---
seg_weekly_opus=""
if [ -n "$weekly_opus" ]; then
  pct_color col "$weekly_opus"
  seg_weekly_opus="${col}wk-opus ${weekly_opus}%${RESET}"
fi

# --- Segment ContextQ (token-optimizer Quality-Score, pro Session) ---
# Der UserPromptSubmit-Hook des token-optimizer-Plugins schreibt alle ~2 Min einen
# Score nach ~/.claude/token-optimizer/quality-cache-<sessionUUID>.json. Die UUID ist
# der Basename des transcript_path. Fallback auf den globalen Cache.
# Die Session-Datei entsteht erst nach den ersten Minuten Laufzeit, und den globalen
# Fallback legt der Hook gar nicht erst an -> eine frische Session hat schlicht noch
# keinen Score. Dann Platzhalter statt Leerstelle, sonst liest sich das fehlende
# Segment wie ein Defekt.
seg_ctxq=""
if [ -n "$transcript" ]; then
  seg_ctxq="${C_SEP}ctxQ …${RESET}"
  sid=${transcript##*/}
  sid=${sid%.jsonl}
  qfile="$HOME/.claude/token-optimizer/quality-cache-${sid}.json"
  [ -f "$qfile" ] || qfile="$HOME/.claude/token-optimizer/quality-cache.json"
  if [ -f "$qfile" ]; then
    qdata=$(jq -r '[((.resource_health // .score) | round), (.resource_health_grade // .grade // "?")] | @tsv' "$qfile" 2>/dev/null)
    IFS=$'\t' read -r q_score q_grade <<< "$qdata"
    if [ -n "$q_score" ] && [ "$q_score" != "null" ]; then
      if   [ "$q_score" -ge 85 ]; then qcol="$C_CTX_OK"
      elif [ "$q_score" -ge 75 ]; then qcol="$C_CTX"
      elif [ "$q_score" -ge 50 ]; then qcol="$C_ORANGE"
      else                             qcol="$C_WARN"
      fi
      seg_ctxq="${qcol}ctxQ ${q_grade}(${q_score})${RESET}"
    fi
  fi
fi

# --- Segment Prompt-Cache TTL + Countdown ---
# Erste Wahl ist prompt_cache aus dem Payload: dort stehen die ausgehandelte TTL und der
# Ablaufzeitpunkt fertig drin. Fehlt das Feld (aeltere Claude-Code-Version), rechnet der
# Zweig darunter denselben Wert aus dem Transcript nach.
# TTL: 1h wenn ENABLE_PROMPT_CACHING_1H gesetzt, sonst 5m. Der Cache wird bei JEDEM
# API-Call neu geschrieben und die TTL dabei auf voll zurueckgesetzt -- also nicht nur
# bei einer Eingabe, sondern bei jedem Turn-Step waehrend der Agent arbeitet. Der
# korrekte Referenzpunkt ("wann wurde der Cache zuletzt geschrieben") ist daher der
# Timestamp der letzten assistant-Message: die 1h startet erst, wenn der Agent DURCH
# ist. Der Transcript-mtime taugt nicht (Hooks/Memory-Consolidation beruehren ihn ohne
# Cache-Touch). Restzeit = TTL - (jetzt - letzter_turn). Ruht die Session, laeuft sie
# ab und bleibt auf "cold" -- das Signal, dass der Cache weg ist (handoff/clear faellig).
case "${ENABLE_PROMPT_CACHING_1H:-}" in
  1|true|TRUE) cache_ttl=3600; cache_label="1h" ;;
  *)           cache_ttl=300;  cache_label="5m" ;;
esac
# Sagt der Payload etwas anderes, gilt der Payload: er kennt die tatsaechlich
# ausgehandelte TTL, die Umgebungsvariable nur den Wunsch.
case "$cache_ttl_lbl" in
  1h) cache_ttl=3600; cache_label="1h" ;;
  5m) cache_ttl=300;  cache_label="5m" ;;
esac
seg_cache="${C_CACHE}cache ${cache_label}${RESET}"
cache_left=""
if [ -n "$cache_expires" ]; then
  cache_left=$(( ${cache_expires%%.*} - NOW ))
elif [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # Epoch des letzten Cache-Touch = spaetester Timestamp aus assistant-Message (jeder
  # API-Call schreibt Cache) und echter User-Eingabe (type=user, kein isMeta, content
  # String oder Array ohne tool_result -- deckt den Latenz-Fall ab, waehrend der Agent
  # auf die neue Eingabe noch nicht geantwortet hat). Meta/Hook-Zeilen fallen raus.
  t_mtime=$(jq -r 'select((.type=="assistant") or (.type=="user" and (.isMeta|not) and ((.message.content|type=="string") or ((.message.content|type=="array") and (any(.message.content[]; .type=="tool_result")|not))))) | (.timestamp | sub("\\.[0-9]+";"") | fromdateiso8601)' "$transcript" 2>/dev/null | tail -1)
  # Fallback auf File-mtime, falls das Transcript (noch) keine parsebare Turn-Zeile hat.
  [ -n "$t_mtime" ] || t_mtime=$(stat -f %m "$transcript" 2>/dev/null || stat -c %Y "$transcript" 2>/dev/null || echo 0)
  t_mtime=${t_mtime%%.*}
  [ "${t_mtime:-0}" -gt 0 ] && cache_left=$(( cache_ttl - (NOW - t_mtime) ))
fi

# Farbe: viel Zeit Cyan, letztes Fuenftel Gelb, abgelaufen Rot. Gilt fuer beide Wege.
if [ -n "$cache_left" ]; then
  [ "$cache_left" -lt 0 ] && cache_left=0
  if   [ "$cache_left" -le 0 ];    then c_lbl="cold"
  elif [ "$cache_left" -ge 3600 ]; then
    printf -v c_lbl '%dh%02dm' $((cache_left / 3600)) $((cache_left % 3600 / 60))
  elif [ "$cache_left" -ge 60 ];   then
    printf -v c_lbl '%dm%02ds' $((cache_left / 60)) $((cache_left % 60))
  else
    c_lbl="${cache_left}s"
  fi
  if   [ "$cache_left" -le 0 ];                  then ccol="$C_WARN"
  elif [ "$cache_left" -lt $((cache_ttl / 5)) ]; then ccol="$C_CTX"
  else                                               ccol="$C_CACHE"
  fi
  seg_cache="${ccol}cache ${c_lbl}/${cache_label}${RESET}"
fi

# --- Segment 6: Vim-Mode ---
seg_vim=""
if [ -n "$vim_mode" ]; then
  seg_vim="${C_CTX}[${vim_mode}]${RESET}"
fi

# --- Segmente zu einer Zeile fügen (leere überspringen, kein führender Trenner) ---
# Args: Zielvariable, Segmente
join_segs() {
  local target=$1 joined="" seg
  shift
  for seg in "$@"; do
    [ -n "$seg" ] || continue
    [ -z "$joined" ] && joined="$seg" || joined="${joined}${SEP}${seg}"
  done
  printf -v "$target" '%s' "$joined"
}

# --- Statusline zusammensetzen (4-zeilig) ---
# Zeile 1 (Ort):      Pfad, branch, worktree
# Zeile 2 (Werkzeug): Modell, Effort, vim
# Zeile 3 (Sitzung):  ctxQ, ctx, cache
# Zeile 4 (Limits):   5h, wk, (wk-opus), d bzw. Runway, (Wechselsignal)
# Eine leere Zeile entfaellt ganz, statt als Leerzeile zu erscheinen: eine Sitzung ohne
# Rate-Limits hat damit drei Zeilen statt einer Luecke.
join_segs line1 "$seg_dir" "$seg_git" "$seg_worktree"
join_segs line2 "$seg_model" "$seg_effort" "$seg_vim"
join_segs line3 "$seg_ctxq" "$seg_ctx" "$seg_cache"
join_segs line4 "$seg_rate" "$seg_weekly" "$seg_weekly_opus" "$seg_daily" "$seg_switch"

out="$line1"
for line in "$line2" "$line3" "$line4"; do
  [ -n "$line" ] && out="${out}"$'\n'"${line}"
done
printf "%b" "$out"
