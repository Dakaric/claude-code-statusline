#!/usr/bin/env bash
# Wie unbekanntes-fenster, nur ohne five_hour im Payload: der Stand hat keinen Besitzer.
# Das 5h-Fenster des Logins darf dann nicht neben einem fremden Wochenwert stehen.
set -u
bash "$(dirname "$0")/unbekanntes-fenster.sh" "$1"
