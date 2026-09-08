# Statusline für mehrere Accounts: Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `statusline.sh` erkennt mehrere Claude-Accounts, rechnet Runway und Wechselsignal über deren gemeinsames Budget und zeigt alles in vier thematisch getrennten Zeilen.

**Architecture:** Das Skript bleibt eine einzelne Datei, weil das Release genau diese eine Datei als Asset ausliefert. Getrennt wird über Funktionen mit je einem Besitzer: Identität, Snapshot-Persistenz, Zeitreihe, Budgetrechnung und Signal fassen einander nur über ihre Rückgabewerte an. Vor dem Umbau entsteht ein Testharness, das die heutige Ausgabe einfriert, damit der Umbau nicht unbemerkt etwas anderes ausgibt.

**Tech Stack:** bash, jq, awk, git. Tests als bash-Skript ohne Framework. CI über GitHub Actions mit shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-08-mehrere-accounts-design.md`

## Global Constraints

- `statusline.sh` bleibt eine einzige ausführbare Datei. Der Release-Workflow lädt sie als Asset hoch; ein Aufteilen in mehrere Dateien würde die Installation brechen.
- `shellcheck statusline.sh` muss fehlerfrei durchlaufen. Das ist ein Gate im Release-Workflow.
- `export LC_NUMERIC=C` bleibt am Anfang stehen. Jede neue awk- oder printf-Rechnung verlässt sich darauf.
- `VERSION` in `statusline.sh` ist die Wahrheit für die Versionsnummer. Der Release-Workflow bricht ab, wenn ein Tag nicht dazu passt.
- Kommentare auf Deutsch mit echten Umlauten, kein Gedankenstrich als Einschub, keine Emojis.
- Fehlende Felder im Payload sind der Normalfall, nicht der Fehlerfall. Jedes Segment prüft auf Leerstring und entfällt still, wenn seine Daten fehlen.
- Der Referenzzeitpunkt aller Tests ist `1788870000` (2026-09-08 14:20 CEST). Alle `resets_at` in Fixtures werden relativ dazu gewählt.

## Dateien

| Datei | Verantwortung |
|---|---|
| `statusline.sh` | Das gesamte Skript, unverändert als Einzeldatei ausgeliefert |
| `tests/run.sh` | Testläufer: jede Fixture durch das Skript, Vergleich mit erwarteter Ausgabe |
| `tests/fixtures/<fall>.json` | Payload auf stdin |
| `tests/setup/<fall>.sh` | Optional: baut das Sandbox-HOME für einen Fall auf (Snapshots, git-Repo) |
| `tests/expected/<fall>.txt` | Erwartete Ausgabe, farbfrei |
| `.github/workflows/ci.yml` | shellcheck und Tests bei jedem Push |
| `README.md` | Beschreibung der neuen Segmente |

---

### Task 1: Testbarkeit herstellen

Ohne gestellte Uhrzeit und ohne farbfreie Ausgabe lässt sich nichts vergleichen. Diese Aufgabe ändert kein Verhalten, sie macht das vorhandene prüfbar.

**Files:**
- Modify: `statusline.sh` (Farbblock ab Zeile 67, alle `$(date +%s)`)
- Create: `tests/run.sh`, `tests/fixtures/basis.json`, `tests/expected/basis.txt`

**Interfaces:**
- Produces: `NOW` als Shell-Variable mit dem Zeitpunkt in Epoch-Sekunden, überschreibbar über `STATUSLINE_NOW`. Alle folgenden Aufgaben nutzen `$NOW` statt `date`.
- Produces: `NO_COLOR` schaltet sämtliche ANSI-Sequenzen ab.
- Produces: `tests/run.sh` als einziger Testeinstieg, Exit 0 bei Erfolg.

- [ ] **Schritt 1: Zeitquelle zentralisieren**

Direkt nach dem `export LC_NUMERIC=C` einfügen:

```bash
# Ein Zeitpunkt fuer den ganzen Lauf. Ueber STATUSLINE_NOW stellbar, damit Tests
# Zeitpunkte setzen koennen, statt auf die Uhr zu warten. Im Normalbetrieb ist die
# Variable nicht gesetzt.
NOW="${STATUSLINE_NOW:-$(date +%s)}"
```

Danach alle drei Vorkommen von `-v now="$(date +%s)"` durch `-v now="$NOW"` ersetzen (Daily-Pacing, 5h-Countdown, Cache-Countdown).

- [ ] **Schritt 2: Farben abschaltbar machen**

Die Inline-Farbe im ctxQ-Segment (`qcol='\033[38;5;208m'`) als Variable in den Farbblock ziehen:

```bash
C_ORANGE='\033[38;5;208m'  # Orange – ctxQ im mittleren Bereich
```

und im ctxQ-Segment `qcol="$C_ORANGE"` schreiben. Danach ans Ende des Farbblocks:

```bash
# NO_COLOR (https://no-color.org) leert alle Sequenzen. Die Tests vergleichen so
# reinen Text, statt ANSI-Codes mitzupflegen.
if [ -n "${NO_COLOR:-}" ]; then
  RESET='' BOLD='' C_DIR='' C_GIT='' C_MODEL='' C_CTX='' C_CTX_OK='' \
    C_WARN='' C_SEP='' C_CACHE='' C_ORANGE=''
  SEP=" | "
