# Installer und Kontowechsel per Klick

Stand: 2026-10-06, Design mit Christian abgestimmt.

## Ziel

Wer mehrere Claude-Konten nutzt, soll aus der Statusline heraus per Cmd+Klick das Konto
wechseln können, ohne Jarvis und ohne vorher zu suchen, wie das geht. Dazu braucht die
Statusline zum ersten Mal einen Installer, der sie installiert und aktualisiert und dabei
das Wechsel-Werkzeug `claude-swap` (CLI `cswap`) mitbringt und einrichtet. Wer nur ein
Konto hat, wählt das ab.

Version 1 unterstützt macOS und Linux. Windows ist ausdrücklich noch nicht unterstützt und
wird in README und Release Notes so benannt; ob das Skript dort unter Git Bash läuft, ist
ungeprüft.

## Ausgangslage

- Installiert wird heute per `curl` auf `statusline.sh` plus Handarbeit in
  `~/.claude/settings.json`. Ein Update ist derselbe Weg.
- Das Release lädt `statusline.sh` und `SHA256SUMS` als Assets hoch
  (`.github/workflows/release.yml`).
- Seit 1.5.0 kann die Limit-Zeile mit `CLAUDE_STATUSLINE_SWITCH_URL` einen OSC-8-Link tragen:
  das Wechselsignal `-> B` oder `⇄`. Ohne die Variable gibt es keinen Link.
- Ein Klick im Terminal übergibt nur eine URL an das Betriebssystem. Ausführen kann er nichts.

## Entscheidungen

- **Ein eigenes URL-Schema `claude-statusline://switch`** mit einem kleinen Handler je
  Betriebssystem. Nur so wird aus einem Klick eine Aktion, ohne Browser und ohne Server.
- **Der Klick folgt dem Wechselsignal.** `-> B` wechselt genau zu Konto B, `⇄` ohne Signal zum
  nächsten Konto in der Rotation von cswap.
- **Der Klick tauscht sofort**, ohne Rückfrage. Ein Cmd+Klick ist Absicht, eine Mitteilung
  meldet danach, was passiert ist.
- **Der Link erscheint nur mit installiertem Handler.** Die Statusline prüft dafür eine
  Marker-Datei (`stat`, kein zusätzlicher Prozess). Ein toter Link wird so nie angezeigt.
- **`CLAUDE_STATUSLINE_SWITCH_URL` gewinnt weiterhin.** Wer ein eigenes Ziel hat (etwa ein
  Cockpit), behält es.
- **Release bleibt schlank.** `install.sh` erzeugt Handler-Skript, App und Desktop-Datei
  selbst aus eingebetteten Vorlagen. Neu im Release ist nur `install.sh`.

## Teil 1: Installer `install.sh`

Aufruf:

```bash
curl -fsSL https://github.com/Dakaric/claude-code-statusline/releases/latest/download/install.sh | bash
```

Ein erneuter Lauf ist das Update. Ablauf:

1. **Voraussetzungen:** `bash` und `jq` prüfen; fehlt `jq`, mit dem passenden Paketbefehl
   (`brew`, `apt`, `dnf`, `pacman`) darauf hinweisen und abbrechen. `curl` ist durch den
   Aufruf gegeben.
2. **Skript holen:** `statusline.sh` und `SHA256SUMS` des neuesten Releases in ein
   `mktemp -d` laden, Prüfsumme verifizieren (`shasum -a 256` bzw. `sha256sum`), erst dann nach
   `~/.claude/statusline.sh` verschieben und ausführbar machen. Scheitert die Prüfung, bleibt die
   vorhandene Datei unangetastet.
3. **Einhängen:** in `~/.claude/settings.json` den Schlüssel `statusLine` setzen, sofern er
   fehlt oder schon auf diese Statusline zeigt. Zeigt er auf ein anderes Skript, fragen statt
   überschreiben. Geschrieben wird per `jq` in eine Temp-Datei und `mv`; alle übrigen Schlüssel
   bleiben erhalten, ungültiges JSON bricht ab, ohne die Datei anzufassen. Vorher eine Kopie
   `settings.json.bak-<datum>` anlegen.
