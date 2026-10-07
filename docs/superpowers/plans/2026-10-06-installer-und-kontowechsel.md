# Installer und Kontowechsel per Klick: Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein `install.sh` installiert und aktualisiert die Statusline, richtet auf Wunsch `claude-swap` samt Klick-Handler für `claude-statusline://switch` ein, und die Statusline verlinkt ihr Wechselsignal auf diesen Handler, sobald er installiert ist.

**Architecture:** `statusline.sh` bleibt eine Einzeldatei und lernt nur zwei Dinge: die Mail je Account im Snapshot und das Link-Ziel über eine Marker-Datei. `install.sh` ist ebenfalls eine Einzeldatei (Release-Asset, läuft per `curl | bash`) und trägt Handler-Rumpf und AppleScript als eingebettete Heredocs. Getestet wird alles von außen: Installer und Handler in einer Sandbox mit eigenem `HOME`, einem `PATH` nur aus Sandbox-Fakes und ausgewählten echten Werkzeugen, sodass kein echtes `cswap`, `uv`, `osacompile` oder `lsregister` je erreichbar ist.

**Tech Stack:** bash (3.2-kompatibel), jq, GitHub Actions mit shellcheck. Tests als bash-Skripte ohne Framework, wie die vorhandenen.

**Spec:** `docs/superpowers/specs/2026-10-06-installer-und-kontowechsel-design.md`

## Global Constraints

- `statusline.sh` bleibt eine einzige ausführbare Datei. Sie startet durch diese Arbeit **keinen zusätzlichen Prozess** pro Lauf: `tests/forks.sh` deckelt bei `max_processes=12` und `max_jq_calls=6`, beide Werte bleiben unverändert.
- Ohne Marker-Datei und ohne `CLAUDE_STATUSLINE_SWITCH_URL` ist die Ausgabe Byte für Byte wie in 1.5.0. Prüfbar daran, dass `bash tests/freeze.sh` keine vorhandene Datei in `tests/expected/` ändert.
- `install.sh` und der Handler laufen unter **bash 3.2** (`/bin/bash` auf macOS): keine assoziativen Arrays, kein `mapfile`, kein `${var,,}`, kein `[[ -v ]]`, Regex nur über eine Variable (`[[ $x =~ $re ]]`).
- `install.sh` steht komplett in Funktionen, die letzte Zeile ist `main "$@"`. Ein abgerissener Download führt so kein halbes Skript aus.
- `install.sh` liest Antworten **nie von stdin** (bei `curl | bash` ist stdin das Skript selbst), nur von `/dev/tty`. Gibt es kein TTY, gilt `--yes`.
- Rekursiv gelöscht wird in `install.sh` nur über `safe_remove_tree`, und nur das eigene `mktemp -d` des Laufs und exakt `$HOME/Applications/Claude Statusline Switch.app`. Verglichen wird der aufgelöste Pfad. `install.sh` enthält genau eine Zeile mit `rm -rf`.
- `cswap switch` wird nie mit Timeout gestartet, nie im Hintergrund, nie per Signal beendet: cswap rollt einen abgebrochenen Tausch nicht zurück.
- Alles, was ein Nutzer liest (Ausgaben von `install.sh`, Mitteilungen des Handlers, README, CHANGELOG), ist **englisch**, wie das übrige öffentliche Repo. Kein Gedankenstrich als Einschub, auch nicht im Englischen.
- Kommentare auf Deutsch. In **neuen** Dateien (`install.sh`, `tests/install.sh`, `tests/handler.sh`, `tests/extract-handler.sh`, `tests/fakes/*`) mit echten Umlauten. In vorhandenen Dateien (`statusline.sh`, `tests/*.sh`, `tests/setup/*.sh`) im Stil der Datei, dort stehen Umlaute als `ae/oe/ue`.
- Jede neue `.sh`-Datei und jede Datei unter `tests/fakes/` kommt in die shellcheck-Zeile von `ci.yml` **und** `release.yml`. Lokal: `shellcheck -x --source-path=/Users/chris/Sites/claude-code-statusline <dateien>`.
- Tests sind hermetisch: eigenes `HOME` je Fall, `env -u CLAUDE_STATUSLINE_SWITCH_URL` bzw. `env -i`, und Installer- sowie Handler-Tests laufen mit einem `PATH`, der nur aus dem Sandbox-`bin` besteht.
- Shell-Aufrufe beim Bauen: absolute Pfade, kein `cd` als Präfix. Alle Befehle unten nutzen `R=/Users/chris/Sites/claude-code-statusline` nur als Lesehilfe; ausgeschrieben wird der volle Pfad.
- Referenzzeitpunkt der Statusline-Tests bleibt `1788870000`.
- CHANGELOG-Überschrift exakt `## 1.6.0 - YYYY-MM-DD` (Bindestrich, Leerzeichen danach), sonst findet der Release-Workflow die Notizen nicht.

## Verträge zwischen den Teilen

Diese Namen benutzen mehrere Aufgaben. Sie stehen hier einmal und gelten überall.

| Was | Wert |
|---|---|
| URL-Schema | `claude-statusline` |
| Link mit Ziel | `claude-statusline://switch?to=<mail, mit jq @uri kodiert>` |
| Link Rotation | `claude-statusline://switch` |
| Statusline-Skript | `$HOME/.claude/statusline.sh`, in `settings.json` als `~/.claude/statusline.sh` |
| Zustandsordner | `$HOME/.claude/statusline/` |
| Antworten | `$HOME/.claude/statusline/config`, Zeilen `schluessel=wert`, heute nur `swap=on\|off` |
| Handler-Skript | `$HOME/.claude/statusline/switch-handler.sh` |
| Marker | `$HOME/.claude/statusline/switch-handler` (leere Datei, die Statusline prüft per `[ -e ]`) |
| macOS-App | `$HOME/Applications/Claude Statusline Switch.app`, Bundle-ID `io.github.dakaric.claude-statusline-switch` |
| Linux-Desktop-Datei | `$HOME/.local/share/applications/claude-statusline-switch.desktop` |
| Handler-Kopf | Zeile 1 `#!/usr/bin/env bash`, dann `CSWAP_BIN=<%q>` und `JQ_BIN=<%q>`, dann der Rumpf aus `handler_body` |
| Signatur „diese Statusline" | Datei enthält den Text `claude-code-statusline v` |
| Snapshot-Feld | `email` (String) im Account-Snapshot, optional |

**Fakes für die Tests** (`tests/fakes/`, jeder Fake schreibt `<name> <argumente>` als Zeile nach `$FAKE_LOG`):

| Fake | Verhalten |
|---|---|
| `curl` | Nur die Form `curl -fsSL -o ZIEL URL`; kopiert `$FAKE_RELEASE_DIR/<basename der URL>` nach ZIEL, sonst Exit 22. Jede andere Form Exit 2. |
| `uname` | gibt `${FAKE_UNAME:-Linux}` aus |
| `uv` | `tool list` listet `claude-swap v0.26.0`, wenn `$HOME/.local/bin/cswap` existiert; `tool install claude-swap` kopiert `$FAKE_DIR/cswap` dorthin; `tool upgrade claude-swap` Exit 0 |
| `pipx` | `list --short` wie oben mit `claude-swap 0.26.0`; `install claude-swap` wie uv; `upgrade claude-swap` Exit 0 |
| `cswap` | `status`/`list`/`switch` geben `$FAKE_CSWAP_DIR/{status,list,switch}.json` aus (Vorgaben unten), `switch` endet mit dem Exit aus `switch.exit` (Vorgabe 0), `add` Exit 0 |
| `osacompile` | `-o APP SKRIPT`: legt `APP/Contents/Info.plist` an und kopiert SKRIPT nach `APP/Contents/source.applescript` |
| `PlistBuddy`, `codesign`, `lsregister`, `xdg-mime`, `update-desktop-database`, `osascript`, `notify-send` | nur mitschreiben, Exit 0; steht der Name in `$FAKE_FAIL`, Exit 1 |

---

### Task 1: Statusline kennt die Mail und verlinkt auf den Handler

**Files:**
- Modify: `statusline.sh:125-147` (erster Account-Lauf), `statusline.sh:167-198` (Snapshot schreiben), `statusline.sh:212-254` (zweiter Account-Lauf), `statusline.sh:432-453` (Link-Ziel, `link_wrap`), `statusline.sh:769-782` (Segment 5a4)
- Modify: `tests/setup/lib.sh`, `tests/snapshots.sh`, `tests/forks.sh`
- Create: `tests/setup/link-handler-ziel.sh`, `tests/setup/link-handler-rotation.sh`, `tests/setup/link-handler-ohne-mail.sh`, `tests/setup/link-ohne-handler.sh`, `tests/setup/link-variable-gewinnt.sh`
- Create: `tests/fixtures/link-handler-ziel.json`, `tests/fixtures/link-handler-rotation.json`, `tests/fixtures/link-handler-ohne-mail.json`, `tests/fixtures/link-ohne-handler.json`, `tests/fixtures/link-variable-gewinnt.json` (je eine Kopie von `tests/fixtures/zwei-accounts.json`)
- Create: `tests/env/link-variable-gewinnt.env`
- Create: `tests/expected/link-handler-ziel.txt` und die vier weiteren (erzeugt mit `tests/freeze.sh`, von Hand geprüft)

**Interfaces:**
- Consumes: nichts aus anderen Aufgaben.
- Produces: Snapshot-Feld `email`; Link `claude-statusline://switch?to=<@uri-Mail>` auf `-> X`, `claude-statusline://switch` auf `⇄` und auf `-> X` ohne bekannte Mail; Link nur bei existierendem Marker `$HOME/.claude/statusline/switch-handler`; `CLAUDE_STATUSLINE_SWITCH_URL` gewinnt, wenn gültig.
- Produces für Tests: `setup_accounts SANDBOX NOW WK_USED WK_OFF FH_USED FH_OFF [MAIL_A] [MAIL_B]`, `write_snapshot … [MAIL]`, `mark_switch_handler SANDBOX`.

- [ ] **Step 1: Test-Bibliothek um Mails und Marker erweitern**

In `tests/setup/lib.sh` `write_snapshot` und `setup_accounts` ersetzen und `mark_switch_handler` anhängen:

```bash
# Schreibt den Snapshot eines Accounts, wie ihn die Statusline selbst ablegt.
# Argumente: sandbox uuid first_seen captured_at wk_used wk_reset fh_used fh_reset [mail]
write_snapshot() {
  local sandbox=$1 uuid=$2 seen=$3 captured=$4
  local wk_used=$5 wk_reset=$6 fh_used=$7 fh_reset=$8 mail=${9:-}
  local mail_field=""
  [ -n "$mail" ] && mail_field="\"email\": \"$mail\","
  mkdir -p "$sandbox/.claude/statusline-accounts"
  cat > "$sandbox/.claude/statusline-accounts/${uuid}.json" <<JSON
{
  "uuid": "$uuid",
  $mail_field
  "first_seen": $seen,
  "captured_at": $captured,
  "rate_limits": {
    "five_hour": { "used_percentage": $fh_used, "resets_at": $fh_reset },
    "seven_day": { "used_percentage": $wk_used, "resets_at": $wk_reset }
  }
}
JSON
}

# Legt das Sandbox-HOME an: aaa ist der aktive Account und steht in claude.json, bbb ist
# der zweite, dessen Stand nur als Snapshot vorliegt. aaa bekommt bewusst keinen
# Snapshot, der entsteht erst im Lauf mit first_seen = now; bbbs first_seen liegt eine
# Sekunde spaeter, damit aaa Label A behaelt. Die Mails sind optional: ohne sie sieht
# alles aus wie vor 1.6.0.
# Argumente: sandbox now wk_used wk_reset_offset fh_used fh_reset_offset [mail_a] [mail_b]
setup_accounts() {
  local sandbox=$1 now=$2 wk_used=$3 wk_off=$4 fh_used=$5 fh_off=$6
  local mail_a=${7:-} mail_b=${8:-} mail_field=""
  [ -n "$mail_a" ] && mail_field=", \"emailAddress\": \"$mail_a\""
  mkdir -p "$sandbox/.claude/statusline-accounts"
  cat > "$sandbox/.claude.json" <<JSON
{ "oauthAccount": { "accountUuid": "$ACCT_A"$mail_field } }
JSON
  write_snapshot "$sandbox" "$ACCT_B" "$((now + 1))" "$((now - 7200))" \
    "$wk_used" "$((now + wk_off))" "$fh_used" "$((now + fh_off))" "$mail_b"
}

# Legt die Marker-Datei an, die install.sh nach erfolgreicher Handler-Registrierung
# schreibt. Ihre Existenz schaltet den Link auf claude-statusline://switch frei.
mark_switch_handler() {
  mkdir -p "$1/.claude/statusline"
  : > "$1/.claude/statusline/switch-handler"
}
```

- [ ] **Step 2: Fünf Fixtures anlegen**

```bash
for name in link-handler-ziel link-handler-rotation link-handler-ohne-mail link-ohne-handler link-variable-gewinnt; do
  cp /Users/chris/Sites/claude-code-statusline/tests/fixtures/zwei-accounts.json \
    "/Users/chris/Sites/claude-code-statusline/tests/fixtures/$name.json"
done
printf 'CLAUDE_STATUSLINE_SWITCH_URL=http://localhost:7373/sphere?swap=1\n' \
  > /Users/chris/Sites/claude-code-statusline/tests/env/link-variable-gewinnt.env
```

`tests/setup/link-handler-ziel.sh`:

```bash
#!/usr/bin/env bash
# Wie zwei-accounts, mit Handler-Marker und Mails: das Wechselsignal verlinkt auf
# claude-statusline://switch mit Bs Mail als Ziel.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 40 -3600 a@example.com b@example.com
mark_switch_handler "$1"
```

`tests/setup/link-handler-rotation.sh`:

```bash
#!/usr/bin/env bash
# Wie wechsel-blockiert, mit Handler-Marker und Mails: ohne Signal verlinkt das
# angehaengte Zeichen auf die Rotation, ohne Ziel.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 96 7200 a@example.com b@example.com
mark_switch_handler "$1"
```

`tests/setup/link-handler-ohne-mail.sh`:

```bash
#!/usr/bin/env bash
# Wie link-handler-ziel, aber die Snapshots stammen von einer Version ohne Mail: das
# Wechselsignal verlinkt dann auf die Rotation statt auf ein Ziel.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 40 -3600
mark_switch_handler "$1"
```

`tests/setup/link-ohne-handler.sh`:

```bash
#!/usr/bin/env bash
# Mails sind bekannt, aber kein Handler installiert und keine Variable gesetzt: kein
# Link. Die Ausgabe muss exakt der von zwei-accounts entsprechen.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 40 -3600 a@example.com b@example.com
```

`tests/setup/link-variable-gewinnt.sh`:

```bash
#!/usr/bin/env bash
# Handler installiert und Variable gesetzt: die Variable gewinnt. Die Ausgabe muss exakt
# der von link-signal entsprechen.
set -u
# shellcheck source=tests/setup/lib.sh
. "$(dirname "$0")/lib.sh"
setup_accounts "$1" "${STATUSLINE_NOW:-1788870000}" 78 77760 40 -3600 a@example.com b@example.com
mark_switch_handler "$1"
```

- [ ] **Step 3: Robustheitstests für die Mail in `tests/snapshots.sh` schreiben**

Unter `acct_a=…` ergänzen:

```bash
acct_b="bbbbbbbb-0000-0000-0000-000000000002"
```

Vor den Aufrufen am Dateiende einfügen:

```bash
# Die Mail kommt aus ~/.claude.json und gehoert dem Login. Beide Snapshots tragen nach
# einem Lauf ihre eigene: A die aus claude.json, B die aus seinem alten Snapshot.
check_mail_follows_login() {
  local sandbox accounts mail_a mail_b
  sandbox=$(mktemp -d)
  accounts="$sandbox/.claude/statusline-accounts"
  HOME="$sandbox" STATUSLINE_NOW="$test_now" \
    bash "$root/tests/setup/link-handler-ziel.sh" "$sandbox" >/dev/null
  run_statusline "$sandbox" zwei-accounts
  mail_a=$(jq -r '.email // ""' "$accounts/$acct_a.json")
  mail_b=$(jq -r '.email // ""' "$accounts/$acct_b.json")
  rm -rf "$sandbox"
  if [ "$mail_a" != a@example.com ] || [ "$mail_b" != b@example.com ]; then
    printf 'FEHLER snapshots: Mails A=%s B=%s, erwartet a@example.com und b@example.com\n' \
      "$mail_a" "$mail_b"
    return 1
  fi
  printf 'ok     snapshots (Mail landet beim Login)\n'
}

# Eingeloggt ist A, der Payload gehoert noch B (wie fremder-payload). Bs Snapshot wird
# in diesem Lauf geschrieben, darf aber nicht As Mail bekommen: sonst wechselte der Klick
# auf "-> B" zu A.
check_mail_not_given_to_foreign_owner() {
  local sandbox accounts mail_b captured_b
  sandbox=$(mktemp -d)
  accounts="$sandbox/.claude/statusline-accounts"
  (
    # shellcheck source=tests/setup/lib.sh
    . "$root/tests/setup/lib.sh"
    setup_accounts "$sandbox" "$test_now" 5 501120 1 7200 a@example.com
    write_snapshot "$sandbox" "$ACCT_A" "$((test_now - 100))" "$((test_now - 600))" \
      43 "$((test_now + 293760))" 10 "$((test_now + 3600))" a@example.com
  )
  run_statusline "$sandbox" fremder-payload
  mail_b=$(jq -r '.email // ""' "$accounts/$acct_b.json")
  captured_b=$(jq -r '.captured_at' "$accounts/$acct_b.json")
  rm -rf "$sandbox"
  if [ "$captured_b" != "$test_now" ]; then
    printf 'FEHLER snapshots: Bs Snapshot wurde nicht geschrieben, der Fall prueft nichts\n'
    return 1
  fi
  if [ -n "$mail_b" ]; then
    printf 'FEHLER snapshots: B bekam die Mail %s des Logins\n' "$mail_b"
    return 1
  fi
  printf 'ok     snapshots (fremder Besitzer bekommt nicht die Mail des Logins)\n'
}
```

Und am Ende die Aufrufe ergänzen:

```bash
check_mail_follows_login || failed=1
check_mail_not_given_to_foreign_owner || failed=1
```

- [ ] **Step 4: Tests laufen lassen, sie müssen scheitern**

Run: `bash /Users/chris/Sites/claude-code-statusline/tests/snapshots.sh`
Expected: `FEHLER snapshots: Mails A= B=b@example.com …` (A bekommt noch keine Mail). Der zweite neue Check meldet `ok`, weil heute niemand eine Mail schreibt; das ist richtig so, er schützt gegen die Implementierung.

Run: `bash /Users/chris/Sites/claude-code-statusline/tests/run.sh`
Expected: fünf Zeilen `FEHLT  link-…` (noch keine Erwartung hinterlegt).

- [ ] **Step 5: Erster Account-Lauf liefert die Mails**

In `statusline.sh` die `read`-Zeile und das jq-Programm des ersten Laufs (Zeilen 125–144) so ändern. Neu sind `login_mail owner_mail`, `def oneline` und die zwei letzten Array-Elemente:

```bash
IFS="$FIELD_SEP" read -r login_read login_uuid acct_owner acct_replace first_seen old_limits \
  login_mail owner_mail \
  <<< "$(jq -n -R -r --slurpfile claude "$HOME/.claude.json" --arg r "$weekly_reset" \
    --argjson now "$NOW" "$SNAPSHOTS_JQ"'
  def oneline: tostring | gsub("[\n\u001f]"; " ");
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
     ($snapshot.rate_limits // {} | tojson),
     ($claude[0].oauthAccount.emailAddress // "" | oneline),
     ($snapshot.email // "" | oneline)]
  | map(tostring) | join("\u001f")' "${snapshot_files[@]}" < /dev/null 2>/dev/null)"
```

Den Kommentarblock darüber (Zeilen 112–113) um einen Satz ergänzen:

```bash
# Derselbe Lauf liefert first_seen und die bisherigen Limits des Besitzers, dazu ob der
# Snapshot des Logins gelesen wurde, die Mail des Logins aus ~/.claude.json und die
# bisher gespeicherte Mail des Besitzers.
```

- [ ] **Step 6: Snapshot speichert die Mail**

Direkt vor `acct_tmp="${acct_file}.tmp.$$"` (Zeile 179) einfügen:

```bash
  # Die Mail nennt der Klick-Handler cswap als Ziel. ~/.claude.json kennt nur die des
  # Logins, also bekommt nur dessen Snapshot sie. Gehoert der Stand einem anderen Account
  # (eine Session von vor dem Umloggen), bleibt dessen bisherige Mail stehen.
  acct_mail="$owner_mail"
  [ "$acct_uuid" = "$login_uuid" ] && [ -n "$login_mail" ] && acct_mail="$login_mail"
```

