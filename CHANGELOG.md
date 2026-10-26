# Changelog

All notable changes to **AudiobookForge** are documented in this file.

## [4.4.0] - 2026-10-26

### Added
- **Calm speech normalization & text clean-up**: improved abbreviation, number, unit, and date normalization across German, English, French, Spanish, and Italian.
- **Audio quality check**: automatic post-synthesis verification for clipped, silent, or truncated chapter outputs with targeted retry.
- **Configurable Phonon inference steps**: adjustable quality/speed steps for Gradium Phonon 40m synthesis.
- **Phonon Neural Engine backend (v4.1–v4.2)**: Core ML exporter (`phonon-coreml-export` compiled for `apple-m1` compatibility across M1–M4 Macs) and power-saving Neural Engine profile.
- **Phonon English 31M free option (v4.2.1)**: un-gated English Phonon model option alongside the 40m multilingual models.
- **Expression controls & Thorsten styles (v4.2)**: speaking rate, expressiveness, pause rhythm sliders, and emotional/style variants directly in the voice gallery.

### Fixed
- Smooth scrolling and inline title editing in large chapter lists (v4.2.3).
- Honest on-disk size reporting for installed TTS engines and voice packs (v4.2.2).
- Automatic rollback of interrupted re-voicing jobs on launch (v4.1).

---

## [4.0.0] - 2026-10-25

### Added
- **Gradium Phonon 40m TTS engine**: ultra-fast neural synthesis (~56× real-time per worker, up to ~130× in parallel) with 78 voices across DE, EN, FR, and ES via the native `xn-ptts` runtime.
- **Kyutai Pocket TTS engine**: high-quality synthesis (~14× real-time) with 24 voices per language (DE, EN, FR, ES, IT) and instant local voice cloning.
- **236 bundled voice previews**: offline audio previews (`Resources/VoiceSamples`) for every catalog voice so users can audition voices before downloading model weights.
- **Re-narrate completed audiobooks ("Re-voice")**: switch any finished book to a new voice or engine while preserving chapter structure, AI summaries, and figure descriptions, with automatic backup and restore on failure.
- **Expanded multi-language UI**: full interface translations in English, German, French, Spanish, and Italian.

---

## [3.0.0] - 2026-10-19

### Added
- **Flow Design System**: frosted glass cards, customizable accent colors (Violet, Coral, Teal, Amber, Rose, Slate), light/dark/system appearance, and scalable typography (XS–XXL).
- **Voice Gallery & Local Voice Cloning**: unified catalog for Kokoro MLX, Piper, Supertonic, OmniVoice MLX (zero-shot voice cloning across 600+ languages), and macOS system voices, plus microphone recording and audio file import for custom `clone:<uuid>` voices.
- **AI Chapter Outline, Summarization & Vision Figure Descriptions**: offline-capable pipeline connecting to local OpenAI-compatible servers (oMLX, LM Studio, Ollama) for intelligent chapter merging, study summaries, and textbook diagram descriptions.
- **Built-in Audiobook Player & Ambient Soundscapes**: chapter-aware M4B/MP3 player with procedural pixel-art scenes and CC0 ambient soundbeds (fireplace, rain, thunderstorm, ocean, stream, night forest, cyberpunk city, night train) with randomized spatial one-shot events.
- **Pronunciation lexicon & natural pause engine**: customizable phonetic replacements and context-aware pause durations between sentences, paragraphs, and headings.

---

## [2.0.0] - 2026-10-04

### Added
- **Streaming audio pipeline**: eliminated uncompressed WAV intermediate files in favor of direct compressed chapter audio, drastically reducing temporary disk usage.
- **Pause & resume across app launches**: persistent per-chapter progress tracking with clean subprocess lifecycle management.
- **Automatic local LLM lifecycle**: optional model unloading on local oMLX/LM Studio servers after summarization passes complete.

---

## [1.0.0] - 2026-08-29

### Added
- Initial macOS release for converting PDF and EPUB documents into chaptered M4B and MP3 audiobooks.
- Multi-column PDF layout extraction, automatic table-of-contents detection, front/back matter filtering, and OCR fallback via Apple Vision.
- Local TTS synthesis via Kokoro MLX and Piper with FFmpeg chapter packaging and cover art embedding.