fi
```

`SEP` wird im Farbblock aus `C_SEP` gebaut und muss deshalb danach neu gesetzt werden.

- [ ] **Schritt 3: Testläufer schreiben**

```bash
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
  actual=$(HOME="$sandbox" NO_COLOR=1 STATUSLINE_NOW="$test_now" bash "$script" < "$fixture")
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
```

`chmod +x tests/run.sh` nicht vergessen.

- [ ] **Schritt 4: Erste Fixture anlegen**

`tests/fixtures/basis.json`, ein Payload mit Limits, aber ohne Transcript und ohne git-Verzeichnis:

```json
{
  "workspace": { "current_dir": "/opt/projekt" },
  "model": { "display_name": "Opus 5 (1M)" },
  "effort": { "level": "xhigh" },
  "context_window": {
    "context_window_size": 200000,
    "used_percentage": 45,
    "current_usage": {
      "input_tokens": 60000,
      "output_tokens": 4000,
      "cache_creation_input_tokens": 15000,
      "cache_read_input_tokens": 11000
    }
  },
  "rate_limits": {
    "five_hour": { "used_percentage": 23, "resets_at": 1788882000 },
    "seven_day": { "used_percentage": 24, "resets_at": 1789318800 }
  }
}
```

`resets_at` des 5h-Fensters liegt 3h20m nach `test_now`, das des Wochenfensters 5,2 Tage danach.

- [ ] **Schritt 5: Erwartung erzeugen und von Hand prüfen**

```bash
cd /Users/chris/Sites/claude-code-statusline
sandbox=$(mktemp -d)
HOME="$sandbox" NO_COLOR=1 STATUSLINE_NOW=1788870000 bash statusline.sh \
  < tests/fixtures/basis.json | tee tests/expected/basis.txt
rm -rf "$sandbox"
```

Die Ausgabe lesen, bevor sie eingefroren wird. Erwartet werden zwei Zeilen: oben Pfad und Modell, unten 5h mit Countdown, Delta, wk und der Kontextbalken. Stimmt etwas nicht, ist das ein Fund und kein Grund, die Datei zu übernehmen.

- [ ] **Schritt 6: Test laufen lassen**

Run: `bash tests/run.sh`
Erwartet: `ok basis` und `1 bestanden, 0 fehlgeschlagen`, Exit 0.

- [ ] **Schritt 7: shellcheck**

Run: `shellcheck statusline.sh tests/run.sh`
Erwartet: keine Ausgabe.

- [ ] **Schritt 8: Commit**

```bash
git add statusline.sh tests/
git commit -m "test: Testharness mit gestellter Uhrzeit und NO_COLOR"
```

---

### Task 2: Cache-Countdown aus dem Payload statt aus dem Transcript

Der Payload liefert `prompt_cache.expires_at` fertig. Das Skript rechnet den Wert heute aus dem Transcript nach, mit einem jq-Ausdruck über jede Zeile der Datei. Diese Aufgabe ersetzt die Rechnung durch das Feld und behält den Transcript-Weg als Fallback für ältere Claude-Code-Versionen.

**Files:**
- Modify: `statusline.sh:254-296` (Segment Prompt-Cache)
- Create: `tests/fixtures/cache-payload.json`, `tests/expected/cache-payload.txt`

**Interfaces:**
- Consumes: `NOW` aus Task 1.
- Produces: `seg_cache` unverändert im Format `cache <Restzeit>/<TTL>`, damit Task 3 es nur verschieben muss.

- [ ] **Schritt 1: Fixture mit prompt_cache anlegen**

`tests/fixtures/cache-payload.json`: wie `basis.json`, zusätzlich

```json
  "prompt_cache": { "warm": true, "ttl": "1h", "expires_at": 1788871500 }
```

`expires_at` liegt 25 Minuten nach `test_now`, erwartet wird also `cache 25m00s/1h`.

- [ ] **Schritt 2: Erwartung schreiben und Test zum Scheitern bringen**

`tests/expected/cache-payload.txt` von Hand um das Segment `cache 25m00s/1h` ergänzen, ausgehend von `tests/expected/basis.txt`.

Run: `bash tests/run.sh`
Erwartet: `FEHLER cache-payload`, weil das Skript ohne Transcript gar kein Cache-Segment mit Countdown baut.

- [ ] **Schritt 3: Payload-Feld auslesen**

Bei den übrigen jq-Zuweisungen ergänzen:

```bash
# Der Payload nennt Ablaufzeitpunkt und TTL des Prompt-Caches direkt. Das ersetzt die
# Rechnung ueber das Transcript, die denselben Wert nur nachbaut.
cache_expires=$(echo "$input" | jq -r '.prompt_cache.expires_at // empty')
cache_ttl_lbl=$(echo "$input" | jq -r '.prompt_cache.ttl // empty')
```

- [ ] **Schritt 4: Segment umbauen**

Der bestehende `case` für `ENABLE_PROMPT_CACHING_1H` bleibt als Fallback stehen, wird aber vom Payload überstimmt:

```bash
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
```

Danach die Restzeit vorrangig aus `cache_expires` bestimmen. Der Block, der `t_mtime` aus dem Transcript liest, bleibt als `else`-Zweig erhalten:

```bash
if [ -n "$cache_expires" ]; then
  cache_calc=$(awk -v expires="$cache_expires" -v now="$NOW" 'BEGIN{
    s = expires - now
    if (s < 0) s = 0
    h = int(s/3600); m = int((s%3600)/60); sec = int(s%60)
    if      (s <= 0) lbl = "cold"
    else if (h > 0)  lbl = sprintf("%dh%02dm", h, m)
    else if (m > 0)  lbl = sprintf("%dm%02ds", m, sec)
    else             lbl = sprintf("%ds", sec)
    printf "%d|%s", s, lbl
  }')
