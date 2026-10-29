# Third-party notices — LumenHearing (Lumen Hub transcription)

Shown in the Hub (Transcription page › Credits). Keep both in sync.

| Component | Use | Licence | Source |
|---|---|---|---|
| FluidAudio 0.17.7 | Swift runtime for Parakeet ASR and Silero VAD (Core ML) | Apache-2.0 | https://github.com/FluidInference/FluidAudio |
| NVIDIA Parakeet TDT 0.6B v3 (Core ML conversion by FluidInference) | Speech-to-text model, downloaded at runtime on the owner's request | CC-BY-4.0 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 · https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml |
| Silero VAD (Core ML conversion by FluidInference) | Voice activity detection, downloaded with Parakeet | MIT | https://github.com/snakers4/silero-vad · https://huggingface.co/FluidInference/silero-vad-coreml |
| Apple Speech framework (SpeechAnalyzer / SpeechTranscriber) | Fallback engine, system-managed model | Apple SDK | macOS 26+ |

Attribution (CC-BY-4.0): "Parakeet TDT 0.6B v3" by NVIDIA, licensed under
CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Converted to Core ML
by FluidInference. No changes to the weights are made by LorisLabs.

FluidAudio's optional NeMo text-processing binary (`NemoTextProcessing` trait)
is turned off, so it is not linked or shipped.

Licences checked 2026-10-28 on the Hugging Face model cards (cc-by-4.0, mit)
and FluidAudio's LICENSE (Apache-2.0). Re-check before each Hub release.
