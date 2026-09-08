# Statusline für mehrere Claude-Accounts

Stand 2026-09-08. Entwurf, noch nicht gebaut.

## Warum

Das Daily-Pacing-Delta in `statusline.sh` rechnet gegen ein Budget von 100 Prozent
über sieben Tage. Wer zwei Abos parallel nutzt und zwischen ihnen wechselt, hat ein
anderes Budget: N mal 100 Prozent, verteilt auf N Wochenfenster, die zu
verschiedenen Zeitpunkten zurückgesetzt werden. Das Delta zeigt dann zu früh Alarm,
weil es den zweiten Vorrat nicht kennt.

Dazu kommt eine Frage, die das Delta gar nicht beantworten kann: In welchem Account
soll ich gerade arbeiten? Ungenutztes Budget verfällt beim Zurücksetzen. Ein Account
mit 20 Prozent Rest und einem Reset morgen ist dringlicher als einer mit 60 Prozent
Rest und fünf Tagen Zeit.

## Was sich ändert

Die Mehr-Account-Logik schaltet sich erst mit dem zweiten Account ein. Bei genau
einem bekannten Account zeigt die Statusline dieselben Werte wie heute, Delta
eingeschlossen, und niemand, der das Repo klont, sieht etwas von Runway, Pfeil oder
Account-Buchstaben.

Der Umbau auf vier Zeilen und das neue Worktree-Segment gelten dagegen für alle,
unabhängig von der Zahl der Accounts. Sie ordnen nur um, was schon da ist.

Ab zwei Accounts ersetzt ein Runway das Delta, die Limit-Werte erscheinen pro
Account, und ein Wechselsignal zeigt an, wo Budget verfällt.

## Datenhaltung

Die Identität des aktiven Accounts steht in `~/.claude.json` unter
`oauthAccount.accountUuid`. Der Statusline-Payload liefert sie nicht, wohl aber die
Limits, also werden beide Quellen zusammengeführt.

Pro Account entsteht eine Datei `~/.claude/statusline-accounts/<accountUuid>.json`
mit den `rate_limits` aus dem Payload, dem Zeitpunkt der Aufnahme und dem Zeitpunkt
des ersten Auftretens. N ist die Zahl dieser Dateien. Sie entstehen von selbst beim
ersten Prompt in einem Account; es gibt keine Konfiguration zu pflegen. Wer sich
versehentlich in einen fremden Account einloggt, löscht die Datei wieder.

Angezeigt werden nur die Label A, B und C, vergeben nach dem Zeitpunkt des ersten
Auftretens. Die UUID bleibt Dateiname und erscheint nie auf dem Bildschirm.

Für das Verbrauchstempo kommt je Account eine Zeitreihe dazu, angehängt nur bei
geändertem Wert und höchstens alle fünf Minuten, damit die Datei nicht mit jedem
Turn mitwächst. Einträge älter als 48 Stunden werden beim Schreiben entfernt.

## Rechnung

Ein `resets_at` in der Vergangenheit bedeutet null Verbrauch, nicht "unbekannt". Das
Fenster ist durch, das nächste beginnt erst mit dem nächsten Prompt in diesem
Account. Damit sind die Werte des inaktiven Accounts nicht geschätzt, sondern
richtig: Wer in Account A arbeitet, kann den Stand von B nicht verändert haben.
Ungenau wird es nur bei paralleler Arbeit auf einem zweiten Gerät.

Das Tempo ist der Verbrauchszuwachs über alle Accounts in den letzten 24 Stunden,
gelesen aus den Zeitreihen. Die Nachfüllrate ist `N * 100 / 7` Punkte pro Tag, bei
zwei Accounts 28,6.

Liegt das Tempo unter der Nachfüllrate, läuft das Budget nie leer, und der Runway
zeigt `oo`. Darüber gilt `Restbudget / (Tempo - Nachfüllrate)`, wobei das
Restbudget die Summe von `100 - used` über alle Accounts ist. Diese Näherung glättet
die diskreten Resets zu einem gleichmäßigen Zufluss und liegt um Stunden daneben,
wenn ein Reset kurz bevorsteht. Für eine Zahl, die zum Wechseln bewegen soll, reicht
das.

Das Wechselsignal hat zwei Auslöser. Der erste ist Erschöpfung: Der aktive Account
ist am Anschlag, 5h oder Woche bei 95 Prozent oder mehr, und woanders ist Kapazität.
Der zweite ist Verfall: Die Verfallsrate eines Accounts ist `Rest / Tage bis zum
Reset`, also die Punkte pro Tag, die dort verbraucht werden müssten, damit nichts
verfällt; hat ein inaktiver Account die höhere, lohnt der Wechsel, obwohl hier noch
Luft ist.

