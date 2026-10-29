# Neural voice spike

Question: can PeopleMaps ship a natural on-device neural voice? Measured 2026-10-28 on an Apple M5 Pro (48 GB), macOS CLI, sherpa-onnx 2.0.1 (Python wheel), CPU execution provider. Harness: `Spikes/neural-voice/` (git-ignored; scripts `bench.py`, `textnorm.py`, `build_lexicon.py`, `prerender.py`, `stitch.py`).

**Not done / not verified**
- **No iPhone or Simulator measurement.** v2.0.1 has no prebuilt iOS xcframework (neither do v2.0.0 and v1.13.8), and `cmake` is not installed, so the iOS library was not built. iPhone figures below are labelled estimates.
- **No listening test.** The agent cannot hear audio; "natural" judgements are the user's to make from the WAVs. Only objective seam metrics are reported.
- Quality ranking of models comes from the projects' own claims and third-party write-ups, not from this spike.

## 1. Candidates and licences

| Candidate | Code / model licence | Voice-data licence | Can a free iOS app bundle it? |
|---|---|---|---|
| **Kokoro-82M v1.0** (StyleTTS2-based, 82M params) | Apache-2.0 (model card tag, "Apache-licensed weights") | One Apache-2.0 licence for the whole release; `VOICES.md` has **no per-voice licence**. Training data per the card: public domain, Apache/MIT-style audio, **synthetic audio from closed commercial TTS providers**, plus two CC BY sets (Koniwa `tnc` CC BY 3.0, SIWIS CC BY 4.0). | **Yes, with attribution** (Apache-2.0 notice; add CC BY credit for the two sets to be safe). Residual risk: the synthetic-from-closed-TTS data. The author says it is the data source; whether those providers' terms bind downstream users is untested. Flagging, not resolving. |
| **Piper** (VITS, `rhasspy/piper`, MIT; archived, successor `piper1-gpl` is GPL-3) | MIT for the engine | **Per voice, mostly restricted.** `en_US-lessac`: Lessac Technologies Blizzard-2013 licence, granted only to a named person/org via a signed form, so not redistributable as-is. `ryan`: CC BY-NC-SA 4.0 (non-commercial). `hfc_female`: CC BY-NC-SA 4.0. `amy`: "See URL" (Mycroft mimic3-voices), unclear. `libritts_r`: CC BY 4.0 (ok). `kristin`: public domain (LibriVox, ok). | Only `libritts_r` (CC BY 4.0) and `kristin` (public domain) are clearly bundlable. The best-known voices (lessac, ryan) are not. Quality of those two is lower than Kokoro by general account (not measured here). |
| **Kitten TTS** | Code Apache-2.0; **models licensed separately** (KittenTTS 2 under the "Stellon Labs Community License", terms not read) | per model repo | v0.8 nano int8 is 25 MB, 15M params, but the author's own comparisons rank it below Piper/Kokoro. KittenTTS 2 is 1.7B params, 492-954 MB: too large for a phone. Not pursued. |
| **Supertonic** (~99M params, ONNX, iOS example) | Code MIT; **weights OpenRAIL-M** (use restrictions apply; file not read) | n/a | Repo is **archived**, "no updates, bug fixes, security patches". Rejected as a dependency. |
| **Kyutai Pocket TTS** (~100M params) | CC-BY-4.0 on the model card (gated download: accept terms on Hugging Face) | n/a | Bundling with attribution looks permitted, but the card carries use restrictions (no impersonation, no misinformation). Authors claim ~6x real time on a MacBook Air M4 with 2 cores and ~200 ms to first audio; not measured here, no iOS runtime checked. Worth a follow-up spike if Kokoro disappoints. |

**Runtime licences.** sherpa-onnx: Apache-2.0. ONNX Runtime: MIT. **espeak-ng (the phonemiser Kokoro and Piper normally use) is GPL-3.0 and must not be linked into the app.** In my runs the sherpa-onnx 2.0.1 wheel had no espeak fallback at all: with no lexicon it refuses to run, and any word missing from the lexicon is silently dropped (it said "OOV ... skipped" and the word vanished from the audio, e.g. "Westlake", "arrived", "Occidental"). That is a hard requirement for us: **every street name must be in a lexicon we ship.** I generated the missing words at build time with espeak-ng via `phonemizer` + a small IPA mapping (tool not shipped; only its pronunciation output is). Whether espeak output used this way is clean of GPL needs a legal check. Confirm that the iOS build of sherpa-onnx behaves the same.

## 2. Live synthesis