4. **Antworten merken** in `~/.claude/statusline/config` (eine `schluessel=wert`-Zeile je
   Einstellung, etwa `swap=on|off`). Ein Update fragt nichts, was dort schon steht.
5. **Swap-Einrichtung** (Teil 2), außer bei `swap=off`.

Optionen: `--yes` (alle Fragen mit der Vorgabe beantworten), `--swap` (Swap einschalten, auch
nach früherem Nein), `--no-swap` (abwählen), `--uninstall` (Teil 4), `--version <tag>`
(bestimmtes Release statt des neuesten). Ohne Terminal (`curl | bash` ohne TTY auf stdin) liest
der Installer Antworten von `/dev/tty`; gibt es keins, gilt `--yes` mit `swap=off`.

## Teil 2: Swap-Einrichtung

1. **Frage:** „Nutzt du mehr als ein Claude-Konto?“ Nein speichert `swap=off`, fertig.
2. **cswap installieren oder aktualisieren:** bevorzugt `uv tool install claude-swap`
   (bzw. `uv tool upgrade claude-swap`), sonst `pipx`. Fehlen beide, anbieten, uv über den
   offiziellen Installer von astral nachzuziehen, nur nach ausdrücklichem Ja.
3. **Aktuelles Konto aufnehmen:** `cswap add`, wenn das angemeldete Konto noch nicht
   gemanagt ist (`cswap status`). Ist Claude Code nicht angemeldet, nur die Anleitung zeigen.
4. **Klick-Handler installieren** (Teil 3) und Marker-Datei anlegen.
5. **Anleitung im Terminal**, kurz und konkret: weiteres Konto per `/login` in Claude Code
   (vorher kein `/logout`), danach `cswap add`; wechseln per Cmd+Klick auf `⇄` oder `-> B`.

## Teil 3: Klick-Handler

Gemeinsames Handler-Skript `~/.claude/statusline/switch-handler.sh`, aufgerufen mit der URL:

- Erlaubt ist nur `claude-statusline://switch` mit optionalem `?to=<mail>`. Alles andere wird
  abgewiesen.
- Ein Ziel wird gegen `cswap list --json` geprüft; nur eine dort gemanagte Mail ist gültig.
  Damit kann auch eine Webseite, die das Schema aufruft, nur zwischen den eigenen Konten
  wechseln; Browser fragen bei fremden Schemata ohnehin vorher.
- Mit Ziel `cswap switch <mail> --json`, ohne Ziel `cswap switch --json` (Rotation).
- Ergebnis als Mitteilung: macOS per `osascript -e 'display notification …'`, Linux per
  `notify-send`, sonst Ausgabe auf stderr.
- Der Handler bricht einen laufenden `cswap switch` nie ab (kein Timeout mit Kill), weil cswap
  einen abgebrochenen Tausch nicht zurückrollt.

Registrierung:

- **macOS:** App `~/Applications/Claude Statusline Switch.app`, gebaut mit `osacompile` aus
  einem AppleScript mit `on open location`, das das Handler-Skript aufruft. `CFBundleURLTypes`
  per `PlistBuddy` in die `Info.plist`, Registrierung über `lsregister -f`. Kein Dock-Symbol
  (`LSUIElement`).
- **Linux:** `~/.local/share/applications/claude-statusline-switch.desktop` mit
  `MimeType=x-scheme-handler/claude-statusline;` und `Exec=… %u`, dann
  `xdg-mime default claude-statusline-switch.desktop x-scheme-handler/claude-statusline` und
  `update-desktop-database`, wenn vorhanden.

## Teil 4: Deinstallation

