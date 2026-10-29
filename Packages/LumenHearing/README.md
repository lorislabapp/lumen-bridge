# LumenHearing — Lumen Hub speech transcription (Phase 1)

On-device transcription of Frigate `speech` events on the always-on Mac.
Research and legal basis: Lumen for Frigate `docs/research/2026-10-29-audio-transcription-speaker-id.md`.

## Pipeline

MQTT `end` (speech) + REST poll `/api/events?label=speech` → safeguards →
clip.mp4 → AVAssetReader 16 kHz mono Float32 → VAD (Silero, energy fallback) →
one shared engine on a serial queue (Parakeet TDT v3 via FluidAudio, or Apple
SpeechTranscriber on macOS 26+) → `SpeakerAttributionStage` (no-op, Phase 2
seam) → SQLite + FTS5 → keyword match → push "Keyword heard" (camera only).

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