Runtime chosen: **sherpa-onnx** (wraps Kokoro and Piper, ships C API/Swift wrappers, ONNX Runtime CPU). Alternatives considered, not built: Core ML conversion (Kokoro's duration predictor and dynamic shapes make this work-heavy; Kokoro-CoreML ports exist but were not evaluated), MLX Swift (Mac/iOS capable, newer, no benchmark taken), ONNX Runtime with the Core ML EP (known to partition poorly on dynamic-shape TTS graphs).

Ten guidance lines (e.g. "In 500 feet, turn left onto North 45th Street."; digits expanded to words by our own normaliser first; full list in `bench.py`). Non-streaming: a one-sentence line is generated in one call, so **time to first audio = whole-line time**. "Short line" below is line 1 (3.38 s of Kokoro audio). Each row is one process, so peak RSS is clean.

| Config (Mac M5 Pro) | Threads | Cold load | First line (cold) | Short line, warm | Warm RTF (mean of 10) | RSS after load | Peak RSS |
|---|---|---|---|---|---|---|---|
| Kokoro v1.0 fp32, af_heart | 1 | 0.41 s | 1.99 s | 2.02 s | 0.60 | 689 MB | 891 MB |
| Kokoro v1.0 fp32, af_heart | 2 | 0.42 s | 1.10 s | 1.09 s | 0.33 | 689 MB | 892 MB |
| Kokoro v1.0 fp32, af_heart | 4 | 0.41-0.43 s | 0.64-0.67 s | 0.64-0.70 s | 0.19-0.20 | 689 MB | 893 MB |
| Kokoro v1.1 int8 (zh+en pack), sid 0 | 2 | 0.48 s | 1.25 s | 1.30 s | 0.57 | 514 MB | 703 MB |
| Piper lessac-high (not shippable, see licences) | 2 | 0.35 s | 0.49 s | 0.52 s | 0.25 | 288 MB | 400 MB |
| Piper lessac-high | 4 | 0.34 s | 0.27 s | 0.26 s | 0.14 | 288 MB | 383 MB |

Notes: the int8 row ran before I added the lexicon fix, so some words were dropped and it is not like for like; it still shows int8 is **slower** than fp32 on this Mac (0.57 vs 0.33 at 2 threads). "Cold load" is ONNX session creation; the first inference is slower than later ones (page-in), shown as "first line".

**Added app size** (model files; sherpa-onnx iOS static libs not built, so excluded. For scale, the macOS arm64 static-lib release tarball is 20 MB and the shared-lib one 8 MB, bz2):

| Bundle | Installed | Compressed (gzip -6; App Store delivers compressed, ONNX weights barely compress) |
|---|---|---|
| Kokoro v1.0 fp32 `model.onnx` + one voice (voices.bin is 28 MB for all 53; one voice is ~0.5 MB) + 6 MB lexicon | ~333 MB | ~308 MB |
| Kokoro v1.1 int8 `model.int8.onnx` (114 MB) + voices.bin (54 MB, 103 voices) + lexicon | ~175 MB | ~150 MB |
| Piper lessac-high `.onnx` | 114 MB | 106 MB |

The App Store's over-the-air download limit and the user's expectation of a maps app make a 150-300 MB add costly; the current app is far smaller.

**iPhone 12 / A14 estimate (not measured).** No published Kokoro-on-A14 benchmark was found. Scaling from this Mac by CPU class (A14: 2 performance + 4 efficiency cores, roughly 2-3x slower per thread than this M5 Pro and fewer fast threads), I'd expect Kokoro fp32 RTF around **0.6-1.0**, so a 3.4 s line takes **~2-3.5 s to first audio** on an A14, and peak memory ~0.9 GB (under iOS' foreground limit on a 4 GB phone, but heavy next to the map). Piper-class models: RTF ~0.3-0.5. Treat all of this as a guess to be replaced by a real device run.

Sample WAVs (Kokoro af_heart, sid 3, then Piper lessac-high for comparison; same 10 lines, in order):
- `Spikes/neural-voice/out/kokoro10-heart-t4-01.wav` ... `-10.wav`
- `Spikes/neural-voice/out/piper-lessac-high-t4-01.wav` ... `-10.wav`

(Absolute: `/Users/lkbidy/atrium/peoplemaps/.claude/worktrees/voice-neural-spike-40d722/Spikes/neural-voice/out/`.)

## 3. Pre-rendering