Beide Auslöser stehen unter derselben Bedingung: Im Zielaccount muss 5h-Kapazität
frei sein. Ein voller 5h-Zähler macht den Wechsel wertlos, egal wie viel Wochenbudget
dort verfällt.

Der Verfallsauslöser allein würde den häufigsten Fall verpassen. Ein frisch
zurückgesetzter Account hat sieben Tage Zeit für 100 Punkte, also eine
Verfallsrate von 14,3, und liegt damit fast immer unter der eines Accounts, der bald
resettet. Ohne den Erschöpfungsauslöser bliebe der Pfeil aus, während du im leeren
Account sitzt.

Das 5h-Fenster läuft nicht im Leerlauf mit. Es startet mit dem ersten Prompt in einem
Account und endet fünf Stunden später. Ein Account, der länger als fünf Stunden
unberührt war, steht beim Wechsel mit vollen fünf Stunden bereit.

## Anzeige

Vier Zeilen statt der heutigen zwei.

```
~/Sites/claude-code-statusline  main  wt fix/rate-limits
Opus 5 (1M)  effort xhigh  [INSERT]
ctxQ 92 . ctx ████░░░░░░ 45% (89k/200k) . cache 42m/1h
5h A 87% (0h12) B frei . wk A 24% (5.1d) B 78% (0.9d) . rw 1.8d . -> B
```

Zeile eins nennt den Ort: Pfad, Branch und, falls vorhanden, den Worktree. Zeile zwei
das Werkzeug: Modell, Effort und Vim-Modus. Zeile drei alles zur laufenden Session.
Zeile vier die Limits.

In der Limit-Zeile steht hinter jedem Wochenwert die Restlaufzeit seines Fensters,
damit sich das Wechselsignal nachrechnen lässt. Im Beispiel hat A 76 Punkte auf 5,1
Tage, also 15 pro Tag, und B 22 Punkte auf 0,9 Tage, also 24 pro Tag. Deshalb der
Pfeil zu B.

Der aktive Account wird hell gesetzt, der inaktive gedimmt. `wk-opus` bleibt die
Anzeige des aktiven Accounts und wird nicht pro Account aufgeteilt.

Bei N gleich eins entfallen die Account-Buchstaben, der Runway und der Pfeil; an
seiner Stelle steht das heutige Delta. Die Limit-Zeile liest sich dann wie die
zweite Zeile von heute, ohne deren Kontext-Segmente.

## Quellen im Payload

Der Statusline-Payload liefert mehr, als das Skript heute nutzt. `.effort.level` gibt
die Stufe der laufenden Sitzung inklusive einer Umschaltung über `/effort`, und
`.worktree.name` nennt den Worktree, ohne dass git dafür befragt werden muss.

Nur die Account-Identität fehlt dort. Sie kommt weiterhin aus `~/.claude.json`.

Laut Dokumentation entfernt Claude Code ein Limit-Fenster aus dem Payload, sobald
dessen `resets_at` verstrichen ist. Das stützt die Regel oben: Ein Fenster, das nicht
mehr auftaucht oder dessen Zeitpunkt vorbei ist, steht auf null.

Das dokumentierte Schema kennt `five_hour`, `seven_day` und `spend_limit`, aber kein
`weekly_opus`. Das Skript fragt es heute trotzdem ab, was nichts kostet und einen
möglichen älteren oder neueren Namen abfängt. Es bleibt als Anzeige des aktiven
Accounts erhalten. Ein Snapshot-Format dafür zu bauen, wäre Code für ein Feld, das
nie ankommt und sich deshalb auch nicht prüfen ließe.

## Prüfung

`statusline.sh` hat heute keine Tests, und diese Logik rechnet mit Zeit. Dazu kommt
ein Harness, das JSON-Fixtures in das Skript pipet und die erwartete Ausgabe
vergleicht, mit gestellter Uhrzeit und gestellten Snapshot-Dateien. Ohne das lässt
sich die Verfallslogik nur durch Warten prüfen.

Abzudecken sind mindestens: ein Account (Delta statt Runway, keine Buchstaben), zwei
Accounts mit versetzten Fenstern, ein Snapshot mit abgelaufenem `resets_at`, Tempo
unter und über der Nachfüllrate, und ein Wechselsignal, das wegen vollem 5h-Zähler
unterdrückt wird.
