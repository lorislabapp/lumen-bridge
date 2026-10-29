#!/bin/zsh
# Rebuilds the synthetic voice fixtures used by the diarization tests.
# Two macOS voices: "Thomas" (French) and "Samantha" (US English).
# Output: two-speakers.m4a (+ .json ground truth) and 3 enrolment clips per voice.
# AAC 32 kb/s mono, like a camera stream. Needs macOS `say`, `afconvert`, python3.
set -euo pipefail
here=${0:A:h}
out=${1:-$here/../Tests/LumenHearingTests/Fixtures}
work=$(mktemp -d "${TMPDIR:-/tmp}/voicefx.XXXXXX")
trap 'rm -rf "$work"' EXIT

fr=(
  "Bonjour, je suis rentré plus tôt ce soir, le colis est posé dans l'entrée."
  "Tu peux sortir les poubelles avant demain matin, s'il te plaît ?"
  "Je pars chercher les enfants à l'école, je reviens dans vingt minutes."
  "N'oublie pas d'arroser les plantes du balcon pendant le week-end."
  "Le dîner sera prêt vers huit heures, on mange des pâtes au saumon."
)
en=(
  "Hi, I left the keys on the kitchen table next to the blue bag."
  "The delivery should arrive this afternoon, please keep the gate open."
  "I will call the plumber tomorrow about the leak under the sink."
  "Could you feed the cat before you go to bed tonight?"
  "We are out of milk and bread, I will stop at the shop on the way home."
)

render() { # voice text file
  say -v "$1" -o "$work/$3.aiff" "$2"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$work/$3.aiff" "$work/$3.wav"
}

for i in 1 2 3 4 5; do
  render Thomas "${fr[$i]}" "fr$i"
  render Samantha "${en[$i]}" "en$i"
done

# Conversation: FR, EN, FR, EN with 0.6 s pauses. Ground truth in seconds.
python3 -I - "$work" <<'PY'
import json, sys, wave
work = sys.argv[1]
order = [("fr1", "fr"), ("en1", "en"), ("fr2", "fr"), ("en2", "en")]
rate, gap = 16000, int(0.6 * 16000)
frames, turns, t = b"", [], 0.0
for name, who in order:
    with wave.open(f"{work}/{name}.wav") as w:
        data = w.readframes(w.getnframes())
    if frames:
        frames += b"\x00\x00" * gap
        t += gap / rate
    dur = len(data) / 2 / rate
    turns.append({"speaker": who, "start": round(t, 3), "end": round(t + dur, 3)})
    frames += data
    t += dur
with wave.open(f"{work}/two.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(frames)
json.dump({"voices": {"fr": "Thomas (fr_FR)", "en": "Samantha (en_US)"}, "turns": turns},
          open(f"{work}/two.json", "w"), indent=1)
PY

aac() { afconvert -f m4af -d aac -b 32000 "$work/$1.wav" "$out/$2.m4a"; }
aac two two-speakers
cp "$work/two.json" "$out/two-speakers.json"
# Enrolment clips: sentences 3-5, never in the conversation (held out).
for i in 1 2 3; do j=$((i + 2)); aac "fr$j" "voice-fr-$i"; aac "en$j" "voice-en-$i"; done
echo "fixtures written to $out"
