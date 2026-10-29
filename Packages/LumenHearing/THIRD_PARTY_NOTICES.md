# Third-party notices — LumenHearing (Lumen Hub transcription)

Shown in the Hub (Transcription page › Credits). Keep both in sync.

| Component | Use | Licence | Source |
|---|---|---|---|
| FluidAudio 0.17.7 | Swift runtime for Parakeet ASR and Silero VAD (Core ML) | Apache-2.0 | https://github.com/FluidInference/FluidAudio |
| NVIDIA Parakeet TDT 0.6B v3 (Core ML conversion by FluidInference) | Speech-to-text model, downloaded at runtime on the owner's request | CC-BY-4.0 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 · https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml |
| Silero VAD (Core ML conversion by FluidInference) | Voice activity detection, downloaded with Parakeet | MIT | https://github.com/snakers4/silero-vad · https://huggingface.co/FluidInference/silero-vad-coreml |
| Apple Speech framework (SpeechAnalyzer / SpeechTranscriber) | Fallback engine, system-managed model | Apple SDK | macOS 26+ |
| pyannote speaker-diarization-community-1 (Core ML conversion by FluidInference, `Segmentation`, `FBank`, `Embedding`, `PldaRho`, `plda-parameters.json`, `xvector-transform.json`) | Speaker diarization (who spoke when) and voice embeddings (WeSpeaker ResNet34), downloaded at runtime on the owner's request (≈ 21 MB, pinned revision `df2625ac`) | CC-BY-4.0 | https://huggingface.co/pyannote/speaker-diarization-community-1 · https://huggingface.co/FluidInference/speaker-diarization-coreml |
| PLDA parameters by BUT Speech@FIT (inside the conversion above) | Clustering back end | CC-BY-4.0 | https://huggingface.co/BUT-FIT/diarizen-wavlm-large-s80-md |
| VBx clustering (port inside FluidAudio) | Speaker clustering code | Apache-2.0 | FluidAudio `ThirdPartyLicenses/vbx-LICENSE.md` |
| fastcluster (port inside FluidAudio) | Hierarchical clustering code | BSD-2-Clause | FluidAudio `ThirdPartyLicenses/fastcluster-LICENSE.md` |

Attribution (CC-BY-4.0): "Parakeet TDT 0.6B v3" by NVIDIA, licensed under
CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Converted to Core ML
by FluidInference. No changes to the weights are made by LorisLabs.

Attribution (CC-BY-4.0): "speaker-diarization-community-1" by pyannote
(pyannoteAI), with WeSpeaker ResNet34 embeddings (WeSpeaker project) and PLDA
parameters by Brno University of Technology / BUT Speech@FIT, licensed under
CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Modified: converted
to Core ML (fixed input shapes, mixed precision, FBank split from the
embedding model) by Fluid Inference. No further changes by LorisLabs. Only the
Community-1 artifacts listed in FluidInference's NOTICE.md are used (the
legacy `wespeaker*.mlmodelc` files are not loaded).

FluidAudio's optional NeMo text-processing binary (`NemoTextProcessing` trait)
is turned off, so it is not linked or shipped.

Licences checked 2026-10-28 on the Hugging Face model cards (cc-by-4.0, mit)
and FluidAudio's LICENSE (Apache-2.0); diarization models checked 2026-10-29
(FluidInference LICENSE + NOTICE.md + PROVENANCE.md at revision df2625ac). Re-check before each Hub release.
