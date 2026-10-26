# Helpers

`phonon-coreml-export` — the `export_coreml` example of
[gradium-ai/xn-ptts](https://github.com/gradium-ai/xn-ptts) at tag v0.4.2 (MIT OR Apache-2.0),
built with `RUSTFLAGS="-C target-cpu=apple-m1" cargo build --release -p ptts --example export_coreml`
(arm64, no `hub` feature: it only reads local model folders).

**Always set `RUSTFLAGS` as above.** The repo's `.cargo/config.toml` builds with `target-cpu=native`;
built on an M4/M5 that emits CSSC instructions (scalar `abs`, `cnt`, `ctz`, `smax`/`smin`/`umax`/`umin`)
and the helper dies with SIGILL on M1–M3 Macs ("Core-ML-Export … (Signal 4)", fixed in 4.2.2).
`HelperBinaryTests` checks the shipped binary for these instructions. The app ships it in `Contents/MacOS` (signed with the app) and uses it to
convert an installed Phonon 40m language model into a Core ML bundle for the Neural Engine
(`PhononEnvironmentManager.prepareNeuralEngine`). No Rust is needed on the user's Mac.