`install.sh --uninstall` entfernt Handler, App bzw. Desktop-Datei, Marker und die
`statusLine`-Zeile aus `settings.json` (nur wenn sie auf diese Statusline zeigt) und
`statusline.sh`. cswap und dessen Konten bleiben, mit Hinweis auf `uv tool uninstall
claude-swap` und `cswap purge`.

## Teil 5: Statusline

- **Mail je Konto:** Der Account-Snapshot speichert zusätzlich `email` aus
  `~/.claude.json` (`oauthAccount.emailAddress`), wenn sie zum aktiven `accountUuid` passt.
  Ältere Snapshots ohne Mail bleiben gültig; dann bekommt `-> B` keinen Ziel-Parameter und
  verlinkt auf die Rotation.
- **Link-Ziel**, in dieser Reihenfolge: `CLAUDE_STATUSLINE_SWITCH_URL`, wenn gesetzt; sonst
  `claude-statusline://switch?to=<mail>` bzw. `claude-statusline://switch`, wenn die Marker-Datei
  `~/.claude/statusline/switch-handler` existiert; sonst kein Link.
- Die Mail wird für die URL kodiert (`@` als `%40`, nur erlaubte Zeichen), damit sie die
  vorhandene URL-Prüfung (kein Leerraum, kein Steuerzeichen, kein Backslash) besteht.
- Ohne Marker und ohne Variable bleibt die Ausgabe Byte für Byte wie in 1.5.0.

## Löschen nur innerhalb einer Positivliste

`install.sh` löscht rekursiv nur zwei Dinge: das eigene `mktemp -d` desselben Laufs und genau
den Pfad `~/Applications/Claude Statusline Switch.app` (beim Neubau und beim Deinstallieren).
Vor jedem rekursiven Löschen wird der aufgelöste Pfad gegen diese Liste geprüft; liegt er
außerhalb, bricht der Installer ab. Eine Sperrliste (`/`, `$HOME`) ist kein Ersatz dafür.
Einzelne Dateien (Marker, Desktop-Datei, Handler-Skript) werden mit `rm -f` und festem Pfad
entfernt. Ein Wächtertest prüft das mit umgebogenem `HOME`, leerem `HOME` und einem
App-Pfad, der per Symlink nach außen zeigt.

## Release

- `install.sh` wird Release-Asset und steht in `SHA256SUMS`.
- `shellcheck` und die CI-Zeilen in `ci.yml` und `release.yml` decken `install.sh` mit ab.
- Version 1.6.0. Release Notes und README nennen: macOS und Linux unterstützt, Linux-Handler
  nur in CI-Sandbox und nicht auf einem echten Desktop getestet, Windows noch nicht unterstützt.

## Tests

- **Statusline:** neue Fixtures für Link mit Ziel, Link auf die Rotation, Marker fehlt (kein
  Link), Variable gewinnt gegen Marker, Snapshot ohne Mail.
- **Installer** (`tests/install.sh`): Lauf in einer Sandbox mit eigenem `HOME`, gefaktem
  `curl` (liefert lokale Release-Dateien), gefaktem `uv`/`cswap`/`osacompile`/`xdg-mime`.
  Geprüft werden: `settings.json` behält fremde Schlüssel, falsche Prüfsumme lässt alte Datei
  stehen, ungültiges JSON bricht ab, `swap=off` wird beim Update respektiert, `--uninstall`
  entfernt nur die eigenen Pfade, der Löschwächter greift.
- **Handler** (`tests/handler.sh`): gegen ein Fake-`cswap`; gültiges Ziel, unbekanntes Ziel,
  fremdes Schema, Rotation.
- **Von Hand:** App-Registrierung und Klick auf Christians Mac. Linux nur über die CI-Sandbox.

## Nicht Teil davon

- Windows (`install.ps1`, Registry-Handler): eigener Schritt.
- Automatisches Wechseln (`cswap auto`).
- Ein Self-Update aus der Statusline heraus.
