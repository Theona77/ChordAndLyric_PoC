# BTC: how it works, the data, fine-tuning and Core ML conversion

BTC ("A Bi-Directional Transformer for Musical Chord Recognition", Jonggwon Park, Kyoyun Choi,
Sungwook Jeon, Dongheon Kim, Jonghun Park, ISMIR 2019) is the "BTC (Core ML)" engine in the app.
Upstream code and weights: <https://github.com/jayg996/BTC-ISMIR19> (MIT licence).

## 1. The pipeline, end to end

```
audio (mono, 22050 Hz)
  │  cut into 10 s chunks (220500 samples)
  ▼
constant-Q transform, per chunk          ConstantQ.swift  (Python reference: cqt_mirror.py)
  144 bins = 6 octaves from C1 (32.7 Hz), 24 bins per octave (quarter tones)
  hop 2048 → 108 frames per chunk (~10.8 frames/s), value = log(|CQT| + 1e-6)
  │
  ▼
BTC transformer                          BTCChords.mlpackage
  input [1, 108, 144]  →  output [1, 108, 170] log-probabilities, one row per frame
  │
  ▼
the app's back end                       ChordEngine.swift / ChordDecoding.swift
  average frames per half beat → key-aware Viterbi smoothing → key changes → slash chords from the bass
```

The constant-Q transform is used instead of a plain FFT because its bins are spaced like piano
keys (two bins per semitone here), so "the same chord a semitone higher" is just the same picture
shifted up two rows, which is easy for a network to learn.

## 2. The model

About 3.0 million parameters (12 MB as float32).

```
log-CQT [108 × 144]
  → normalise: (x − mean) / std         mean −2.228, std 1.719 (from the training set)
  → Linear 144 → 128
  → + sinusoidal position signal        (so the model knows where in the 10 s each frame is)
  → 8 × bi-directional self-attention layer:
        forward block:  sees the current and PAST frames only (causal mask)
        backward block: sees the current and FUTURE frames only
        each block = LayerNorm → 4-head attention → residual
                     → LayerNorm → two 3-wide 1-D convolutions with ReLU → residual
        concat(forward, backward) [256] → Linear → 128
  → LayerNorm
  → Linear 128 → 170 classes, softmax per frame
```

Why two directions: a chord is easier to name once you've heard what came before *and* after
(a G between C and D is likely the V of C...). The paper's attention maps show some layers
attending locally (smoothing within one chord) and others across chord boundaries.

**The 170 classes:** 12 roots × 14 qualities, then `X` (a chord outside the vocabulary) and `N`
(no chord). Index = root × 14 + quality, with qualities in this order:

```
min maj dim aug min6 maj6 min7 minmaj7 maj7 7 dim7 hdim7 sus2 sus4
```

e.g. A:min7 = 9 × 14 + 6 = 132. No slash chords: training labels had their bass note removed,
which is why the app adds them afterwards from the bass (`SlashChords` in `ChordDecoding.swift`).

## 3. How it was trained (upstream)

| | |
|---|---|
| Data | **Isophonics** (Beatles, Queen, Zweieck, Carole King), **Robbie Williams** (Di Giorgi et al. 2013), **UsPop2002** chord annotations: roughly 480 songs of Western pop/rock |
| Audio | Not public (copyright). The authors bought/collected it; the datasets are label files only |
| Instances | 10 s windows every 5 s; CQT computed per window |
| Augmentation | Pitch shift −5…+6 semitones with rubberband (12 versions of every song), labels transposed to match |
| Loss | Cross-entropy per frame |
| Optimiser | Adam, learning rate 1e-4, betas (0.9, 0.98), batch 128 |
| Validation | 5-fold cross-validation by song |

For its accuracy on real music, see the paper's tables; trained chord models of this generation
typically reach roughly 80–85% on major/minor for Western pop. The app's synthetic set scores
higher because it's easy; real songs, especially styles BTC wasn't trained on, will score lower.

Label sources, if you want to rebuild or extend the training set:

- Isophonics: <http://isophonics.net/datasets>
- UsPop2002 chords: <https://github.com/tmc323/Chord-Annotations>
- Robbie Williams: B. Di Giorgi et al., "Automatic chord recognition based on the probabilistic
  modeling of diatonic modal harmony", 2013 (annotations distributed by the authors)
- McGill Billboard (not used by BTC, ~740 songs, good for more data): <https://ddmal.music.mcgill.ca/research/The_McGill_Billboard_Project_(Chord_Analysis_Dataset)/>

All are label files only; the audio has to be your own copies, matched to the exact recording.

## 4. Fine-tuning on your own songs (`finetune_btc.py`)

BTC has never heard Indonesian worship music, gospel piano or acoustic covers; a few dozen
annotated songs from the style you care about can help a lot. The script starts from the released
weights and trains a little more on your songs:

```sh
pip install torch librosa mir_eval pyyaml numpy
git clone https://github.com/jayg996/BTC-ISMIR19.git

cd Tools/btc
python finetune_btc.py --btc ./BTC-ISMIR19 \
    --audio ../../TestSet/real/audio --labels ../../TestSet/real/labels \
    --out btc_finetuned.pt --epochs 20 --freeze-layers 4
```

- **Data:** `name.mp3` + `name.lab` (Harte labels, sounding pitch, not capo shapes). The app's
  "Export .lab" gives you a starting point: export, fix the wrong chords and times while listening
  with the player, save. 20–50 songs is a sensible start; more is better.
- It computes features exactly like the app does, so there's no train/app mismatch.
- Pitch-shift augmentation (−5…+6 by default) is done by shifting the CQT rows, so every song
  teaches the model all 12 keys.
- `--freeze-layers 4` keeps the first 4 of the 8 attention layers fixed: less risk of forgetting
  what it learned from ~480 songs when you only have a few dozen.
- It holds out 20% of your songs and prints frame accuracy on them before and after, and saves the
  best epoch. If "before" is already higher than "after", you need more (or cleaner) data.

Tested end to end on the synthetic set (10 training songs, 3 held out, 3 epochs, ~2 minutes on CPU): held-out frame accuracy 88.5% → 94.1%. That shows the pipeline works, not that
it will gain 6 points on real songs.

## 5. Converting to Core ML (`convert_btc.py`)

```sh
python convert_btc.py --btc ./BTC-ISMIR19 --out ../../ChordDetectionPOC/Models
python convert_btc.py --btc ./BTC-ISMIR19 --checkpoint btc_finetuned.pt --out ../../ChordDetectionPOC/Models
```

What it does and why:

1. **Rewrites the forward pass with fixed shapes.** BTC's code computes tensor shapes at run time
   (`shape[2] // num_heads`), which coremltools can't convert. The rewrite uses the same weights
   with batch 1 and 108 frames hard-coded, and is checked against the original (max difference
   ~1e-5) before converting.
2. **Bakes in the normalisation** (mean/std) and a log-softmax, so the app feeds raw log-CQT and
   gets log-probabilities.
3. **Replaces the −∞ attention masks with −10000**, same softmax result, safe on every Core ML
   compute unit.
4. **Exports `BTCKernels.bin`**: the sparse constant-Q filter bank the Swift code multiplies with
   each 32768-point FFT. Generating it from the Python reference guarantees Swift and Python
   compute identical features (checked: max log difference 0.001).
5. Saves an ML Program (`.mlpackage`, float32, iOS 17+). Xcode compiles it into the app.

Model I/O: input `logcqt` [1, 108, 144] float32, output `logprobs` [1, 108, 170] float32.
Pad a final, partial window with the mean (−2.228), which normalises to 0 like BTC's padding.

## 6. Feature check (why the Swift features can be trusted)

librosa computes the CQT octave by octave with resampling; `cqt_mirror.py` computes the same
filter bank in one pass. On BTC's example song the model's frame predictions from the two agree on
**99.1%** of frames. librosa's `cqt` defaults to `tuning=0` (also in 0.6.3, the version BTC used),
so no tuning correction is applied, matching training.
