# claude-code-statusline

Eine Statusline für Claude Code, ausgeliefert als einzelnes bash-Skript, dazu ein Installer, der sie einrichtet und auf Wunsch den Kontowechsel per Klick.

## Language

**Verwaltete Kopie**:
Die Statusline unter `~/.claude/statusline.sh`, die der Installer anlegt und bei jedem Lauf aktualisiert.
_Avoid_: installierte Version, Hauptkopie

**Andere Kopie**:
Jede Datei außerhalb der verwalteten Kopie, die diese Statusline enthält, etwa eine Handinstallation oder eine angepasste Fassung. Der Installer hängt auf Nachfrage von ihr um, verändert oder löscht sie aber nie.
_Avoid_: alte Version, Fremdskript

**Fremde Statusline**:
Ein Skript in `statusLine`, das nicht diese Statusline ist. Wird nur nach ausdrücklichem Ja ersetzt.

## Relationships

- `statusLine` in `settings.json` zeigt auf genau eine Datei: die **verwaltete Kopie**, eine **andere Kopie** oder eine **fremde Statusline**.

## Example dialogue

> **Dev:** "Der Nutzer hat `~/bin/sl.sh` mit eigenen Farben eingehängt. Überschreibt das Update seine Farben?"
> **Domain expert:** "Nein. Das ist eine andere Kopie. Der Installer fragt, ob er auf die verwaltete Kopie umhängen soll, und `~/bin/sl.sh` bleibt unverändert liegen."