Im jq-Aufruf darunter `--arg mail "$acct_mail"` ergänzen und das Ergebnisobjekt um die Mail erweitern:

```bash
  if echo "$input" | jq -c \
    --arg uuid "$acct_uuid" --argjson now "$NOW" --argjson seen "$first_seen" \
    --argjson old "$old_limits" --arg mail "$acct_mail" '
    def later(a; b):
      if a == null then b elif b == null then a
      else [a, b] | max_by([.resets_at // 0, .used_percentage // 0]) end;
    (.rate_limits // {}) as $new
    | {uuid: $uuid, first_seen: $seen, captured_at: $now,
       rate_limits: (reduce (($old + $new) | keys[]) as $k
         ({}; .[$k] = later($old[$k]; $new[$k])))}
      + (if $mail == "" then {} else {email: $mail} end)' \
    > "$acct_tmp" 2>/dev/null; then
```

- [ ] **Step 7: Zweiter Account-Lauf liefert die Mail des Wechselziels**

Die `read`-Zeile (Zeilen 213–214) um `switch_mail` erweitern:

```bash
IFS="$FIELD_SEP" read -r acct_n acct_lbl others rest need switch_to wk_all hist_u hist_r \
  my_fh_used my_fh_reset switch_mail \
```

Im jq-Programm das Ziel einmal als `$target` berechnen, statt nur sein Label im Array. Der Abschnitt ab `| ($accts | sort_by(.wk_days)` bis zum Ende des Arrays lautet danach:

```
  | ($accts | sort_by(.wk_days)
     | reduce .[] as $a ({cum: 0, need: 0};
         .cum += (100 - $a.wk_used)
         | .need = ([.need, .cum / $a.wk_days] | max))) as $runway
  | ($others
     | map((if .fh_reset <= $now then 0 else .fh_used end) as $fh
           | select($fh < 95)
           | ((100 - .wk_used) / .wk_days) as $decay
           | select($me_done or ($decay > $me_decay))
           | {lbl, email, decay: $decay})
     | sort_by(-.decay) | first) as $target
  | [ ($accts | length),
      ($me.lbl // ""),
      ($others | map("\(.lbl) " + (if .fh_reset <= $now then "free" else "\(.fh_used)%" end))
       | join(" ")),
      $runway.cum,
      $runway.need,
      ($target.lbl // ""),
      ($accts | map("\(.lbl) \(.wk_used)% (\((.wk_days * 10 | round) / 10)d)") | join(" ")),
      (if $me.uuid then ($me.wk_used | round) else "" end),
      (if $me.uuid then $me.wk_reset else "" end),
      (if $me.uuid then ($me.fh_used | round) else "" end),
      ($me.rate_limits.five_hour.resets_at | numbers) // "",
      ($target.email // "" | tostring | @uri)
    ] | map(tostring) | join("\u001f")' "${snapshot_files[@]}" < /dev/null 2>/dev/null)"
```

Im Kommentarblock über dem Lauf (Zeilen 206–211) ergänzen:

```bash
# switch_mail: die Mail des Wechselziels, schon fuer eine URL kodiert (@uri macht aus
# "@" "%40" und laesst nur Buchstaben, Ziffern und -_.~ stehen), leer ohne Ziel oder
# ohne bekannte Mail.
```

- [ ] **Step 8: Link-Ziel über Marker, `link_wrap` mit expliziter URL**

Den Block `# --- Optionaler Klick-Link (OSC 8) ---` bis zum Ende von `link_wrap` (Zeilen 432–453) ersetzen:

```bash
# --- Optionaler Klick-Link (OSC 8) ---
# Die Limit-Zeile bekommt einen Cmd+Klick-Link zum Kontowechsel. Das Ziel, in dieser
# Reihenfolge: CLAUDE_STATUSLINE_SWITCH_URL, wenn gesetzt und gueltig, etwa ein eigenes
# Cockpit. Sonst das eigene Schema claude-statusline://switch, aber nur, wenn install.sh
# den Klick-Handler eingerichtet hat: das verraet die Marker-Datei, geprueft mit [ -e ]
# ohne eigenen Prozess. Ohne beides gibt es keinen Link, ein Link ohne Handler waere tot.
# Erlaubt sind nur URLs mit Schema und ohne Leerraum, Steuerzeichen und Backslash: die
# Zeile geht durch printf %b, ein Backslash in der URL wuerde dort zur Steuersequenz.
# NO_COLOR laesst den Link stehen, er ist keine Farbe.
switch_url=""
switch_by_handler=0
url_re='^[A-Za-z][A-Za-z0-9+.-]*://[^[:space:][:cntrl:]\]+$'
if [[ "${CLAUDE_STATUSLINE_SWITCH_URL:-}" =~ $url_re ]]; then
  switch_url="$CLAUDE_STATUSLINE_SWITCH_URL"
elif [ -e "$HOME/.claude/statusline/switch-handler" ]; then
  switch_url="claude-statusline://switch"
  switch_by_handler=1
fi

# link_wrap VAR URL TEXT: VAR wird TEXT als OSC-8-Link auf URL.
# printf -v statt nameref, damit bash 3.2 (macOS) mitlaeuft.
link_wrap() {
  printf -v "$1" '%s' "\033]8;;${2}\033\\\\${3}\033]8;;\033\\\\"
}
```

- [ ] **Step 9: Segment 5a4 setzt das Ziel**

Den Block `# --- Segment 5a4 …` (Zeilen 769–782) ersetzen:

```bash
# --- Segment 5a4: Klick-Link zum Kontowechsel (ergaenzt seg_switch aus 5a3) ---
# Zeigt die Zeile das Wechselsignal, ist es selbst der Link. Ueber den Handler traegt er
# dann die Mail des Ziels, damit der Klick genau dorthin wechselt; ohne bekannte Mail
# bleibt die Rotation. Sonst steht am Ende ein eigenes Zeichen fuer die Rotation, aber
# nur in einer Zeile, die ohnehin Limits zeigt: allein wuerde es eine Zeile nur fuer sich
# aufmachen.
switch_link=""
if [ -n "$switch_url" ]; then
  if [ -n "$seg_switch" ]; then
    target_url="$switch_url"
    if [ "$switch_by_handler" = 1 ] && [ -n "$switch_mail" ]; then
      target_url="${switch_url}?to=${switch_mail}"
    fi
    link_wrap switch_link "$target_url" "-> ${switch_to}"
    seg_switch="${C_WARN}${switch_link}${RESET}"
  elif [ -n "${seg_rate}${seg_weekly}${seg_weekly_opus}${seg_daily}" ]; then
    link_wrap switch_link "$switch_url" "⇄"
    seg_switch="${C_SEP}${switch_link}${RESET}"
  fi
fi
```

- [ ] **Step 10: Erwartungen einfrieren und von Hand prüfen**

Run: `bash /Users/chris/Sites/claude-code-statusline/tests/freeze.sh >/dev/null && git -C /Users/chris/Sites/claude-code-statusline status --short tests/expected`
Expected: genau fünf neue Dateien (`??`), **keine** geänderte (`M`). Steht ein `M` da, hat sich das Verhalten ohne Marker verändert: zurück zu Step 5–9.

Dann die letzte Zeile jeder neuen Datei mit `cat -v` lesen und vergleichen:

```bash
for n in link-handler-ziel link-handler-rotation link-handler-ohne-mail; do
  tail -1 "/Users/chris/Sites/claude-code-statusline/tests/expected/$n.txt" | cat -v; echo
done
cmp /Users/chris/Sites/claude-code-statusline/tests/expected/link-ohne-handler.txt \
    /Users/chris/Sites/claude-code-statusline/tests/expected/zwei-accounts.txt && echo gleich-zwei-accounts
cmp /Users/chris/Sites/claude-code-statusline/tests/expected/link-variable-gewinnt.txt \
    /Users/chris/Sites/claude-code-statusline/tests/expected/link-signal.txt && echo gleich-link-signal
```

Expected:

```text
5h A 23% (3h20m) B free | wk A 24% (5.2d) B 78% (0.9d) | rw ? | ^[]8;;claude-statusline://switch?to=b%40example.com^[\-> B^[]8;;^[\
5h A 23% (3h20m) B 96% | wk A 24% (5.2d) B 78% (0.9d) | rw ? | ^[]8;;claude-statusline://switch^[\M-bM-^GM-^D^[]8;;^[\
5h A 23% (3h20m) B free | wk A 24% (5.2d) B 78% (0.9d) | rw ? | ^[]8;;claude-statusline://switch^[\-> B^[]8;;^[\
gleich-zwei-accounts
gleich-link-signal
```

(`M-bM-^GM-^D` ist `⇄` in `cat -v`.)

- [ ] **Step 11: Prozesswächter deckt den Handler-Pfad ab**

In `tests/forks.sh` nach dem Setup-Aufruf (`bash "$root/tests/setup/runway-knapp.sh" …`) einfügen:

```bash
# Mit Marker laeuft auch der Link-Zweig mit. Er darf keinen Prozess kosten.
mkdir -p "$sandbox/.claude/statusline"
: > "$sandbox/.claude/statusline/switch-handler"
```

und im Messlauf `env -u ENABLE_PROMPT_CACHING_1H` zu `env -u ENABLE_PROMPT_CACHING_1H -u CLAUDE_STATUSLINE_SWITCH_URL` erweitern.

- [ ] **Step 12: Alle Statusline-Tests und shellcheck**

```bash
bash /Users/chris/Sites/claude-code-statusline/tests/run.sh
bash /Users/chris/Sites/claude-code-statusline/tests/snapshots.sh
bash /Users/chris/Sites/claude-code-statusline/tests/forks.sh
bash /Users/chris/Sites/claude-code-statusline/tests/race.sh
bash /Users/chris/Sites/claude-code-statusline/tests/branch.sh
shellcheck -x --source-path=/Users/chris/Sites/claude-code-statusline \
  /Users/chris/Sites/claude-code-statusline/statusline.sh \
  /Users/chris/Sites/claude-code-statusline/tests/*.sh \
  /Users/chris/Sites/claude-code-statusline/tests/setup/*.sh
```

Expected: alles `ok`, `forks` weiterhin höchstens 12 Prozesse, shellcheck ohne Ausgabe.

- [ ] **Step 13: Commit**

```bash
git -C /Users/chris/Sites/claude-code-statusline add statusline.sh tests/
git -C /Users/chris/Sites/claude-code-statusline commit -m "feat(statusline): Mail je Account und Link auf den Klick-Handler"
```

---

### Task 2: Installer-Grundgerüst mit Download, Prüfsumme, settings.json und Löschwächter