- **Distinct street names in the bundled graph** (`Core/Resources/seattle-graph.json.gz`): **773** (774 entries, one empty), 484 distinct words after splitting. The graph covers only part of the city: for the whole of Seattle expect several times more (rough guess in the low thousands; not counted).
- **Phrase templates** (20 clips rendered): 4 distances ("in five hundred feet", "in a quarter mile", "in one thousand feet", "in one mile"), 6 maneuvers (turn/bear/keep left/right onto), continue straight on, U-turn on, 3 roundabout exits, "then", arrival (3 variants), rerouting. Maneuver × distance × name is composed at runtime: 773 + 20 clips, not 10,000+ sentences.
- **Rendered all of them** with Kokoro fp32 af_heart, 4 threads: 263 s render time, **1,104 s of audio** (names average ~1.4 s), 53 MB as 24 kHz WAV.

| Encoding (793 clips) | Total payload | On disk as separate files (4 KB blocks) |
|---|---|---|
| AAC-LC 32 kbps mono (ffmpeg `aac`) | 6.45 MB | 7.9 MB |
| AAC 32 kbps (AudioToolbox `aac_at`, what iOS decodes natively) | **5.66 MB** | 6.9 MB |
| Opus 24 kbps mono | **3.39 MB** | 5.0 MB |

Pack clips into one archive to avoid block overhead (payload sizes then apply). AAC decodes natively with `AVAudioPlayer`; Opus plays on iOS only inside a CAF container (not tested here); otherwise it needs a decoder library. A sample set: `Spikes/neural-voice/out/prerender-sample/*.m4a`.

**Stitching.** Five sentences built as `[distance clip] + [maneuver clip] + [name clip]` with 60 ms silence and silence-trimmed clips, next to the live render of the same sentence (`out/stitch/stitch-N.wav` vs `out/stitch/live-N.wav`):
- Stitched is **8-9% longer** than live (e.g. 3.66 s vs 3.38 s), which fits the added gaps.
- Pitch at each seam (end of previous clip → start of next, Hz, crude autocorrelation): 194→312, 195→203, 205→235, 190→231, 190→229, 195→209, 203→253, 205→203. Most seams jump 15-50 Hz up, one jumps 118 Hz. Each name clip is rendered as a standalone sentence, so it starts at utterance-initial pitch with its own falling contour. **Expect audible seams** unless fixed; this is a prediction from the numbers, please listen.
- Mitigations, none tested: render each name inside a carrier ("onto X") and cut after the carrier; add a short cross-fade; render names without final-sentence intonation; or pre-render the common maneuver × top-N names as whole sentences.

## 4. Recommendation

**Pre-render with Kokoro (af_heart), keep the system voice as the fallback. Do not ship live neural synthesis.**

| | Live Kokoro on device | Pre-rendered Kokoro clips | Not worth it (stay on system voice) |
|---|---|---|---|
| Added size | ~150-310 MB (+ runtime libs, unmeasured) | **3.4-6.5 MB** (grows with city coverage) | 0 |
| Runtime cost | RAM ~0.9 GB (fp32) / 0.7 GB (int8), est. 2-3.5 s to first audio on A14, battery | Plays an audio file: nothing | none |
| Quality | Full-sentence prosody, can say anything | Per-clip quality is the live model's; seams between clips likely audible | Robotic, user's complaint |
| Handles any text | Yes, but every word needs a lexicon entry (OOV words are dropped silently) | Only streets and phrases we rendered; new places, POIs, renamed roads need the system-voice fallback (voice switches mid-route) | Yes |
| Licence / compliance | Apache-2.0 + attribution; synthetic-training-data question; espeak-ng GPL must stay out; build/maintain the iOS sherpa-onnx lib | Same model licence; clips are our own output; no GPL at runtime | None |
| Engineering risk | iOS lib build unmeasured; memory and latency on real phones unknown | Low: asset pipeline + AVAudioPlayer + stitching tuning | None |
| Reversible | Hard (ships a big model) | Easy | n/a |

Why not live: size and RAM are 50-100x the pre-rendered option, A14 latency is probably 2+ s per line, and the main benefit (arbitrary text) matters little because the street set is fixed and bundled. Why not "not worth it": quality is the user's stated goal and the pre-rendered payload is cheap. Next steps if accepted: (1) listen to `out/stitch/` and the live WAVs to confirm the voice and seam quality, (2) re-render names with carrier phrase to fix seams, (3) count names for all of Seattle (the graph is expanding in the `all-seattle-spike` session), (4) decide fallback behaviour for names not in the pack, (5) add attribution to Acknowledgements (Kokoro Apache-2.0; CC BY: Koniwa `tnc`, SIWIS).
