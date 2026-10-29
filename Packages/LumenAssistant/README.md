# LumenAssistant — Lumen Hub hands-free assistant (listen → understand → act)

Research: Lumen for Frigate `docs/research/2026-10-29-voice-assistant-visual-verification.md`
and `2026-10-29-audio-transcription-speaker-id.md`. Approved pilot: indoor camera
microphones, local only, with the safety tiers below.

## Pipeline

```
go2rtc fMP4 (Frigate) ─► FMP4AudioDemuxer ─► AACDecoder (AVAudioConverter) ─► 16 kHz mono
  ─► UtteranceStream: Silero streaming VAD (FluidAudio) + Endpointer (0.6 s end silence)
  ─► AssistantEngine
       gate: assistant on + camera opted in + LumenHearing gate (indoor, consent, no staff) + Pro
       ASR: one shared LumenHearing engine (Parakeet v3 / Apple SpeechTranscriber)
       wake: TranscriptWakeSpotter ("Lumen" FR/EN, fuzzy)  ·  or natural mode
       understand: RuleParser (FR+EN) → LLM fallback (llama-server, json_schema) only if unsure
       policy: PolicyEngine (tiers, voice, presence, TV playing) + RateLimiter (+ duplicate drop)
       act: HomeAssistantClient (REST) · dry run · undo window · hash-chained AuditLog
       reply: AssistantNotifier (Hub push) · SpeechOutput (AVSpeechSynthesizer) · ActionVerifier (no-op seam)
```

Nothing heard is stored unless it is accepted as a command: the audio and the
text of every other utterance die inside `AssistantEngine.handle`. Accepted
commands keep only their normalized text in the audit log; refusals keep the
action and the reason, never the words. This is separate from LumenHearing's
opt-in transcript retention.

## Safety (code, not prompt)

| Tier | Devices | Rule from a camera mic |
|---|---|---|
| T0 | lights, plugs, fans, TV/media, shutters, scenes, status questions | run (any voice; wake phrase) |
| T1 | thermostat, camera privacy | run only for a confident **adult** voice match |
| T2 | locks, alarm, garage | **never run**: pending proposal + push; Face ID receipt on iPhone (HMAC, single-use, 30 s monotonic) |

- Voice ID only lowers rights (`unknown`/`maybe`/not identified → T0). Children: T0 only.
- Natural mode (no wake word): T0 only, known voice **and** a person seen in that
  room **and** no TV/speaker playing there **and** "addressed to the house" ≥ 0.85.
- Rate limits: T0 12/min, T1 6/10 min, T2 3/10 min; the same action within 4 s is dropped
  (two cameras hear one sentence).
- Dry run (default on): every command is logged and previewed, nothing is sent.
- Undo: "non, annule" / "cancel" within 10 s from the same room restores prior states
  (no undo for scenes or T2).
- Outdoor/doorbell audio never reaches the parser or the LLM (LumenHearing's outdoor lock).
  The LLM gets the sentence quoted as data, sees only exposed device ids (schema enum), and
  its answer is re-checked through the same verb × kind table and policy.

Tool model uses LorisAI's vocabulary (`ToolEffect` read-only / write / destructive,
proposal + receipt) so it can move onto `AIToolGate` once LorisAI qualifies (its
2026-10-23 eval is NO-GO, so it is not imported).

## Decisions

- **Home Assistant client written here**, not LorisIoT `IoTHomeAssistant`
  (catalogue status source-observed, unqualified): its `HAEntityState` drops
  `device_class`, `current_position`, `temperature`; and linking LorisIoT adds a path
  dependency on LorisFoundation that would collide with the Bridge's remote
  LorisFoundation package. Same rules kept: no bearer over public cleartext, no
  redirects, 4 MB cap, strict entity ids. Revisit when LorisIoT qualifies.
- **Areas** come from `POST /api/template` (HA admin only). A non-admin token still
  works: rooms are then set by the owner in the Hub.
- **WebSocket** (live states) not used yet: states are read just before acting.
- **Wake word** is read from the transcript. `WakePhraseSpotter` is the seam for a
  trained acoustic "Lumen" model (Porcupine lost its free tier; openWakeWord models are
  non-commercial). Measured Parakeet spellings of French "Lumen": "Lumaine", "L'humaine".
- **ASR** is per-utterance on endpointed speech (not token streaming): Parakeet takes
  ≈ 45–55 ms for a 3 s utterance on the M5 Pro, so chunked streaming is not needed yet.
- **Camera audio**: go2rtc's fMP4 carries AAC. G.711/Opus cameras need a go2rtc source
  that outputs AAC (`ffmpeg:<cam>#audio=aac` in Frigate's go2rtc config). The
  Hub currently opens the same video+audio stream the HomeKit module uses.

## Tests

`swift test` — parser matrix (78 FR/EN), held-out set written blind by a separate
agent (`Fixtures/heldout-commands.json`, 90 items), wake, policy, rate limits, audit
chain, proposals, HA REST against a local mock server, engine (modes, undo, dry run, T2).

Real models (Parakeet v3 + Silero, already downloaded):
`LUMEN_ASSISTANT_MODELS_DIR=<dir with Models/> swift test` — `say` audio → fMP4 →
demux → AAC decode → VAD → ASR → parse → policy → mock HA, plus real-time latency.
Live LLM: `LUMEN_ASSISTANT_LLM_URL=http://<host>:8012 swift test --filter LLMLive`
(skipped when llama-server is down). Fixtures: `Scripts/make-command-fixtures.sh`.