**Files:**
- Create: `install.sh`
- Create: `tests/install.sh`
- Create: `tests/fakes/curl`, `tests/fakes/uname`, `tests/fakes/uv`, `tests/fakes/pipx`, `tests/fakes/cswap`, `tests/fakes/osacompile`, `tests/fakes/PlistBuddy`, `tests/fakes/codesign`, `tests/fakes/lsregister`, `tests/fakes/xdg-mime`, `tests/fakes/update-desktop-database`, `tests/fakes/osascript`, `tests/fakes/notify-send` (alle ausführbar)

**Interfaces:**
- Consumes: nichts.
- Produces (Funktionen in `install.sh`, von Task 3–5 benutzt): `die MSG`, `info MSG`, `warn MSG`, `ask_yes_no FRAGE y|n`, `config_get KEY`, `config_set KEY VALUE`, `safe_remove_tree PFAD`, `write_settings JQ_FILTER [JQ_ARGS…]`, `current_statusline_command`, `points_to_this_statusline BEFEHL`; Globale `OS` (`macos|linux`), `TMP_DIR`, `ASSUME_YES`, `SWAP_FLAG` (`on|off|""`), `UNINSTALL`, `CLAUDE_DIR`, `STATUSLINE_PATH`, `SETTINGS_PATH`, `STATE_DIR`, `CONFIG_PATH`, `HANDLER_PATH`, `MARKER_PATH`, `APP_PATH`, `DESKTOP_PATH`, `APP_NAME`, `URL_SCHEME`, `DESKTOP_NAME`, `STATUSLINE_COMMAND`, `MACOS_TOOL_DIRS`.
- Produces (Test-Harness in `tests/install.sh`, von Task 4–5 erweitert): `new_sandbox`, `run_installer ARGS…` (hängt immer `--yes` an), `has_log MUSTER`, `fail TEXT`, `ok TEXT`, Globale `sb`, `home`, `failed`.

- [ ] **Step 1: Fakes anlegen**

`tests/fakes/curl`:

```bash
#!/usr/bin/env bash
# Fake für curl im Installer-Test: liefert Dateien aus FAKE_RELEASE_DIR statt aus dem
# Netz. Erlaubt ist nur die Form, die install.sh für Release-Dateien benutzt:
# curl -fsSL -o ZIEL URL. Jede andere Form, etwa der uv-Installer von astral, scheitert,
# damit sie im Test nicht unbemerkt durchläuft.
set -u
printf 'curl %s\n' "$*" >> "$FAKE_LOG"
if [ "$#" -ne 4 ] || [ "$1" != -fsSL ] || [ "$2" != -o ]; then
  exit 2
fi
source_file="$FAKE_RELEASE_DIR/${4##*/}"
[ -f "$source_file" ] || exit 22
cp "$source_file" "$3"
```

`tests/fakes/uname`:

```bash
#!/usr/bin/env bash
# Fake für uname: der Test wählt das Betriebssystem, damit beide Zweige auf jedem
# Rechner laufen.
printf '%s\n' "${FAKE_UNAME:-Linux}"
```

`tests/fakes/uv`:

```bash
#!/usr/bin/env bash
# Fake für uv: installiert cswap als Kopie des cswap-Fakes nach ~/.local/bin, wie uv
# tool install es täte.
set -u
printf 'uv %s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  "tool list")
    [ -x "$HOME/.local/bin/cswap" ] && printf 'claude-swap v0.26.0\n- cswap\n'
    exit 0 ;;
  "tool install claude-swap")
    mkdir -p "$HOME/.local/bin" && cp "$FAKE_DIR/cswap" "$HOME/.local/bin/cswap" ;;
  "tool upgrade claude-swap")
    exit 0 ;;
  *)
    exit 2 ;;
esac
```

`tests/fakes/pipx`:

```bash
#!/usr/bin/env bash
# Fake für pipx, Gegenstück zum uv-Fake.
set -u
printf 'pipx %s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  "list --short")
    [ -x "$HOME/.local/bin/cswap" ] && printf 'claude-swap 0.26.0\n'
    exit 0 ;;
  "install claude-swap")
    mkdir -p "$HOME/.local/bin" && cp "$FAKE_DIR/cswap" "$HOME/.local/bin/cswap" ;;
  "upgrade claude-swap")
    exit 0 ;;
  *)
    exit 2 ;;
esac
```

`tests/fakes/cswap`:

```bash
#!/usr/bin/env bash
# Fake für cswap. Antworten liegen als Dateien in FAKE_CSWAP_DIR, damit jeder Testfall
# sie selbst bestimmt. Ohne Datei antwortet er wie ein cswap ohne Login und ohne Konten.
set -u
printf 'cswap %s\n' "$*" >> "$FAKE_LOG"
state=${FAKE_CSWAP_DIR:?}
case "${1:-}" in
  status)
    cat "$state/status.json" 2>/dev/null || printf '{"schemaVersion":1,"active":null}\n' ;;
  list)
    cat "$state/list.json" 2>/dev/null || printf '{"schemaVersion":1,"accounts":[]}\n' ;;
  switch)
    cat "$state/switch.json" 2>/dev/null
    exit "$(cat "$state/switch.exit" 2>/dev/null || echo 0)" ;;
  add)
    exit 0 ;;
  --version)
    printf 'cswap 0.26.0\n' ;;
  *)
    exit 2 ;;
esac
```

`tests/fakes/osacompile`:

```bash
#!/usr/bin/env bash
# Fake für osacompile -o APP SKRIPT: legt das Gerüst einer App an und legt das
# AppleScript daneben, damit der Test seinen Inhalt prüfen kann.
set -u
printf 'osacompile %s\n' "$*" >> "$FAKE_LOG"
[ "$#" -eq 3 ] && [ "$1" = -o ] || exit 2
mkdir -p "$2/Contents/MacOS"
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict/></plist>\n' > "$2/Contents/Info.plist"
cp "$3" "$2/Contents/source.applescript"
```

Die sieben reinen Mitschreiber unterscheiden sich nur im Namen und werden in einem Zug erzeugt:

```bash
for tool in PlistBuddy codesign lsregister xdg-mime update-desktop-database osascript notify-send; do
  cat > "/Users/chris/Sites/claude-code-statusline/tests/fakes/$tool" <<EOF
#!/usr/bin/env bash
# Fake für $tool: schreibt den Aufruf mit. Steht der Name in FAKE_FAIL, scheitert er.
set -u
printf '$tool %s\n' "\$*" >> "\$FAKE_LOG"
case " \${FAKE_FAIL:-} " in *" $tool "*) exit 1 ;; esac
exit 0
EOF
done
chmod +x /Users/chris/Sites/claude-code-statusline/tests/fakes/*
```

Danach muss etwa `tests/fakes/lsregister` genau so aussehen:

```bash
#!/usr/bin/env bash
# Fake für lsregister: schreibt den Aufruf mit. Steht der Name in FAKE_FAIL, scheitert er.
set -u
printf 'lsregister %s\n' "$*" >> "$FAKE_LOG"
case " ${FAKE_FAIL:-} " in *" lsregister "*) exit 1 ;; esac
exit 0
```

- [ ] **Step 2: Test-Harness und Grundtests schreiben**

`tests/install.sh`:

```bash
#!/usr/bin/env bash
# Tests für install.sh. Jeder Fall bekommt eine eigene Sandbox: ein HOME, einen PATH nur
# aus Fakes und ausgewählten echten Werkzeugen, und ein Release-Verzeichnis, aus dem der
# curl-Fake liefert. Ein echtes cswap, uv, osacompile oder lsregister ist so nie
# erreichbar. Jeder Lauf bekommt --yes: ohne würde der Installer auf /dev/tty fragen und
# ein Test im Terminal hinge.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
failed=0
sb=""
home=""

real_tools="bash env cat cp mv rm mkdir chmod grep awk sed date mktemp rmdir dirname jq sha256sum shasum"
fake_tools="curl uname uv osacompile PlistBuddy codesign lsregister xdg-mime update-desktop-database osascript notify-send"

sha256_line() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

new_sandbox() {
  local tool real
  sb=$(mktemp -d)
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
}

drop_sandbox() { rm -rf "$sb"; }

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
  elif [ "$(jq -r '.statusLine.command' "$home/.claude/settings.json")" != "~/.claude/statusline.sh" ]; then
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
  backups=$(ls "$home/.claude" | grep -c '^settings\.json\.bak-')
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

check_bad_checksum_keeps_old_file() {
  new_sandbox
  mkdir -p "$home/.claude"
  printf 'OLD\n' > "$home/.claude/statusline.sh"
  printf '%064d  statusline.sh\n' 0 > "$sb/release/SHA256SUMS"
  if run_installer; then fail "falsche Prüfsumme endet ohne Fehler"
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
  elif [ "$(cat "$home/.claude/settings.json")" != '{ kaputt' ]; then fail "ungültige settings.json verändert"
  elif ls "$home/.claude" | grep -q '^settings\.json\.bak-'; then fail "Sicherung trotz Abbruch angelegt"
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
  if run_installer --version 'v1.6.0/../x'; then fail "unsinniger Tag wird angenommen"; fi
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

check_home_guard() {
  local bad before=$failed
  new_sandbox
  for bad in "" "/" "relativ/pfad"; do
    if env -i HOME="$bad" TMPDIR="$sb/tmp" PATH="$sb/bin" FAKE_LOG="$sb/log" \
        FAKE_RELEASE_DIR="$sb/release" "$BASH" "$root/install.sh" --yes < /dev/null > "$sb/out" 2>&1; then
      fail "HOME='$bad' wird angenommen"
    fi
  done
  [ -s "$sb/log" ] && fail "bei unbrauchbarem HOME wurde trotzdem etwas aufgerufen"
  [ "$failed" = "$before" ] && ok "unbrauchbares HOME bricht vor allem anderen ab"
  drop_sandbox
}

# Statischer Wächter: rekursives Löschen gibt es nur an einer Stelle, in safe_remove_tree.
check_single_recursive_delete() {
  local count others
  count=$(grep -c 'rm -rf' "$root/install.sh")
  others=$(grep -nE 'rm -r[^f]|rm -fr|rm -Rf|find .*-delete|rmtree' "$root/install.sh")
  if [ "$count" != 1 ] || [ -n "$others" ]; then
    printf 'FEHLER install rekursives Löschen an %s Stellen\n%s\n' "$count" "$others"
    failed=1
  else
    printf 'ok     install (rekursives Löschen nur in safe_remove_tree)\n'
  fi
}

check_fresh_install
check_keeps_foreign_keys
check_foreign_statusline_kept
check_bad_checksum_keeps_old_file
check_missing_checksum_line_fails
check_invalid_settings_aborts
check_release_tag
check_windows_refused
check_jq_missing
check_home_guard
check_single_recursive_delete
exit "$failed"
```

