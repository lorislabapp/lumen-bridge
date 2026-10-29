# LumenHearing — Lumen Hub speech transcription (Phase 1) and voices (Phase 2)

On-device transcription of Frigate `speech` events on the always-on Mac.
Research and legal basis: Lumen for Frigate `docs/research/2026-10-29-audio-transcription-speaker-id.md`.

## Pipeline

MQTT `end` (speech) + REST poll `/api/events?label=speech` → safeguards →
clip.mp4 → AVAssetReader 16 kHz mono Float32 → VAD (Silero, energy fallback) →
one shared engine on a serial queue (Parakeet TDT v3 via FluidAudio, or Apple
SpeechTranscriber on macOS 26+) → `VoiceAttributor` (Phase 2, below) →
SQLite + FTS5 → keyword match → push "Keyword heard" (camera only).

## Non-negotiable defaults

- Off by default; each camera needs an explicit consent (versioned) and an
  "indoor" placement. Outdoor / street cameras are locked off.
- "Staff present" stops everything; events seen meanwhile are dropped for good.
- Events older than a camera's consent are refused; no history backfill.
- No emotion/tone analysis. No voiceprints. Text stays on the Mac
  (DB 0600, excluded from backups, `secure_delete`), retention 1–30 days (default 30).
- Push payloads never contain transcript text or the matched phrase.

## Decisions

- Storage is raw SQLite3: LorisKnowledge (catalogue owner for FTS5) is
  local-only/unreleased, so not importable. Revisit when it ships.
- One engine instance + serial queue (Apple's analyzer cap; research §throughput).
- Apple engine never sets `ignoresResourceLimits`; `insufficientResources` → retry ×3.

## Tests

`swift test` (unit + Apple-engine integration on macOS 26+).
Parakeet: `LUMEN_HEARING_PARAKEET=1 LUMEN_HEARING_MODELS_DIR=<dir> swift test`
(downloads ≈ 480 MB from huggingface.co once).

## Phase 2 — speakers and named voices (`Sources/LumenHearing/Voices`)

Per speech event: pyannote community-1 offline diarization (FluidAudio
`OfflineDiarizerManager`) → transcript lines labelled S1, S2… (split at the
speaker change with Parakeet word timings) → speaker turns in `voices.sqlite`.

Named voices are opt-in and need the person's own recorded consent (FR/EN
sheet in the Hub). Enrolment is "teach from event": the owner picks 3–5 real
clips of that person; each clip is re-fetched, cut to that speaker's turns and
embedded. Matching: cosine, best sample per person, three bands
(`VoiceThresholds`: match ≥ 0.72 with a 0.06 lead, maybe ≥ 0.52, else unknown,
never under 2 s of speech). Unknown voices cluster over days (join ≥ 0.60);
the owner can name, merge, ignore ("this is the TV") or forget them.
Face ↔ voice: exactly one recognised Frigate face + one voice on the same
camera → evidence; 3 agreeing events and no conflict promote the cluster into
the consenting adult with that face name, else it stays a suggestion.

Safeguards: staff mode, outdoor/street cameras and missing consent stop
diarization too (`VoiceGate`, checked before and after diarization);
embeddings are AES-GCM sealed with a Keychain key (this Mac only), DB 0600,
`secure_delete`, excluded from backups; "forget me" removes a person's samples,
name, face link and labels; children: no auto-learning, re-enrol prompt after
120 days, never counted for permissions; `VoiceRights` can only lower rights.
No emotion/tone analysis. Nothing here sends audio, text or embeddings off the Mac.

Schema changes are numbered migrations in `VoiceStore.migrations`.

Diarization integration test (real model, ≈ 21 MB once):
`LUMEN_HEARING_DIARIZER=1 LUMEN_HEARING_MODELS_DIR=<dir> swift test --filter VoiceIntegration`.
Fixtures come from `Scripts/make-voice-fixtures.sh` (macOS `say`).

## Pro gate (`ProGate.swift`)

Hub features need Lumen Pro. Policy only here (7-day cached grant, fail
closed for new enablement, a definite "not Pro" pauses processing, data is
never deleted); the CloudKit read lives in the Hub app.
