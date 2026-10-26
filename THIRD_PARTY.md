# Third-Party Licenses & Attributions

AudiobookForge is licensed under the [MIT License](LICENSE). It builds upon open-source software, speech synthesis runtimes, model weights, and Creative Commons Zero (CC0) ambient recordings listed below.

---

## 1. Software Dependencies & Runtimes

| Component | Source | License | Usage |
|---|---|---|---|
| **xn-ptts (`ptts`)** | [gradium-ai/xn-ptts](https://github.com/gradium-ai/xn-ptts) (v0.4.2) | MIT OR Apache-2.0 | Native Swift/Rust runtime and Core ML exporter (`Helpers/phonon-coreml-export`) for Phonon TTS |
| **MLX Audio / MLX** | [ml-explore/mlx](https://github.com/ml-explore/mlx) / [Blaizzy/mlx-audio](https://github.com/Blaizzy/mlx-audio) | MIT | Python bridge runtime for Kokoro MLX, Supertonic, and OmniVoice |
| **Piper** | [rhasspy/piper](https://github.com/rhasspy/piper) | MIT | Fast local ONNX neural text-to-speech engine |
| **Pocket TTS** | [kyutai-labs/pocket-tts](https://github.com/kyutai-labs/pocket-tts) | MIT (code) | Local neural TTS and voice cloning runtime |
| **FFmpeg** | [ffmpeg.org](https://ffmpeg.org) | LGPL v2.1+ / GPL v2+ | External CLI tool used for M4B/MP3 chapter encoding and loudness normalization |

---

## 2. TTS Model & Voice Weight Licenses

AudiobookForge does not bundle large TTS model weights inside the application binary; models are downloaded on demand by the user after reviewing the license notice in the app. All catalog voices are suitable for personal listening; redistribution of generated audio depends on the underlying model weights license:

| Voice / Model Family | Source Repository | Model Weights License | Redistribution of Generated Audio |
|---|---|---|---|
| **Kokoro 82M (EN / FR / ES / IT)** | [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) | Apache-2.0 | Yes (Apache-2.0) |
| **Kokoro DE — Martin & Victoria** | [kikiri-tts/kikiri-german-martin](https://huggingface.co/kikiri-tts/kikiri-german-martin), [kikiri-german-victoria](https://huggingface.co/kikiri-tts/kikiri-german-victoria) | Apache-2.0 | Yes (Apache-2.0) |
| **Kokoro DE — Thorsten** | [Thorsten-Voice/Kokoro](https://huggingface.co/Thorsten-Voice) | CC0 1.0 | Yes (CC0 Public Domain dataset) |
| **Piper — Thorsten (medium / high / emotional)** | [Thorsten-Voice/Piper](https://huggingface.co/Thorsten-Voice/Piper), [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices) | MIT / CC0 1.0 | Yes |
| **Piper — Community Voices (DE / EN)** | [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices) | Per-voice license on model card | Check individual model card before commercial redistribution |
| **Phonon 40m (DE / EN / FR / ES)** | [gradium/phonon-40m-*](https://huggingface.co/gradium) | CC BY-NC 4.0 | Non-commercial use only |
| **Phonon Voices Catalog** | [gradium/phonon-voices](https://huggingface.co/gradium/phonon-voices) | Apache-2.0 | Voice embeddings are Apache-2.0; output subject to Phonon model license |
| **Pocket TTS (DE / EN / FR / ES / IT)** | [kyutai/pocket-tts](https://huggingface.co/kyutai/pocket-tts) | CC BY 4.0 | Yes, with attribution; voice cloning requires speaker consent |
| **Supertonic M1** | [mlx-community/supertonic-3](https://huggingface.co/mlx-community/supertonic-3) | See model card (MIT runtime) | Check model card |
| **OmniVoice** | [mlx-community/OmniVoice](https://huggingface.co/mlx-community/OmniVoice) | Apache-2.0 | Yes (Apache-2.0); voice cloning requires speaker consent |

---

## 3. Bundled Ambient Soundscape Recordings (CC0 1.0 Public Domain)

All ambient soundscape loops and one-shot events in `AudiobookForge/Resources/Ambient/` are derived from field recordings on [Freesound](https://freesound.org) released under **CC0 1.0 Universal (Public Domain Dedication)** or synthesized procedurally by `scripts/build_ambient_assets.py`. Attribution is not legally required under CC0, but we gratefully credit the original recordists below:

| Scene | Role | Recording | Creator | License |
|---|---|---|---|---|
| `fire` | Base loop | [Aachen_Burning Fireplace Crackling Fire Sounds.wav](https://freesound.org/people/visionear/sounds/501417/) | visionear | CC0 1.0 |
| `fire` | One-shot events | [Crackling fireplace](https://freesound.org/people/nielstii/sounds/346321/) | nielstii | CC0 1.0 |
| `fire` | One-shot events | [Fire crackling in fireplace](https://freesound.org/people/NomadApe/sounds/444920/) | NomadApe | CC0 1.0 |
| `fire` | One-shot events | [fire crackles](https://freesound.org/people/florianreichelt/sounds/563766/) | florianreichelt | CC0 1.0 |
| `fire` | One-shot events | [Crackling Fire](https://freesound.org/people/samarobryn/sounds/414767/) | samarobryn | CC0 1.0 |
| `rain` | Base loop | [Gentle Rain from Window.wav](https://freesound.org/people/YostPeter/sounds/523405/) | YostPeter | CC0 1.0 |
| `rain` | One-shot events | [Rain on Metal Window Ledge](https://freesound.org/people/Erbsland-Music/sounds/428605/) | Erbsland-Music | CC0 1.0 |
| `rain` | One-shot events | [water drop](https://freesound.org/people/florianreichelt/sounds/683102/) | florianreichelt | CC0 1.0 |
| `rain` | One-shot events | [Water drop (splash)](https://freesound.org/people/bolkmar/sounds/451126/) | bolkmar | CC0 1.0 |
| `storm` | Base loop | [Rain - heavy storm 2.wav](https://freesound.org/people/jodybruchon/sounds/459465/) | jodybruchon | CC0 1.0 |
| `storm` | One-shot events | [Rain Thunder.mp3](https://freesound.org/people/Nimlos/sounds/359151/) | Nimlos | CC0 1.0 |
| `storm` | One-shot events | [weird_thunder_clap.wav](https://freesound.org/people/SpeedY/sounds/17059/) | SpeedY | CC0 1.0 |
| `storm` | One-shot events | [Thunder strike](https://freesound.org/people/AyaDrevis/sounds/652690/) | AyaDrevis | CC0 1.0 |
| `storm` | One-shot events | [Thunder 08](https://freesound.org/people/Emulius/sounds/744723/) | Emulius | CC0 1.0 |
| `storm` | One-shot events | [Rolling_Distant_Thunder_In_Heavy_Rain_06](https://freesound.org/people/BlondPanda/sounds/778374/) | BlondPanda | CC0 1.0 |
| `ocean` | Base loop | [ocean waves at cabo da roca portugal.wav](https://freesound.org/people/Ninochka/sounds/440712/) | Ninochka | CC0 1.0 |
| `ocean` | One-shot events | [Ocean-waves-binaural.WAV](https://freesound.org/people/L.Finck/sounds/636552/) | L.Finck | CC0 1.0 |
| `ocean` | One-shot events | [Atlantic Ocean Waves Close](https://freesound.org/people/Sacha.Julien/sounds/724583/) | Sacha.Julien | CC0 1.0 |
| `water` | Base loop | [StreamDistantSclolex.wav](https://freesound.org/people/Sclolex/sounds/324208/) | Sclolex | CC0 1.0 |
| `water` | One-shot events | [water drop](https://freesound.org/people/florianreichelt/sounds/683102/) | florianreichelt | CC0 1.0 |
| `water` | One-shot events | [Water drop (splash)](https://freesound.org/people/bolkmar/sounds/451126/) | bolkmar | CC0 1.0 |
| `water` | One-shot events | [water drop 1.aif](https://freesound.org/people/beskhu/sounds/273870/) | beskhu | CC0 1.0 |
| `water` | One-shot events | [waterDrop.mp3](https://freesound.org/people/casstway/sounds/519991/) | casstway | CC0 1.0 |
| `forest` | Base loop | [Night Frogs and Toads at Caiman Pond - Kwa Nature Reserve, French Guiana](https://freesound.org/people/felix.blume/sounds/868746/) | felix.blume | CC0 1.0 |
| `forest` | One-shot events | [Jungle nighttime crickets and frogs](https://freesound.org/people/SarahAGGross/sounds/737476/) | SarahAGGross | CC0 1.0 |
| `forest` | One-shot events | [Jungle nighttime](https://freesound.org/people/SarahAGGross/sounds/737477/) | SarahAGGross | CC0 1.0 |
| `forest` | One-shot events | [Jungle nighttime 2](https://freesound.org/people/SarahAGGross/sounds/737478/) | SarahAGGross | CC0 1.0 |
| `cyberpunk` | Base loop | [City at night Ambience.wav](https://freesound.org/people/puppetmaster685719/sounds/641211/) | puppetmaster685719 | CC0 1.0 |
| `cyberpunk` | One-shot events | [Small city ambience with traffic, motors, horn, siren, slight passerby hubbub](https://freesound.org/people/felix.blume/sounds/705049/) | felix.blume | CC0 1.0 |
| `cyberpunk` | One-shot events | [Ambient City Sounds at Night](https://freesound.org/people/RaucousRaptor/sounds/563887/) | RaucousRaptor | CC0 1.0 |
| `train` | Base loop | [inside a train.wav](https://freesound.org/people/bisanu6/sounds/143205/) | bisanu6 | CC0 1.0 |
| `train` | One-shot events | Synthesized rail joints (`scripts/build_ambient_assets.py`) | AudiobookForge | CC0 1.0 |
