# Measuring chord accuracy

Three pieces:

| Tool | What it does |
|---|---|
| `chord-eval` (Swift, `Package.swift` at the repo root) | Runs the app's own `Engine/` code on audio files and writes `.lab` files |
| `score.py` | Compares `.lab` files with reference labels using the standard MIREX metrics (`mir_eval`) |
| `make_synthetic_set.py` | Renders 12 synthetic songs with exact labels, for a quick sanity check |

## Quick start (synthetic set)

```sh
pip3 install numpy mir_eval
python3 Tools/make_synthetic_set.py --out TestSet/synthetic

swift run -c release chord-eval --models ChordDetectionPOC/Models --out results TestSet/synthetic/audio
python3 Tools/score.py --ref TestSet/synthetic/labels results/templates results/basicPitch results/btc
```

Add `--per-song` to `score.py` to see which songs fail. `chord-eval --help` lists the knobs
(`--bass-weight`, `--stay`, `--per-beat`, `--no-drum-removal`, ...) so you can compare settings,
e.g. `--out results-nobass --bass-weight 0`.

You can also export the detection for the song on screen from the app (Chords card → "Export .lab")
and score it the same way.

## A real test set (what actually matters)

The synthetic songs use simple timbres; the trained models (BTC, Basic Pitch) have never heard
anything like them, so their synthetic scores understate them and the template engine's overstate
it. Decide between engines on real recordings:

1. Pick 10–20 songs you own, across the styles you care about (acoustic, band, piano ballad,
   EDM, ...). Put them in `TestSet/real/audio/` (the folder is git-ignored, don't commit audio).
2. Get reference chords as `.lab` files named like the audio, in `TestSet/real/labels/`:
   - **Annotate yourself**: in Sonic Visualiser or Audacity, add a label at every chord change,
     export, and convert to `start<TAB>end<TAB>chord` lines. Chords in Harte syntax:
     `C`, `A:min`, `G:7`, `F:maj7`, `D:min7`, `E:sus4`, `B:dim`, `N` for no chord.
     Roughly 15–30 minutes per song.
   - **Public annotations**: Isophonics (Beatles, Queen, Carole King) and the McGill Billboard set
     publish `.lab` files. They must be aligned to *your* copy of the audio: check that the first
     chord starts where you hear it, and shift the times if not.
3. Optional: put the key in `TestSet/real/audio/<name>.key` (e.g. `A:min`) to mimic the app, which
   gets the key from MusicUnderstanding. Without it the key is estimated from the audio.
4. Run `chord-eval` and `score.py` as above.

**Fairness note:** BTC was trained on Isophonics (incl. the Beatles and Queen), Robbie Williams
and UsPop2002. It will
look unrealistically good on those songs. Use songs outside those collections when comparing BTC
with the other engines.

## Reading the numbers

- `majmin` is the headline number most papers report. Published systems: template + HMM methods
  around 65–75% on real music, trained models around 80–85%.
- `root` tells you whether the right chord *family* is found (C vs Cmaj7 both count).
- `sevenths` / `tetrads` show how well 7ths etc. are recognised; expect much lower numbers.

## Results on the synthetic set (Python mirror of the Swift pipeline)

13 songs. Song 13 is modelled on a real worship song: G D/F# Em Bm C G/B Am D, then up a
semitone for the last third. Current defaults: half-beat segments, key changes found from the
chords, slash chords from the bass, sus penalty -1.3 for the template matcher.
`majmin_inv` also requires the bass note to match (D/F# is not D).

| Engine | root | majmin | majmin_inv | sevenths |
|---|---|---|---|---|
| Templates, before this work (no bass, beat segments; 12 songs, no slash chords) | 84.2% | 85.1% | – | 73.5% |
| Templates, now | 91.8% | 88.6% | 88.0% | 78.4% |
| Basic Pitch + templates | 91.9% | 91.2% | 88.2% | 85.0% |
| BTC | 95.8% | 97.1% | 96.5% | 88.9% |

Re-measure with `chord-eval` on your Mac; then on real songs.

**Speed:** Debug builds run Swift number-crunching loops 10–50x slower than Release. To judge
speed, run the app with the Release configuration (Product → Scheme → Edit Scheme → Run →
Build Configuration) or use `swift run -c release chord-eval`.

## BTC conversion

How BTC works, its data, fine-tuning on your own songs and conversion: `Tools/btc/README.md`. `Tools/btc/cqt_mirror.py`
is the Python reference for the Swift `ConstantQ`.