elif [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # ... bisheriger Transcript-Block, unveraendert
fi
```

Die Farbwahl darunter (`c_secs`, `thresh`, `ccol`) bleibt, wie sie ist, und läuft jetzt für beide Wege.

- [ ] **Schritt 5: Tests**

Run: `bash tests/run.sh`
Erwartet: `ok basis`, `ok cache-payload`, Exit 0.

- [ ] **Schritt 6: shellcheck und Commit**

```bash
shellcheck statusline.sh
git add statusline.sh tests/
git commit -m "feat: Cache-Countdown aus prompt_cache.expires_at, Transcript als Fallback"
```

---

### Task 3: Vier Zeilen, Worktree und Effort

**Files:**
- Modify: `statusline.sh` (jq-Block am Anfang, Segmentblock, Zusammenbau ab Zeile 316)
- Create: `tests/fixtures/vier-zeilen.json`, `tests/expected/vier-zeilen.txt`
- Modify: `tests/expected/basis.txt`, `tests/expected/cache-payload.txt`

**Interfaces:**
- Consumes: alle bestehenden `seg_*`-Variablen.
- Produces: die Zeilenaufteilung `line1` bis `line4`. Task 6 und 7 hängen ihre Segmente an `line4`.
- Produces: `seg_worktree` und `seg_effort`.

- [ ] **Schritt 1: Fixture mit Worktree und Effort**

`tests/fixtures/vier-zeilen.json`: wie `basis.json`, zusätzlich

```json
  "worktree": { "name": "fix-rate-limits" },
  "vim": { "mode": "INSERT" }
```

- [ ] **Schritt 2: Erwartung schreiben, Test scheitern lassen**

`tests/expected/vier-zeilen.txt`:

```
/opt/projekt | wt fix-rate-limits
Opus 5 (1M) | effort xhigh | [INSERT]
ctx ████░░░░░░ 45% (90k/200k) | cache 5m
5h 23% (3h20m) | d +50% (5.2d) | wk 24%
```

Die genauen Zahlen in Zeile 3 und 4 aus `tests/expected/basis.txt` übernehmen, statt sie zu raten.

Run: `bash tests/run.sh`
Erwartet: `FEHLER vier-zeilen`, zwei Zeilen statt vier.

- [ ] **Schritt 3: Neue Felder lesen**

```bash
worktree=$(echo "$input" | jq -r '.worktree.name // .workspace.git_worktree // empty')
effort=$(echo "$input"   | jq -r '.effort.level // empty')
```

- [ ] **Schritt 4: Segmente bauen**

Neben `seg_git` einfügen:

```bash
# --- Segment: Worktree ---
# Nur gesetzt, wenn die Sitzung in einem Worktree laeuft. Im Hauptbaum fehlt das Feld.
seg_worktree=""
if [ -n "$worktree" ]; then
  seg_worktree="${C_GIT}wt ${worktree}${RESET}"
fi

# --- Segment: Effort-Stufe ---
# Der Payload nennt den Wert der laufenden Sitzung, also auch nach einem /effort.
seg_effort=""
if [ -n "$effort" ]; then
  seg_effort="${C_MODEL}effort ${effort}${RESET}"
fi
```

- [ ] **Schritt 5: Zeilen neu schneiden**

Den Block am Dateiende ersetzen:

```bash
# --- Statusline zusammensetzen (4-zeilig) ---
# Zeile 1 (Ort):      Pfad, branch, worktree
# Zeile 2 (Werkzeug): Modell, Effort, vim
# Zeile 3 (Sitzung):  ctxQ, ctx, cache
# Zeile 4 (Limits):   5h, d bzw. Runway, wk, (wk-opus), (Wechselsignal)
line1=$(join_segs "$seg_dir" "$seg_git" "$seg_worktree")
line2=$(join_segs "$seg_model" "$seg_effort" "$seg_vim")
line3=$(join_segs "$seg_ctxq" "$seg_ctx" "$seg_cache")
line4=$(join_segs "$seg_rate" "$seg_daily" "$seg_weekly" "$seg_weekly_opus")

out="$line1"
for l in "$line2" "$line3" "$line4"; do
  [ -n "$l" ] && out="${out}"$'\n'"${l}"
done
printf "%b" "$out"
```

Leere Zeilen entfallen so ganz, statt als Leerzeile zu erscheinen. Eine Sitzung ohne Limits hat damit drei Zeilen.

- [ ] **Schritt 6: Bestehende Erwartungen nachziehen**

`tests/expected/basis.txt` und `tests/expected/cache-payload.txt` auf die neue Aufteilung anpassen. Beide haben keinen Worktree und keinen Vim-Modus, ihre Zeile 1 ist also nur der Pfad und Zeile 2 nur Modell und Effort.

- [ ] **Schritt 7: Tests, shellcheck, Commit**

```bash
bash tests/run.sh
shellcheck statusline.sh
git add statusline.sh tests/
git commit -m "feat: 4-Zeilen-Layout mit Worktree- und Effort-Segment"
```

---

### Task 4: Account-Snapshots

Die Nahtstelle. Alles Weitere liest das Format, das hier entsteht.

**Files:**
- Modify: `statusline.sh` (neuer Block nach dem jq-Auslesen)
- Create: `tests/fixtures/zwei-accounts.json`, `tests/setup/zwei-accounts.sh`, `tests/expected/zwei-accounts.txt`

**Interfaces:**
- Produces: `$HOME/.claude/statusline-accounts/<uuid>.json` mit den Feldern `uuid`, `first_seen`, `captured_at`, `rate_limits`.
- Produces: `accounts` als kompaktes JSON-Array aller Accounts, nach `first_seen` sortiert. Index 0 ist Label A, 1 ist B, 2 ist C.
- Produces: `acct_uuid` als UUID des aktiven Accounts, leer wenn unbekannt.
- Produces: `acct_n` als Zahl der bekannten Accounts.

- [ ] **Schritt 1: Setup-Skript für den Testfall**

`tests/setup/zwei-accounts.sh` legt einen zweiten, inaktiven Account im Sandbox-HOME an. Der aktive Account aaa bekommt hier bewusst keinen Snapshot: der entsteht erst im Lauf, mit `first_seen = now`. Damit aaa trotzdem Label A wird, liegt das `first_seen` von bbb eine Sekunde später.

```bash
#!/usr/bin/env bash
# Baut ein HOME mit zwei Accounts: aaa ist aktiv und steht in claude.json, bbb ist der
# zweite, dessen Stand nur als Snapshot vorliegt. bbb hat 78 Prozent der Woche
# verbraucht, sein Wochenfenster laeuft in 0,9 Tagen ab, sein 5h-Fenster ist durch.
set -u
sandbox=$1
now=${STATUSLINE_NOW:-1788870000}

mkdir -p "$sandbox/.claude/statusline-accounts"
cat > "$sandbox/.claude.json" <<JSON
{ "oauthAccount": { "accountUuid": "aaaaaaaa-0000-0000-0000-000000000001" } }
JSON

cat > "$sandbox/.claude/statusline-accounts/bbbbbbbb-0000-0000-0000-000000000002.json" <<JSON
{
  "uuid": "bbbbbbbb-0000-0000-0000-000000000002",
  "first_seen": $((now + 1)),
  "captured_at": $((now - 7200)),
  "rate_limits": {
    "five_hour": { "used_percentage": 40, "resets_at": $((now - 3600)) },
    "seven_day": { "used_percentage": 78, "resets_at": $((now + 77760)) }
  }
}
JSON
```

- [ ] **Schritt 2: Fixture und Erwartung**

`tests/fixtures/zwei-accounts.json` ist `basis.json`. Der Unterschied liegt allein im Setup.

Die Erwartung wird in Task 6 gefüllt. In dieser Aufgabe prüft der Test nur, dass die Ausgabe unverändert bleibt, obwohl ein zweiter Snapshot existiert: `tests/expected/zwei-accounts.txt` ist zunächst eine Kopie von `tests/expected/basis.txt`.

- [ ] **Schritt 3: Test zum Scheitern bringen**

Run: `bash tests/run.sh`
Erwartet: `ok zwei-accounts`, weil das Skript die Datei noch gar nicht liest. Danach prüfen, dass die Snapshot-Datei des aktiven Accounts nach dem Lauf existiert:

```bash
sandbox=$(mktemp -d)
HOME="$sandbox" STATUSLINE_NOW=1788870000 bash tests/setup/zwei-accounts.sh "$sandbox"
HOME="$sandbox" NO_COLOR=1 STATUSLINE_NOW=1788870000 bash statusline.sh \
  < tests/fixtures/zwei-accounts.json > /dev/null
ls "$sandbox/.claude/statusline-accounts/"
rm -rf "$sandbox"
```

Erwartet: nur die bbb-Datei. Das ist der rote Zustand.

- [ ] **Schritt 4: Identität und Snapshot schreiben**

Nach dem jq-Block einfügen:

```bash
# --- Account-Identitaet und Snapshot ---
# Der Payload nennt den Account nicht, ~/.claude.json schon. Beides zusammen ergibt
# einen Stand pro Account, aus dem sich der inaktive Account spaeter ablesen laesst.
acct_dir="$HOME/.claude/statusline-accounts"
acct_uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$HOME/.claude.json" 2>/dev/null)
if [ -n "$acct_uuid" ] && [ -n "$five_h$weekly" ]; then
  mkdir -p "$acct_dir"
  acct_file="$acct_dir/${acct_uuid}.json"
  first_seen=$(jq -r '.first_seen // empty' "$acct_file" 2>/dev/null)
  [ -n "$first_seen" ] || first_seen="$NOW"
  echo "$input" | jq -c \
    --arg uuid "$acct_uuid" --argjson now "$NOW" --argjson seen "$first_seen" \
    '{uuid: $uuid, first_seen: $seen, captured_at: $now, rate_limits: (.rate_limits // {})}' \
    > "$acct_file" 2>/dev/null
fi
```

Die Bedingung `[ -n "$five_h$weekly" ]` verhindert, dass eine Sitzung ohne Limits einen leeren Snapshot schreibt und damit einen echten Stand überschreibt.

- [ ] **Schritt 5: Accounts einlesen und sortieren**

Direkt darunter:

```bash
# Alle bekannten Accounts, nach erstem Auftreten sortiert. Der Index im Array ist das
# Label: 0 ist A, 1 ist B, 2 ist C. Ein Fenster, dessen resets_at verstrichen ist, gilt
# als unbenutzt: Claude Code entfernt es aus dem Payload, und das naechste startet erst
# mit dem naechsten Prompt in diesem Account.
accounts="[]"
acct_n=0
if [ -d "$acct_dir" ]; then
  accounts=$(jq -s -c --argjson now "$NOW" '
    map(select(.uuid))
    | sort_by(.first_seen)
    | map(. + {
        wk_used:  (if (.rate_limits.seven_day.resets_at // 0) > $now
                   then (.rate_limits.seven_day.used_percentage // 0) else 0 end),
        wk_reset: (.rate_limits.seven_day.resets_at // 0),
        fh_used:  (if (.rate_limits.five_hour.resets_at // 0) > $now
                   then (.rate_limits.five_hour.used_percentage // 0) else 0 end),
        fh_reset: (.rate_limits.five_hour.resets_at // 0)
      })' "$acct_dir"/*.json 2>/dev/null) || accounts="[]"
  [ -n "$accounts" ] || accounts="[]"
  acct_n=$(echo "$accounts" | jq -r 'length')
fi
```

- [ ] **Schritt 6: Prüfen, dass der Snapshot entsteht**

Denselben Befehl wie in Schritt 3 laufen lassen.
Erwartet: zwei Dateien im Verzeichnis, und

```bash
jq -r '.uuid, .first_seen' "$sandbox/.claude/statusline-accounts/aaaaaaaa-0000-0000-0000-000000000001.json"
```

zeigt die aaa-UUID und `1788870000`.

- [ ] **Schritt 7: Tests, shellcheck, Commit**

`bash tests/run.sh` muss weiter alles grün melden, weil sich an der Ausgabe nichts geändert hat.

```bash
shellcheck statusline.sh tests/setup/zwei-accounts.sh
git add statusline.sh tests/
git commit -m "feat: Snapshot je Account unter ~/.claude/statusline-accounts"
```

---

### Task 5: Zeitreihe und Verbrauchstempo

**Files:**
- Modify: `statusline.sh` (Block direkt nach dem Snapshot)
- Create: `tests/setup/tempo.sh`, `tests/fixtures/tempo.json`, `tests/expected/tempo.txt`

**Interfaces:**
- Consumes: `acct_uuid`, `acct_dir`, `NOW`, `weekly`.
- Produces: `$acct_dir/<uuid>.history` als NDJSON mit je einem Objekt `{"t":<epoch>,"u":<prozent>}`.
- Produces: `burn_24h` als Zahl der über alle Accounts in 24 Stunden verbrauchten Prozentpunkte, leer wenn zu wenig Historie da ist.

- [ ] **Schritt 1: Testfall bauen**

`tests/setup/tempo.sh` legt für den aktiven Account eine Historie an, die in 24 Stunden von 4 auf 24 Prozent steigt, also 20 Punkte:

```bash
#!/usr/bin/env bash
set -u
sandbox=$1
now=${STATUSLINE_NOW:-1788870000}
uuid="aaaaaaaa-0000-0000-0000-000000000001"

mkdir -p "$sandbox/.claude/statusline-accounts"
cat > "$sandbox/.claude.json" <<JSON
{ "oauthAccount": { "accountUuid": "$uuid" } }
JSON
{
  echo "{\"t\":$((now - 90000)),\"u\":2}"
  echo "{\"t\":$((now - 86400)),\"u\":4}"
  echo "{\"t\":$((now - 43200)),\"u\":14}"
  echo "{\"t\":$((now - 600)),\"u\":24}"
} > "$sandbox/.claude/statusline-accounts/${uuid}.history"
```

Der erste Eintrag liegt älter als 24 Stunden und darf nicht mitzählen.

- [ ] **Schritt 2: Historie schreiben**

```bash
# --- Verbrauchs-Historie je Account ---
# Nur bei geaendertem Wert und hoechstens alle fuenf Minuten anhaengen, sonst waechst
# die Datei mit jedem Turn. Alles aelter als 48 Stunden faellt beim Schreiben raus.
if [ -n "$acct_uuid" ] && [ -n "$weekly" ]; then
  hist_file="$acct_dir/${acct_uuid}.history"
  last_line=$(tail -1 "$hist_file" 2>/dev/null)
  last_t=$(echo "$last_line" | jq -r '.t // 0' 2>/dev/null || echo 0)
  last_u=$(echo "$last_line" | jq -r '.u // -1' 2>/dev/null || echo -1)
  if [ "$weekly" != "$last_u" ] && [ $((NOW - last_t)) -ge 300 ]; then
    printf '{"t":%d,"u":%d}\n' "$NOW" "$weekly" >> "$hist_file"
    cutoff=$((NOW - 172800))
    tmp_hist="${hist_file}.tmp"
    if jq -c --argjson cut "$cutoff" 'select(.t >= $cut)' "$hist_file" > "$tmp_hist" 2>/dev/null; then
      mv "$tmp_hist" "$hist_file"
    else
      rm -f "$tmp_hist"
    fi
  fi
fi
```

- [ ] **Schritt 3: Tempo berechnen**

```bash
# --- Verbrauchstempo der letzten 24 Stunden ueber alle Accounts ---
# Summe der Zuwaechse. Faellt der Wert, hat das Fenster zurueckgesetzt: dann zaehlt der
# neue Stand selbst als Verbrauch, nicht die negative Differenz.
burn_24h=""
if [ "$acct_n" -ge 1 ]; then
  burn_24h=$(cat "$acct_dir"/*.history 2>/dev/null | jq -s -r --argjson from "$((NOW - 86400))" '
    map(select(.t >= $from))
    | if length < 2 then empty
      else . as $rows
        | [range(1; ($rows | length))
           | ($rows[.].u - $rows[. - 1].u) as $d
           | if $d >= 0 then $d else $rows[.].u end]
        | add
      end')
fi
```

Achtung: `cat` über mehrere Historien vermischt die Accounts. Solange nur ein Account gleichzeitig verbraucht, stimmt die Summe trotzdem, weil die Einträge des inaktiven Accounts sich nicht ändern. Bleibt der Wert eines Accounts konstant, erzeugt er keine neuen Zeilen.

- [ ] **Schritt 4: Tempo sichtbar prüfen**

Zum Prüfen vorübergehend `printf 'burn=%s\n' "$burn_24h" >&2` ans Ende setzen und den Lauf aus Task 4 Schritt 3 mit `tests/setup/tempo.sh` wiederholen.
Erwartet: `burn=20`. Danach die Zeile wieder entfernen.

- [ ] **Schritt 5: Tests, shellcheck, Commit**

```bash
bash tests/run.sh
shellcheck statusline.sh tests/setup/tempo.sh
git add statusline.sh tests/
git commit -m "feat: Verbrauchs-Historie je Account und 24h-Tempo"
```

---

### Task 6: Limit-Zeile pro Account und Runway

**Files:**
- Modify: `statusline.sh` (Segmente 5a bis 5c)
- Modify: `tests/expected/zwei-accounts.txt`

**Interfaces:**
- Consumes: `accounts`, `acct_n`, `acct_uuid`, `burn_24h`, `NOW`.
- Produces: `seg_rate`, `seg_weekly` mit Account-Buchstaben ab `acct_n >= 2`, `seg_runway` an Stelle von `seg_daily`.

- [ ] **Schritt 1: Erwartung schreiben**

`tests/expected/zwei-accounts.txt`, Zeile 4:

```
5h A 23% (3h20m) B frei | wk A 24% (5.2d) B 78% (0.9d) | rw oo
```

Ohne Historie ist `burn_24h` leer, das Tempo also unbekannt. Dann zeigt der Runway `rw ?`. Die Erwartung entsprechend auf `rw ?` setzen und den `rw oo`-Fall in Task 7 über `tests/setup/tempo.sh` prüfen.

Run: `bash tests/run.sh`
Erwartet: `FEHLER zwei-accounts`.

- [ ] **Schritt 2: Buchstabe des aktiven Accounts bestimmen**

```bash
# Label aus der Sortierung: Index 0 ist A. Bei nur einem Account bleibt es leer, dann
# sieht die Zeile aus wie vor dem Umbau.
acct_label() {
  local uuid=$1
  [ "$acct_n" -ge 2 ] || return 0
  echo "$accounts" | jq -r --arg u "$uuid" '
    (map(.uuid) | index($u)) as $i
    | if $i == null then "" else ("ABCDEFGH" | split("")[$i]) end'
}
```

- [ ] **Schritt 3: 5h-Segment je Account**

Der folgende Block gehört **innerhalb** des bestehenden `if [ -n "$five_h" ]` ans Ende, weil er `$col`, `$rate_val` und `$cd` aus diesem Block verwendet. Steht er außerhalb, sind die Variablen leer und das Segment bricht still zusammen.

```bash
if [ "$acct_n" -ge 2 ]; then
  lbl=$(acct_label "$acct_uuid")
  seg_rate="${col}5h ${lbl} ${rate_val}%${cd}${RESET}"
  # Inaktive Accounts: "frei", wenn ihr 5h-Fenster durch ist, sonst Stand und Restzeit.
  others=$(echo "$accounts" | jq -r --arg u "$acct_uuid" --argjson now "$NOW" '
    to_entries[] | select(.value.uuid != $u)
    | ("ABCDEFGH" | split("")[.key]) as $lbl
    | if .value.fh_reset <= $now then "\($lbl) frei"
      else "\($lbl) \(.value.fh_used)%" end' | tr '\n' ' ')
  seg_rate="${seg_rate}${C_SEP} ${others% }${RESET}"
fi
```

- [ ] **Schritt 4: Wochen-Segment je Account mit Restlaufzeit**

```bash
if [ "$acct_n" -ge 2 ]; then
  seg_weekly=$(echo "$accounts" | jq -r --argjson now "$NOW" '
    to_entries[]
    | ("ABCDEFGH" | split("")[.key]) as $lbl
    | (if .value.wk_reset > $now then (.value.wk_reset - $now) / 86400 else 7 end) as $d
    | "\($lbl) \(.value.wk_used)% (\($d * 10 | round / 10)d)"' | tr '\n' ' ')
  seg_weekly="${C_CTX}wk ${seg_weekly% }${RESET}"
fi
```

Ein Fenster, dessen `resets_at` verstrichen ist, bekommt volle sieben Tage, weil es erst mit dem nächsten Prompt neu startet.

`seg_weekly_opus` bleibt unangetastet und zeigt weiter nur den aktiven Account. Das dokumentierte Payload-Schema kennt kein `weekly_opus`; das Skript fragt es defensiv ab, aber ein Snapshot-Format für ein Feld zu bauen, das nie ankommt, wäre ungetesteter Code.

- [ ] **Schritt 5: Runway an Stelle des Deltas**

Den Block `Segment 5a` um einen zweiten Zweig erweitern. Bei `acct_n` unter 2 bleibt das Delta unverändert. Ab 2:

```bash
# --- Segment 5a: Runway ueber das Gesamtbudget (ersetzt das Delta ab 2 Accounts) ---
# Nachfuellrate ist N mal 100 Punkte pro 7 Tage. Liegt das Tempo darunter, laeuft das
# Budget nie leer. Darueber bleiben Rest / (Tempo - Nachfuellrate) Tage. Die Rechnung
# glaettet die einzelnen Resets zu einem gleichmaessigen Zufluss und liegt deshalb um
# Stunden daneben, wenn ein Reset unmittelbar bevorsteht.
if [ "$acct_n" -ge 2 ]; then
  if [ -z "$burn_24h" ]; then
    seg_daily="${C_SEP}rw ?${RESET}"
  else
    rest=$(echo "$accounts" | jq -r 'map(100 - .wk_used) | add')
    seg_daily=$(awk -v rest="$rest" -v rate="$burn_24h" -v n="$acct_n" \
      -v ok="$C_CTX_OK" -v warn="$C_WARN" -v mid="$C_CTX" -v rst="$RESET" 'BEGIN{
      refill = n * 100 / 7
      if (rate <= refill) { printf "%srw oo%s", ok, rst; exit }
      d = rest / (rate - refill)
      col = (d < 1) ? warn : ((d < 3) ? mid : ok)
      printf "%srw %.1fd%s", col, d, rst
    }')
  fi
fi
```

- [ ] **Schritt 6: Runway mit echter Zahl prüfen**

Der Fall oben zeigt `rw ?`, weil keine Historie da ist. Ein zweiter Fall deckt die Rechnung ab. `tests/setup/runway-knapp.sh` ist `tests/setup/zwei-accounts.sh` plus einer Historie, die in 24 Stunden 60 Punkte verbraucht:

```bash
{
  echo "{\"t\":$((now - 86400)),\"u\":0}"
  echo "{\"t\":$((now - 43200)),\"u\":30}"
  echo "{\"t\":$((now - 600)),\"u\":60}"
} > "$sandbox/.claude/statusline-accounts/aaaaaaaa-0000-0000-0000-000000000001.history"
```

`tests/fixtures/runway-knapp.json` ist `basis.json` mit `seven_day.used_percentage` auf 60. Rest ist dann 40 plus 22 gleich 62, die Nachfüllrate bei zwei Accounts 28,6, das Tempo 60. Erwartet: `rw 2.0d`.

Ein dritter Fall `runway-endlos.sh` mit nur 10 Punkten in 24 Stunden muss `rw oo` ergeben, weil 10 unter 28,6 liegt.

Run: `bash tests/run.sh`
Erwartet: beide Fälle grün.

- [ ] **Schritt 7: Tests, shellcheck, Commit**

```bash
bash tests/run.sh
shellcheck statusline.sh tests/setup/*.sh
git add statusline.sh tests/
git commit -m "feat: Limit-Zeile je Account und Runway ueber das Gesamtbudget"
```

---

### Task 7: Wechselsignal

**Files:**
- Modify: `statusline.sh` (neues Segment nach 5c, Zusammenbau von `line4`)
- Create: `tests/setup/wechsel-verfall.sh`, `tests/fixtures/wechsel-verfall.json`, `tests/expected/wechsel-verfall.txt`
- Create: `tests/setup/wechsel-erschoepft.sh`, `tests/fixtures/wechsel-erschoepft.json`, `tests/expected/wechsel-erschoepft.txt`
- Create: `tests/setup/wechsel-blockiert.sh`, `tests/fixtures/wechsel-blockiert.json`, `tests/expected/wechsel-blockiert.txt`

**Interfaces:**
- Consumes: `accounts`, `acct_n`, `acct_uuid`, `NOW`.
- Produces: `seg_switch`, leer wenn kein Wechsel lohnt.

- [ ] **Schritt 1: Drei Fälle als Fixtures**

`wechsel-verfall`: aktiver Account A mit 24 Prozent und 5,2 Tagen Restlaufzeit, Account B mit 78 Prozent und 0,9 Tagen, dessen 5h-Fenster ist durch. Verfallsrate A ist 76 durch 5,2 gleich 14,6, B ist 22 durch 0,9 gleich 24,4. Erwartet: Pfeil zu B.

`wechsel-erschoepft`: aktiver Account A mit 97 Prozent im 5h-Fenster, B frisch mit 0 Prozent und sieben Tagen. Verfallsrate von B ist 14,3 und damit niedriger als die von A, trotzdem muss der Pfeil kommen, weil A am Anschlag ist.

`wechsel-blockiert`: wie `wechsel-verfall`, aber Bs 5h-Fenster läuft noch und steht bei 96 Prozent. Erwartet: kein Pfeil.

Die Setup-Skripte folgen dem Muster aus `tests/setup/zwei-accounts.sh`, mit angepassten Werten in der bbb-Datei.

- [ ] **Schritt 2: Erwartungen schreiben, Tests scheitern lassen**

In `wechsel-verfall.txt` und `wechsel-erschoepft.txt` endet Zeile 4 auf `| -> B`, in `wechsel-blockiert.txt` nicht.

Run: `bash tests/run.sh`
Erwartet: drei Fehler, weil das Segment fehlt.

- [ ] **Schritt 3: Signal berechnen**

```bash
# --- Segment: Wechselsignal ---
# Zwei Gruende, in einen anderen Account zu wechseln. Erstens Erschoepfung: hier ist
# Schluss, woanders nicht. Zweitens Verfall: dort laeuft mehr Budget pro Tag ab als
# hier, es geht also verloren, wenn es liegen bleibt. Beides zaehlt nur, wenn im Ziel
# ueberhaupt 5h-Kapazitaet frei ist, sonst bringt der Wechsel nichts.
seg_switch=""
if [ "$acct_n" -ge 2 ] && [ -n "$acct_uuid" ]; then
  target=$(echo "$accounts" | jq -r --arg u "$acct_uuid" --argjson now "$NOW" '
    (map(select(.uuid == $u)) | first) as $me
    | (if $me.wk_reset > $now then ($me.wk_reset - $now) / 86400 else 7 end) as $me_days
    | ((100 - $me.wk_used) / $me_days) as $me_decay
    | ($me.fh_used >= 95 or $me.wk_used >= 95) as $me_done
    | [ to_entries[]
        | select(.value.uuid != $u)
        | ("ABCDEFGH" | split("")[.key]) as $lbl
        | (if .value.fh_reset <= $now then 0 else .value.fh_used end) as $fh
        | select($fh < 95)
        | (if .value.wk_reset > $now then (.value.wk_reset - $now) / 86400 else 7 end) as $days
        | ((100 - .value.wk_used) / $days) as $decay
        | select($me_done or $decay > $me_decay)
        | {lbl: $lbl, decay: $decay}
      ]
    | sort_by(-.decay) | first | .lbl // empty')
  if [ -n "$target" ]; then
    seg_switch="${C_WARN}-> ${target}${RESET}"
  fi
fi
```

- [ ] **Schritt 4: Segment in die Zeile hängen**

```bash
line4=$(join_segs "$seg_rate" "$seg_daily" "$seg_weekly" "$seg_weekly_opus" "$seg_switch")
```

- [ ] **Schritt 5: Tests, shellcheck, Commit**

```bash
bash tests/run.sh
shellcheck statusline.sh tests/setup/*.sh
git add statusline.sh tests/
git commit -m "feat: Wechselsignal bei Erschoepfung oder drohendem Verfall"
```

---

### Task 8: CI, README und Version

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`, `README.md`, `statusline.sh` (VERSION)

- [ ] **Schritt 1: CI-Workflow**

```yaml
name: ci

on:
  push:
    branches: ['**']
  pull_request:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Lint with shellcheck
        run: shellcheck statusline.sh tests/run.sh tests/setup/*.sh

      - name: Run tests
        run: bash tests/run.sh
```

- [ ] **Schritt 2: Tests auch im Release-Gate**

In `.github/workflows/release.yml` nach dem shellcheck-Schritt:

```yaml
      - name: Run tests
        run: bash tests/run.sh
```

und den vorhandenen shellcheck-Schritt auf `shellcheck statusline.sh tests/run.sh tests/setup/*.sh` erweitern.

- [ ] **Schritt 3: README ergänzen**

Ein Abschnitt zu mehreren Accounts: was die vier Zeilen zeigen, dass die Mehr-Account-Anzeige erst ab dem zweiten erkannten Account erscheint, wo die Snapshots liegen und wie man einen versehentlich erfassten Account wieder loswird (`rm ~/.claude/statusline-accounts/<uuid>.json` samt zugehöriger `.history`). Dazu die Erklärung von `rw` und `->`.

- [ ] **Schritt 4: Version anheben**

`VERSION="1.2.0"` in `statusline.sh`. Neue Segmente ohne Bruch bestehender Nutzung, also die mittlere Stelle.

- [ ] **Schritt 5: Alles prüfen**

```bash
bash tests/run.sh
shellcheck statusline.sh tests/run.sh tests/setup/*.sh
```

- [ ] **Schritt 6: Commit**

```bash
git add .github/ README.md statusline.sh
git commit -m "ci: shellcheck und Tests bei jedem Push, README und v1.2.0"
```