- [ ] **Step 3: Test laufen lassen, er muss scheitern**

Run: `bash /Users/chris/Sites/claude-code-statusline/tests/install.sh`
Expected: `FEHLER install …` für jeden Fall, auch für den statischen Wächter, weil `install.sh` noch fehlt.

- [ ] **Step 4: `install.sh` schreiben**

```bash
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
  {
    if [ -f "$CONFIG_PATH" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$key="*) ;; *) printf '%s\n' "$line" ;; esac
      done < "$CONFIG_PATH"
    fi
    printf '%s=%s\n' "$key" "$value"
  } > "$tmp" && mv -f "$tmp" "$CONFIG_PATH" || { rm -f "$tmp"; die "cannot write $CONFIG_PATH"; }
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
  staged="$CLAUDE_DIR/.statusline.sh.new.$$"
  if ! { cp "$new" "$staged" && chmod 755 "$staged" && mv -f "$staged" "$STATUSLINE_PATH"; }; then
    rm -f "$staged"
    die "cannot write $STATUSLINE_PATH"
  fi
  info "Installed $("$STATUSLINE_PATH" --version) to $STATUSLINE_PATH"
}

# --- settings.json ---
check_settings_readable() {
  [ -e "$SETTINGS_PATH" ] || return 0
  jq -e 'type == "object"' "$SETTINGS_PATH" >/dev/null 2>&1 \
    || die "$SETTINGS_PATH is not a valid JSON object. Nothing was changed."
}

current_statusline_command() {
  [ -e "$SETTINGS_PATH" ] || return 0
  jq -r '.statusLine.command // "" | tostring' "$SETTINGS_PATH"
}

# Zeigt ein statusLine-Befehl auf diese Statusline? Erkannt wird ein einzelner Pfad, mit
# ~/ am Anfang oder absolut, dessen Datei die Versionskennung dieses Projekts trägt.
points_to_this_statusline() {
  local path
  case "$1" in
    ""|*[[:space:]]*) return 1 ;;
    "~/"*) path="$HOME/${1#\~/}" ;;
    /*) path=$1 ;;
    *) return 1 ;;
  esac
  [ -f "$path" ] && grep -q 'claude-code-statusline v' "$path" 2>/dev/null
}

# write_settings FILTER [JQ-ARGUMENTE]: wendet FILTER auf settings.json an. Vorher eine
# Sicherung daneben, geschrieben über eine Temp-Datei, damit ein Fehler nie eine halbe
# Datei hinterlässt. Ein Symlink (etwa in ein Dotfiles-Repo) bleibt ein Symlink.
write_settings() {
  local filter=$1 tmp backup
  shift
  mkdir -p "$CLAUDE_DIR" || die "cannot create $CLAUDE_DIR"
  tmp="$SETTINGS_PATH.tmp.$$"
  if [ -e "$SETTINGS_PATH" ]; then
    backup="$SETTINGS_PATH.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$SETTINGS_PATH" "$backup" || die "cannot back up $SETTINGS_PATH"
    jq "$@" "$filter" "$SETTINGS_PATH" > "$tmp"
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
  if [ -n "$current" ] && points_to_this_statusline "$current"; then
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
  write_settings '.statusLine = ((if (.statusLine | type) == "object" then .statusLine else {} end)
    + {type: "command", command: $cmd})' --arg cmd "$STATUSLINE_COMMAND"
  info "Set statusLine in $SETTINGS_PATH."
}

main() {
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
```

- [ ] **Step 5: Tests laufen lassen, sie müssen bestehen**

```bash
bash /Users/chris/Sites/claude-code-statusline/tests/install.sh
shellcheck -x --source-path=/Users/chris/Sites/claude-code-statusline \
  /Users/chris/Sites/claude-code-statusline/install.sh \
  /Users/chris/Sites/claude-code-statusline/tests/install.sh \
  /Users/chris/Sites/claude-code-statusline/tests/fakes/*
```

Expected: nur `ok     install (…)`-Zeilen, Exit 0; shellcheck ohne Ausgabe. Der lokale Lauf nutzt `/bin/bash` 3.2 (`$BASH` des Testlaufs), das ist zugleich die Prüfung der 3.2-Verträglichkeit.

- [ ] **Step 6: Commit**

```bash
git -C /Users/chris/Sites/claude-code-statusline add install.sh tests/install.sh tests/fakes
git -C /Users/chris/Sites/claude-code-statusline commit -m "feat(install): Installer mit Prüfsumme, settings.json und Löschwächter"
```

---

### Task 3: Klick-Handler

**Files:**
- Modify: `install.sh` (neue Funktionen `handler_body` und `write_switch_handler` vor `main`)
- Create: `tests/extract-handler.sh`, `tests/handler.sh`

**Interfaces:**
- Consumes: `die`, `HANDLER_PATH`, `STATE_DIR` aus Task 2.
- Produces: `write_switch_handler CSWAP_BIN JQ_BIN` schreibt `$HANDLER_PATH` ausführbar mit dem Kopf aus „Verträge". `handler_body` gibt den Rumpf aus. Der Handler endet mit 0 nach einem cswap-Lauf (auch bei cswap-Fehler, die Mitteilung trägt ihn) und mit 2, wenn er eine URL abweist.

- [ ] **Step 1: Extraktion des Rumpfs**

`tests/extract-handler.sh`:

```bash
#!/usr/bin/env bash
# Gibt den Rumpf des Klick-Handlers aus, so wie install.sh ihn einbettet. tests/handler.sh
# prüft genau diesen Text, CI lässt shellcheck darüber laufen.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
body=$(sed -n "/<<'SWITCH_HANDLER'\$/,/^SWITCH_HANDLER\$/p" "$root/install.sh" | sed '1d;$d')
[ -n "$body" ] || { echo "extract-handler: kein Handler-Rumpf in install.sh" >&2; exit 1; }
printf '%s\n' "$body"
```

- [ ] **Step 2: Handler-Tests schreiben**

`tests/handler.sh`:

```bash
#!/usr/bin/env bash
# Tests für den Klick-Handler gegen einen cswap-Fake. Der Handler wird aus install.sh
# herausgelöst und mit einem Kopf versehen, wie install.sh ihn schreibt.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
failed=0
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT

mkdir -p "$sb/bin" "$sb/cswap"
for tool in bash cat; do ln -s "$(command -v "$tool")" "$sb/bin/$tool"; done
for tool in uname osascript notify-send; do ln -s "$root/tests/fakes/$tool" "$sb/bin/$tool"; done
{
  printf '#!/usr/bin/env bash\n'
  printf 'CSWAP_BIN=%q\nJQ_BIN=%q\n' "$root/tests/fakes/cswap" "$(command -v jq)"
  bash "$root/tests/extract-handler.sh"
} > "$sb/handler.sh"

cat > "$sb/cswap/list.json" <<'JSON'
{"schemaVersion":1,"accounts":[
  {"number":1,"email":"a@example.com","active":true},
  {"number":2,"email":"b@example.com","active":false}]}
JSON
printf '{"schemaVersion":1,"switched":true,"message":"Switched to Account-2 (b@example.com)"}\n' \
  > "$sb/cswap/switch.json"

# run_handler URL: setzt rc, leert das Log vorher. FAKE_UNAME wählt den Mitteilungsweg.
run_handler() {
  : > "$sb/log"
  env -i PATH="$sb/bin" FAKE_LOG="$sb/log" FAKE_CSWAP_DIR="$sb/cswap" \
    FAKE_UNAME="${FAKE_UNAME:-Darwin}" "$BASH" "$sb/handler.sh" "$1" > "$sb/out" 2>&1
  rc=$?
}

expect() {
  local name=$1 url=$2 want_rc=$3 want_log=$4 deny_log=${5:-}
  run_handler "$url"
  if [ "$rc" != "$want_rc" ]; then
    printf 'FEHLER handler %s: Exit %s, erwartet %s\n' "$name" "$rc" "$want_rc"; cat "$sb/log"; failed=1
  elif [ -n "$want_log" ] && ! grep -qF -- "$want_log" "$sb/log"; then
    printf 'FEHLER handler %s: "%s" fehlt im Log\n' "$name" "$want_log"; cat "$sb/log"; failed=1
  elif [ -n "$deny_log" ] && grep -qF -- "$deny_log" "$sb/log"; then
    printf 'FEHLER handler %s: "%s" darf nicht im Log stehen\n' "$name" "$deny_log"; cat "$sb/log"; failed=1
  else
    printf 'ok     handler (%s)\n' "$name"
  fi
}

expect "gültiges Ziel" 'claude-statusline://switch?to=b%40example.com' 0 'cswap switch 2 --json'
expect "Ziel ohne Rücksicht auf Groß- und Kleinschreibung" \
  'claude-statusline://switch?to=B%40Example.com' 0 'cswap switch 2 --json'
expect "Mitteilung trägt cswaps Meldung" 'claude-statusline://switch?to=b%40example.com' 0 \
  'Switched to Account-2 (b@example.com)'
expect "Rotation" 'claude-statusline://switch' 0 'cswap switch --json' 'cswap list'
expect "unbekanntes Ziel" 'claude-statusline://switch?to=c%40example.com' 2 'is not an account managed' 'cswap switch'
expect "fremdes Schema" 'https://evil.example/switch' 2 '' 'cswap'
expect "angehängter Parameter" 'claude-statusline://switch?to=b%40example.com&x=1' 2 '' 'cswap switch'
expect "anderer Pfad" 'claude-statusline://switch/x' 2 '' 'cswap'
expect "leeres Ziel" 'claude-statusline://switch?to=' 2 '' 'cswap switch'
expect "Zeilenumbruch im Ziel" 'claude-statusline://switch?to=%0Ab%40example.com' 2 '' 'cswap switch'
expect "Nullbyte im Ziel" 'claude-statusline://switch?to=b%40example.com%00' 2 '' 'cswap switch'

cat > "$sb/cswap/list.json" <<'JSON'
{"schemaVersion":1,"accounts":[
  {"number":1,"email":"b@example.com"},{"number":2,"email":"b@example.com"}]}
JSON
expect "mehrdeutige Mail" 'claude-statusline://switch?to=b%40example.com' 2 'more than one' 'cswap switch'

printf '{"schemaVersion":1,"error":{"type":"X","message":"No account found with identifier: 9"}}\n' \
  > "$sb/cswap/switch.json"
printf '1\n' > "$sb/cswap/switch.exit"
expect "cswap-Fehler wird gemeldet" 'claude-statusline://switch' 0 'No account found with identifier: 9'

FAKE_UNAME=Linux expect "Mitteilung unter Linux" 'claude-statusline://switch' 0 'notify-send Claude Statusline'
rm -f "$sb/bin/notify-send"
FAKE_UNAME=Linux run_handler 'claude-statusline://switch'
if grep -q 'No account found' "$sb/out"; then printf 'ok     handler (ohne notify-send auf stderr)\n'
else printf 'FEHLER handler ohne notify-send: keine Meldung auf stderr\n'; failed=1; fi

# cswap rollt einen abgebrochenen Tausch nicht zurück: kein Timeout, kein kill, kein
# Hintergrundlauf im Handler.
if bash "$root/tests/extract-handler.sh" | grep -nE '\btimeout\b|\bkill\b|&[[:space:]]*$'; then
  printf 'FEHLER handler: Timeout, kill oder Hintergrundlauf im Handler\n'; failed=1
else
  printf 'ok     handler (cswap switch wird nie abgebrochen)\n'
fi

exit "$failed"
```

