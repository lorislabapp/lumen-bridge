#!/bin/zsh
# Rebuilds the spoken-command fixtures for the end-to-end tests (macOS `say`).
# French: Thomas (fr_FR). English: Samantha (en_US). AAC 32 kb/s, 16 kHz mono,
# like a camera stream. Pauses are real silence so the VAD has to endpoint.
set -euo pipefail
here=${0:A:h}
out=${1:-$here/../Tests/LumenAssistantTests/Fixtures}
work=$(mktemp -d "${TMPDIR:-/tmp}/cmdfx.XXXXXX")
trap 'rm -rf "$work"' EXIT

render() { # voice "text" name
  say -v "$1" -o "$work/$3.aiff" "$2"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$work/$3.aiff" "$work/$3.wav"
  afconvert -f m4af -d aac -b 32000 "$work/$3.wav" "$out/$3.m4a"
}

# [[slnc 1500]] inserts 1.5 s of silence inside one file.
render Thomas "Lumen, allume la lumière du salon." cmd-fr-on
render Samantha "Lumen, turn off the kitchen light." cmd-en-off
render Thomas "Lumen, ferme les volets du salon. [[slnc 1500]] Non, annule." cmd-fr-close-undo
render Samantha "Lumen, open the living room shutters." cmd-en-open
render Thomas "Il faudrait allumer la lumière un jour. [[slnc 1200]] Le film commence à huit heures." chatter-fr
render Thomas "Lumen, déverrouille la porte d'entrée." cmd-fr-unlock
ls -la "$out"