- [ ] **Step 3: Tests laufen lassen, sie müssen scheitern**

Run: `bash /Users/chris/Sites/claude-code-statusline/tests/handler.sh`
Expected: `extract-handler: kein Handler-Rumpf in install.sh` und `FEHLER handler …` für jeden Fall.

- [ ] **Step 4: Handler in `install.sh` einbetten**

Vor `main()` einfügen:

```bash
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
# Nummer, weil cswap bei einer mehrdeutigen Mail interaktiv nachfragen würde. So kann
# auch eine Webseite, die das Schema aufruft, nur zwischen den eigenen Konten wechseln.
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
        && notify-send "$title" "$body" >/dev/null 2>&1 && return 0 ;;
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

# Die Nummer des einen Kontos mit dieser Mail, "none" oder "ambiguous".
account_number() {
  printf '%s' "$2" | "$JQ_BIN" -r --arg mail "$1" '
    [.accounts[]? | select((.email // "" | ascii_downcase) == ($mail | ascii_downcase)) | .number]
    | if length == 1 then .[0] | tostring
      elif length == 0 then "none"
      else "ambiguous" end' 2>/dev/null
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
    result=$("$CSWAP_BIN" switch "$number" --json 2>/dev/null)
  else
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
```

Hinweis zum Fall „leeres Ziel": `?to=` ergibt `target=""` und landet im zweiten `if`, das die URL abweist, statt sie als Rotation zu behandeln.

- [ ] **Step 5: Tests und shellcheck**

```bash
bash /Users/chris/Sites/claude-code-statusline/tests/handler.sh
bash /Users/chris/Sites/claude-code-statusline/tests/extract-handler.sh > /private/tmp/claude-501/switch-handler-body.sh
shellcheck -x /private/tmp/claude-501/switch-handler-body.sh \
  /Users/chris/Sites/claude-code-statusline/install.sh \
  /Users/chris/Sites/claude-code-statusline/tests/handler.sh \
  /Users/chris/Sites/claude-code-statusline/tests/extract-handler.sh
bash /Users/chris/Sites/claude-code-statusline/tests/install.sh
```

Expected: alle `ok`, shellcheck still, `tests/install.sh` weiter grün (der statische Wächter zählt weiterhin genau ein `rm -rf`).

- [ ] **Step 6: Commit**

```bash
git -C /Users/chris/Sites/claude-code-statusline add install.sh tests/extract-handler.sh tests/handler.sh
git -C /Users/chris/Sites/claude-code-statusline commit -m "feat(install): Klick-Handler für claude-statusline://switch"
```

---

### Task 4: Swap-Einrichtung und Registrierung des Handlers

**Files:**
- Modify: `install.sh` (neue Funktionen vor `main`, `main` ruft `setup_swap`)
- Modify: `tests/install.sh` (neue Fälle)

**Interfaces:**
- Consumes: `ask_yes_no`, `config_get`, `config_set`, `safe_remove_tree`, `warn`, `info`, `OS`, `TMP_DIR`, `SWAP_FLAG`, Pfad-Globale (Task 2); `write_switch_handler` (Task 3).
- Produces: `setup_swap`, `remove_switch_handler` (von Task 5 benutzt), Globale `CSWAP_BIN`. Config-Schlüssel `swap=on|off`.

- [ ] **Step 1: Fälle in `tests/install.sh` ergänzen**

Vor dem Block mit den Aufrufen einfügen:

```bash
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
  run_installer --swap
  if has_log 'cswap add'; then fail "gemanagtes Konto erneut aufgenommen"
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
  run_installer
  if has_log 'uv ' || has_log 'cswap ' || has_log 'xdg-mime'; then fail "Update ignoriert swap=off"
  else ok "Update respektiert swap=off"
  fi
  drop_sandbox
}

check_no_swap_removes_handler() {
  new_sandbox
  unmanaged_status
  FAKE_UNAME=Linux run_installer --swap
  FAKE_UNAME=Linux run_installer --no-swap
  if [ -e "$home/.claude/statusline/switch-handler" ]; then fail "--no-swap lässt den Marker stehen"
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
```

Und die Aufrufe vor `check_single_recursive_delete` ergänzen:

```bash
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
```

- [ ] **Step 2: Tests laufen lassen, die neuen müssen scheitern**

Run: `bash /Users/chris/Sites/claude-code-statusline/tests/install.sh`
Expected: die Fälle aus Task 2 `ok`, die neuen `FEHLER install …` (kein `swap=` in der Config, keine uv-Aufrufe).

- [ ] **Step 3: Swap-Einrichtung in `install.sh`**

Vor `main()` einfügen:

```bash
# --- cswap ---
# Bevorzugt uv, sonst pipx. Ein cswap, das auf anderem Weg kam, bleibt unangetastet.
# Setzt CSWAP_BIN auf den absoluten Pfad oder endet mit 1.
CSWAP_BIN=""

find_cswap() {
  if command -v cswap >/dev/null 2>&1; then
    CSWAP_BIN=$(command -v cswap)
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
    rm -f "$MARKER_PATH"
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

note_switch_url_override() {
  local url
  [ -e "$SETTINGS_PATH" ] || return 0
  url=$(jq -r '.env.CLAUDE_STATUSLINE_SWITCH_URL // empty' "$SETTINGS_PATH" 2>/dev/null)
  [ -n "$url" ] || return 0
  info "Note: CLAUDE_STATUSLINE_SWITCH_URL is set in settings.json ($url). Clicks go there, not to the handler, until you remove it."
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
```

In `main` nach `wire_settings` die Zeile `setup_swap` einfügen.

- [ ] **Step 4: Tests und shellcheck**

```bash
bash /Users/chris/Sites/claude-code-statusline/tests/install.sh
shellcheck -x --source-path=/Users/chris/Sites/claude-code-statusline \
  /Users/chris/Sites/claude-code-statusline/install.sh /Users/chris/Sites/claude-code-statusline/tests/install.sh
```

Expected: alle `ok`, Exit 0, shellcheck still.

- [ ] **Step 5: Commit**

```bash
git -C /Users/chris/Sites/claude-code-statusline add install.sh tests/install.sh
git -C /Users/chris/Sites/claude-code-statusline commit -m "feat(install): cswap einrichten und Klick-Handler registrieren"
```

---

### Task 5: Deinstallation und Löschwächter

**Files:**
- Modify: `install.sh` (Funktion `uninstall`, Verzweigung in `main`)
- Modify: `tests/install.sh` (neue Fälle)

**Interfaces:**
- Consumes: `remove_switch_handler` (Task 4), `write_settings`, `current_statusline_command`, `points_to_this_statusline`, `safe_remove_tree` (Task 2).
- Produces: `install.sh --uninstall`.

- [ ] **Step 1: Fälle in `tests/install.sh` ergänzen**

Vor dem Aufrufblock einfügen:

```bash
check_uninstall_removes_only_own_paths() {
  local os
  for os in Darwin Linux; do
    new_sandbox
    unmanaged_status
    mkdir -p "$home/.claude/statusline-accounts" "$home/Applications/Other.app"
    printf 'keep\n' > "$home/.claude/other.txt"
    printf '{}\n' > "$home/.claude/statusline-accounts/x.json"
    printf 'keep\n' > "$home/Applications/Other.app/keep"
    FAKE_UNAME=$os run_installer --swap
    jq '. + {theme: "dark"}' "$home/.claude/settings.json" > "$sb/s.json" && mv "$sb/s.json" "$home/.claude/settings.json"
    if ! FAKE_UNAME=$os run_installer --uninstall; then fail "$os: --uninstall endet mit Fehler"
    elif [ -e "$home/.claude/statusline.sh" ]; then fail "$os: statusline.sh bleibt"
    elif [ -e "$home/.claude/statusline" ]; then fail "$os: Zustandsordner bleibt"
    elif [ -e "$home/Applications/Claude Statusline Switch.app" ]; then fail "$os: App bleibt"
    elif [ -e "$home/.local/share/applications/claude-statusline-switch.desktop" ]; then fail "$os: Desktop-Datei bleibt"
    elif jq -e 'has("statusLine")' "$home/.claude/settings.json" >/dev/null; then fail "$os: statusLine bleibt"
    elif ! jq -e '.theme == "dark"' "$home/.claude/settings.json" >/dev/null; then fail "$os: fremder Schlüssel verloren"
    elif [ ! -f "$home/.claude/other.txt" ] || [ ! -f "$home/.claude/statusline-accounts/x.json" ] \
      || [ ! -f "$home/Applications/Other.app/keep" ]; then fail "$os: fremde Dateien gelöscht"
    elif ! grep -q 'cswap purge' "$sb/out"; then fail "$os: kein Hinweis auf cswap"
    else ok "$os: --uninstall entfernt nur die eigenen Pfade"
    fi
    drop_sandbox
  done
}

check_uninstall_keeps_foreign_statusline() {
  new_sandbox
  mkdir -p "$home/.claude"
  printf '#!/bin/sh\n' > "$home/other.sh"
  printf '{"statusLine":{"type":"command","command":"~/other.sh"}}\n' > "$home/.claude/settings.json"
  cp "$home/.claude/settings.json" "$sb/original.json"
  run_installer --uninstall
  if cmp -s "$home/.claude/settings.json" "$sb/original.json"; then ok "--uninstall lässt fremde Statusline stehen"
  else fail "--uninstall verändert eine fremde Statusline"
  fi
  drop_sandbox
}

# Der App-Pfad ist ein Symlink nach außen: nichts außerhalb darf verschwinden.
check_guard_symlinked_app() {
  new_sandbox
  mkdir -p "$sb/outside" "$home/Applications"
  printf 'keep\n' > "$sb/outside/sentinel"
  ln -s "$sb/outside" "$home/Applications/Claude Statusline Switch.app"
  if FAKE_UNAME=Darwin run_installer --uninstall; then fail "Symlink als App-Pfad wird nicht abgewiesen"
  elif [ ! -f "$sb/outside/sentinel" ]; then fail "Ziel des Symlinks wurde gelöscht"
  elif ! grep -q 'refusing to delete' "$sb/out"; then fail "keine Begründung für die Weigerung"
  else ok "Löschwächter: App-Pfad als Symlink"
  fi
  drop_sandbox
}

# ~/Applications selbst zeigt nach außen: der aufgelöste Pfad liegt dann nicht unter HOME.
check_guard_symlinked_applications_dir() {
  new_sandbox
  mkdir -p "$sb/outside/Claude Statusline Switch.app"
  printf 'keep\n' > "$sb/outside/Claude Statusline Switch.app/sentinel"
  ln -s "$sb/outside" "$home/Applications"
  if FAKE_UNAME=Darwin run_installer --uninstall; then fail "umgelenktes ~/Applications wird nicht abgewiesen"
  elif [ ! -f "$sb/outside/Claude Statusline Switch.app/sentinel" ]; then fail "App außerhalb von HOME gelöscht"
  else ok "Löschwächter: ~/Applications als Symlink"
  fi
  drop_sandbox
}

# HOME zeigt auf einen Ordner mitten in einem fremden Baum. Nach Installation und
# Deinstallation muss der Baum außerhalb von HOME unverändert sein.
check_guard_bent_home() {
  local before after
  new_sandbox
  unmanaged_status
  mkdir -p "$sb/tree/Applications/Claude Statusline Switch.app" "$sb/tree/user"
  printf 'keep\n' > "$sb/tree/Applications/Claude Statusline Switch.app/sentinel"
  printf 'keep\n' > "$sb/tree/sibling"
  before=$(find "$sb/tree" -path "$sb/tree/user" -prune -o -print | sort)
  home="$sb/tree/user"
  FAKE_UNAME=Darwin run_installer --swap
  FAKE_UNAME=Darwin run_installer --uninstall
  after=$(find "$sb/tree" -path "$sb/tree/user" -prune -o -print | sort)
  if [ "$before" != "$after" ]; then fail "umgebogenes HOME: außerhalb von HOME wurde etwas verändert"
  else ok "Löschwächter: umgebogenes HOME"
  fi
  drop_sandbox
}

check_guard_empty_home_uninstall() {
  new_sandbox
  if env -i HOME="" TMPDIR="$sb/tmp" PATH="$sb/bin" FAKE_LOG="$sb/log" FAKE_UNAME=Darwin \
      "$BASH" "$root/install.sh" --yes --uninstall < /dev/null > "$sb/out" 2>&1; then
    fail "--uninstall mit leerem HOME wird angenommen"
  elif [ -s "$sb/log" ]; then fail "--uninstall mit leerem HOME ruft trotzdem Werkzeuge"
  else ok "Löschwächter: leeres HOME bei --uninstall"
  fi
  drop_sandbox
}
```

Aufrufe vor `check_single_recursive_delete` ergänzen:

```bash
check_uninstall_removes_only_own_paths
check_uninstall_keeps_foreign_statusline
check_guard_symlinked_app
check_guard_symlinked_applications_dir
check_guard_bent_home
check_guard_empty_home_uninstall
```

- [ ] **Step 2: Tests laufen lassen, die neuen müssen scheitern**

Run: `bash /Users/chris/Sites/claude-code-statusline/tests/install.sh`
Expected: `FEHLER install Darwin: statusline.sh bleibt` usw., weil `--uninstall` heute noch eine normale Installation ausführt.

- [ ] **Step 3: `uninstall` in `install.sh`**

Vor `main()` einfügen:

```bash
# --- Deinstallation ---
# cswap und seine Konten bleiben: sie gehören einem eigenen Werkzeug, das auch ohne diese
# Statusline nützt. Die Verbrauchshistorie in statusline-accounts bleibt ebenfalls.
uninstall() {
  local current
  remove_switch_handler
  rm -f "$CONFIG_PATH"
  current=$(current_statusline_command)
  if [ "$current" = "$STATUSLINE_COMMAND" ] \
    || { [ -n "$current" ] && points_to_this_statusline "$current"; }; then
    write_settings 'del(.statusLine)'
    info "Removed statusLine from $SETTINGS_PATH."
  fi
  rm -f "$STATUSLINE_PATH"
  rmdir "$STATE_DIR" 2>/dev/null
  info "Removed claude-code-statusline."
  info "cswap and its accounts were kept. To remove them: cswap purge, then uv tool uninstall claude-swap"
  info "Usage history stays in $CLAUDE_DIR/statusline-accounts. Delete that folder if you no longer need it."
}
```

`main` so umbauen, dass `--uninstall` nach der Prüfung von `settings.json` abzweigt, ohne Download und ohne Fragen:

```bash
main() {
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
```

Achtung, Reihenfolge in `uninstall`: `points_to_this_statusline` liest `statusline.sh`, also wird die Datei erst danach gelöscht.

- [ ] **Step 4: Tests und shellcheck**

```bash
bash /Users/chris/Sites/claude-code-statusline/tests/install.sh
shellcheck -x --source-path=/Users/chris/Sites/claude-code-statusline \
  /Users/chris/Sites/claude-code-statusline/install.sh /Users/chris/Sites/claude-code-statusline/tests/install.sh
```

Expected: alle `ok`, Exit 0. `check_single_recursive_delete` zählt weiterhin genau ein `rm -rf`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/chris/Sites/claude-code-statusline add install.sh tests/install.sh
git -C /Users/chris/Sites/claude-code-statusline commit -m "feat(install): Deinstallation mit Löschwächter"
```

---

### Task 6: Release 1.6.0, CI und Dokumentation

**Files:**
- Modify: `statusline.sh:7` (`VERSION="1.6.0"`)
- Modify: `.github/workflows/ci.yml`, `.github/workflows/release.yml`
- Modify: `README.md` (Einleitung, Segmenttabelle, Abschnitt „Click-through link", Install, Requirements, Uninstall, Releasing)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: alle Tests und Dateien aus Task 1–5.
- Produces: Release-Assets `statusline.sh`, `install.sh`, `SHA256SUMS` (mit Zeilen für beide Skripte).

- [ ] **Step 1: Version**

In `statusline.sh` Zeile 7: `VERSION="1.6.0"`.

- [ ] **Step 2: CI**

In `.github/workflows/ci.yml` die shellcheck-Zeile ersetzen und die Testschritte ergänzen:

```yaml
      - name: Lint with shellcheck
        run: shellcheck -x statusline.sh install.sh tests/run.sh tests/race.sh tests/forks.sh tests/snapshots.sh tests/branch.sh tests/freeze.sh tests/fixture-env.sh tests/install.sh tests/handler.sh tests/extract-handler.sh tests/setup/*.sh tests/fakes/*

      - name: Lint the embedded click handler
        run: |
          bash tests/extract-handler.sh > "$RUNNER_TEMP/switch-handler.sh"
          shellcheck "$RUNNER_TEMP/switch-handler.sh"
```

Nach `Run branch test` anhängen:

```yaml
      - name: Run installer test
        run: bash tests/install.sh

      - name: Run click handler test
        run: bash tests/handler.sh
```

- [ ] **Step 3: Release-Workflow**

In `.github/workflows/release.yml` dieselbe shellcheck-Zeile, denselben Schritt `Lint the embedded click handler` und dieselben zwei Testschritte wie in `ci.yml`. Außerdem:

```yaml
      - name: Generate checksums
        run: sha256sum statusline.sh install.sh > SHA256SUMS
```

und im Release-Schritt:

```yaml
          gh release create "$GITHUB_REF_NAME" \
            statusline.sh install.sh SHA256SUMS \
            --title "$GITHUB_REF_NAME" \
            --notes-file RELEASE_NOTES.md
```

- [ ] **Step 4: CHANGELOG**

Über `## 1.5.0 - 2026-10-06` einfügen, Datum ist der Tag, an dem getaggt wird (`date +%F`):

```markdown
## 1.6.0 - YYYY-MM-DD

### Added

- **An installer.** `curl -fsSL https://github.com/Dakaric/claude-code-statusline/releases/latest/download/install.sh | bash` downloads the latest release, checks it against `SHA256SUMS`, puts it at `~/.claude/statusline.sh` and sets `statusLine` in `~/.claude/settings.json`. Every other setting stays as it is, and a backup of the file is written first. Running it again updates. `--uninstall` removes what it added.
- **Switch accounts with a click, no server needed.** If you use more than one Claude account, the installer sets up [claude-swap](https://github.com/realiti4/claude-swap) and a handler for `claude-statusline://` links. Cmd+click on `-> B` switches to B, on `⇄` to the next account, and a notification says where you landed. The link only shows once the handler is installed, and `CLAUDE_STATUSLINE_SWITCH_URL` still takes precedence.
- **Each account snapshot remembers its email address**, so a click on `-> B` can name B as the target. Snapshots from older versions stay valid; until B has been used once with 1.6.0, the click rotates to the next account instead.

### Platforms

- macOS and Linux. The Linux link handler is tested in CI, not yet on a real desktop. Windows is not supported yet.
```

- [ ] **Step 4b: Datum prüfen**

Run: `grep -n '^## 1.6.0 - [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$' /Users/chris/Sites/claude-code-statusline/CHANGELOG.md`
Expected: genau eine Trefferzeile. `YYYY-MM-DD` darf nicht stehen bleiben.

- [ ] **Step 5: README**

Einleitungssatz unter der Codezeile `# claude-code-statusline`: „No daemon, no config file, no dependencies beyond `jq`." ersetzen durch „No daemon, nothing to configure, no dependencies beyond `jq`."

In der Segmenttabelle die Zeile `Account switch` ersetzen:

```markdown
| Account switch | `-> B`, `⇄` | `-> B` when another account is the better place to work; both are links once click-to-switch is set up |
```

Den Unterabschnitt `#### Click-through link to switch accounts` vollständig ersetzen:

```markdown
#### Switch accounts with a click

With more than one account, the end of the limits line can be a link: `-> B` when the status line recommends a switch, otherwise `⇄`. Cmd+click (Ctrl+click in most Linux terminals) switches right away, `-> B` to account B and `⇄` to the next account in line, and a notification tells you where you landed. Your terminal needs to support OSC 8 hyperlinks.

The switching itself is done by [claude-swap](https://github.com/realiti4/claude-swap) (`cswap`). The installer sets it up when you tell it you use more than one account: it installs `cswap` with `uv` or `pipx`, adds the account you are logged into, and registers a handler for `claude-statusline://` links, a small app in `~/Applications` on macOS and a desktop entry on Linux. To add another account, run `/login` in Claude Code without logging out first, then `cswap add`.

The link only appears once that handler is installed, so the line never shows a link that does nothing. The handler only switches between accounts `cswap` already manages and ignores every other address. The Linux handler is tested in CI, not yet on a real desktop.

To send the click somewhere else, for example your own dashboard, set `CLAUDE_STATUSLINE_SWITCH_URL` in `~/.claude/settings.json`. It takes precedence over the handler:

    "env": { "CLAUDE_STATUSLINE_SWITCH_URL": "http://localhost:7373/sphere?swap=1" }

The URL needs a scheme and must not contain whitespace or backslashes, otherwise it is ignored.
```

Den Abschnitt `## Install` bis vor `### Pin to a release` ersetzen:

````markdown
## Install

```bash
curl -fsSL https://github.com/Dakaric/claude-code-statusline/releases/latest/download/install.sh | bash
```

The installer downloads the latest release, checks it against the release's `SHA256SUMS`, puts it at `~/.claude/statusline.sh` and sets the `statusLine` entry in `~/.claude/settings.json`. Every other setting stays as it is, and a backup of the file is written next to it first. If `statusLine` already points at another script, it asks before replacing it.

It also asks whether you use more than one Claude account. Say yes and it sets up [click-to-switch](#switch-accounts-with-a-click). Your answer is kept in `~/.claude/statusline/config`, so an update doesn't ask again.

Run the same command again to update. Options go after `bash -s --`:

```bash
curl -fsSL https://github.com/Dakaric/claude-code-statusline/releases/latest/download/install.sh | bash -s -- --yes
```

| Option | Effect |
|--------|--------|
| `--yes` | answer every question with its default |
| `--swap`, `--no-swap` | turn click-to-switch on or off, whatever you answered before |
| `--version v1.6.0` | install that release instead of the latest |
| `--uninstall` | remove what the installer added |

macOS and Linux are supported. Windows is not supported yet.

### Install by hand

```bash
curl -fsSL https://raw.githubusercontent.com/Dakaric/claude-code-statusline/main/statusline.sh \
  -o ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then wire it up in `~/.claude/settings.json` (create the file if it doesn't exist):

```json
{
  "statusLine": {
    "command": "~/.claude/statusline.sh"
  }
}
```

The next Claude Code session picks it up.
````

Unter `### Pin to a release` `ver=v1.4.0` durch `ver=v1.6.0` ersetzen.

Unter `### Requirements` ergänzen:

```markdown
- `curl` for the installer
- For click-to-switch: `uv` or `pipx` (the installer offers to install `uv` if neither is there), and on Linux `xdg-utils`
```

Den Abschnitt `## Uninstall` ersetzen:

````markdown
## Uninstall

```bash
curl -fsSL https://github.com/Dakaric/claude-code-statusline/releases/latest/download/install.sh | bash -s -- --uninstall
```

This removes the script, the click handler, the stored answers and the `statusLine` entry if it points at this status line. `cswap` and its accounts stay; remove them with `cswap purge` and `uv tool uninstall claude-swap`. The usage history in `~/.claude/statusline-accounts/` stays too, delete the folder if you no longer need it.

Installed by hand? Remove the `statusLine` entry from `~/.claude/settings.json` and delete the script.
````

Unter `## Releasing` im Codeblock `# 2. add a "## x.y.z — YYYY-MM-DD" section to CHANGELOG.md, commit it` ersetzen durch `# 2. add a "## x.y.z - YYYY-MM-DD" section to CHANGELOG.md, commit it`, und im Absatz darunter „publishes a GitHub Release with the script and checksum attached" ersetzen durch „publishes a GitHub Release with the script, the installer and their checksums attached".

- [ ] **Step 6: Gedankenstrich-Wächter über die geänderten Texte**

Run: `git -C /Users/chris/Sites/claude-code-statusline diff main -- README.md CHANGELOG.md install.sh | grep -nE '^\+.*( — | – )'`
Expected: keine Ausgabe.

- [ ] **Step 7: Volle Testsuite wie in CI**

```bash
shellcheck -x --source-path=/Users/chris/Sites/claude-code-statusline \
  /Users/chris/Sites/claude-code-statusline/statusline.sh /Users/chris/Sites/claude-code-statusline/install.sh \
  /Users/chris/Sites/claude-code-statusline/tests/*.sh /Users/chris/Sites/claude-code-statusline/tests/setup/*.sh \
  /Users/chris/Sites/claude-code-statusline/tests/fakes/*
for t in run race forks snapshots branch install handler; do
  bash "/Users/chris/Sites/claude-code-statusline/tests/$t.sh" || echo "ROT: $t"
done
```

Expected: shellcheck still, keine Zeile `ROT:`.

- [ ] **Step 8: Commit und Push des Branches**

```bash
git -C /Users/chris/Sites/claude-code-statusline add statusline.sh .github README.md CHANGELOG.md
git -C /Users/chris/Sites/claude-code-statusline commit -m "release: 1.6.0 mit Installer und Kontowechsel per Klick"
git -C /Users/chris/Sites/claude-code-statusline push -u origin feat/installer
```

Danach muss der CI-Lauf auf GitHub grün sein (`gh run watch` oder `gh pr checks`). Er ist der einzige Lauf unter bash 5 und der einzige unter Linux.

---

### Task 7: Prüfung von Hand auf Christians Mac

Läuft mit Christian, nicht autonom: Schritt 3 tauscht das echte Konto, Schritt 2 ändert seine echte `settings.json`.

**Files:** keine.

- [ ] **Step 1: Lokale Release-Dateien bereitstellen**

```bash
S=/private/tmp/claude-501/statusline-e2e
mkdir -p "$S/bin" "$S/release"
ln -sf /Users/chris/Sites/claude-code-statusline/tests/fakes/curl "$S/bin/curl"
cp /Users/chris/Sites/claude-code-statusline/statusline.sh "$S/release/"
shasum -a 256 "$S/release/statusline.sh" | sed "s|$S/release/||" > "$S/release/SHA256SUMS"
```

- [ ] **Step 2: Installer mit echtem osacompile, PlistBuddy, codesign, lsregister und cswap**

Nur `curl` ist gefälscht:

```bash
PATH="/private/tmp/claude-501/statusline-e2e/bin:$PATH" FAKE_LOG=/private/tmp/claude-501/statusline-e2e/log \
  FAKE_RELEASE_DIR=/private/tmp/claude-501/statusline-e2e/release \
  bash /Users/chris/Sites/claude-code-statusline/install.sh --swap
```

Erwartet: `statusLine.command` steht auf `~/.claude/statusline.sh` (vorher `~/.claude/statusline-command.sh`), eine Sicherung `settings.json.bak-*` liegt daneben, `~/Applications/Claude Statusline Switch.app` existiert, `codesign -v ~/Applications/Claude\ Statusline\ Switch.app` meldet nichts, der Installer weist auf die gesetzte `CLAUDE_STATUSLINE_SWITCH_URL` hin.

- [ ] **Step 3: Klick simulieren**

```bash
open 'claude-statusline://switch?to=cl%40koempf24.de'
```

Erwartet: Mitteilung „Switched to Account-1 (cl@koempf24.de)", `cswap status` zeigt Konto 1. Danach mit `open 'claude-statusline://switch'` zurück rotieren und Konto 2 prüfen. Die App erscheint nicht im Dock.

- [ ] **Step 4: Abweisung prüfen**

```bash
open 'claude-statusline://switch?to=fremd%40example.com'
```

Erwartet: Mitteilung „fremd@example.com is not an account managed by cswap.", `cswap status` unverändert.

- [ ] **Step 5: Link-Variable entfernen, echter Klick in der Statusline**

Entschieden: Der Statusline-Klick soll ohne Jarvis funktionieren. `CLAUDE_STATUSLINE_SWITCH_URL` dauerhaft aus `env` in `~/.claude/settings.json` nehmen (per `jq 'del(.env.CLAUDE_STATUSLINE_SWITCH_URL)'` über eine Temp-Datei, vorher Sicherung). Das Jarvis-Cockpit bleibt über den Konto-Chip in der Sphere erreichbar, nur der Statusline-Link zeigt nicht mehr dorthin.

Dann eine neue Claude-Code-Session starten. Die Limit-Zeile muss jetzt `⇄` bzw. `-> X` als Link auf `claude-statusline://switch…` tragen (Prüfung mit `echo '<payload>' | ~/.claude/statusline.sh | cat -v` oder Hover im Terminal). Cmd+Klick: Mitteilung erscheint, `cswap status` zeigt das andere Konto.

- [ ] **Step 5b: Jarvis-Doku nachziehen**

In `/Users/chris/Sites/jarvis/CLAUDE.md` (Abschnitt „Konto-Swap") steht, die Statusline verlinke per `CLAUDE_STATUSLINE_SWITCH_URL` auf `/sphere?swap=1`. Den Satz ändern: Die Statusline wechselt seit 1.6.0 selbst über ihren Klick-Handler, `/sphere?swap=1` bleibt als Einstieg ins Konto-Overlay bestehen. Die Memory-Notiz `konto-swap-status.md` entsprechend anpassen. Eigener Commit im Jarvis-Repo.

- [ ] **Step 6: Ergebnis festhalten**

Ergebnis in die Daily Note (Skill `daily-notes`). Bei Abweichungen: Fehler im Branch beheben, nicht als Meldung liegen lassen.

---

## Entscheidungen aus dem Grill (2026-10-07)

- **Andere Kopie:** Zeigt `statusLine` auf eine andere Kopie dieser Statusline, fragt der Installer mit Vorgabe Ja, ob er auf die verwaltete Kopie umhängt. Die alte Datei bleibt unangetastet, die Ausgabe nennt ihren Pfad. Umgesetzt in `wire_settings` (Task 2), Begriffe in `CONTEXT.md`.
- **Christians Link:** Der Statusline-Klick läuft künftig über den Handler, ohne Jarvis. `CLAUDE_STATUSLINE_SWITCH_URL` wird in Task 7 entfernt, die Jarvis-Doku nachgezogen.
- **Sprache:** Alle Ausgaben englisch, keine Locale-Weiche. Steht in der Spec.
- **Gleiche Mail in zwei Organisationen:** wird abgewiesen, Erweiterung über `&org=` steht unter „Nicht Teil davon" in der Spec.
