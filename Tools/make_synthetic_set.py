#!/usr/bin/env python3
"""Render a small synthetic test set with exact chord labels.

    pip install numpy
    python3 Tools/make_synthetic_set.py --out TestSet/synthetic

Writes <out>/audio/song_XX.wav, <out>/audio/song_XX.key and <out>/labels/song_XX.lab.

Each song has a key, tempo and progression; a "piano" plays the chords (varied voicings and
inversions), a bass plays the root (with occasional passing notes), drums play a rock beat and a
"voice" sings a melody with non-chord tones. Every song is detuned by up to +-25 cents.

This is NOT a substitute for real recordings: the timbres are simple and the trained models (BTC,
Basic Pitch) have never heard anything like them. Use it to catch regressions and gross errors;
judge accuracy on real songs (see Tools/README.md).
"""
import argparse
import os
import wave

import numpy as np

SR = 22050
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
QUALITIES = {  # harte: intervals
    "maj": [0, 4, 7], "min": [0, 3, 7], "7": [0, 4, 7, 10], "maj7": [0, 4, 7, 11],
    "min7": [0, 3, 7, 10], "sus4": [0, 5, 7], "sus2": [0, 2, 7], "dim": [0, 3, 6],
}

# Progressions as (scale-degree semitones above the tonic, quality, beats[, bass interval]).
# A bass interval makes a slash chord: (7, "maj", 4, 4) in G is D with F# in the bass (D/F#).
PROGRESSIONS = {
    "pop": [(0, "maj", 4), (7, "maj", 4), (9, "min", 4), (5, "maj", 4)],
    "doo-wop": [(0, "maj", 4), (9, "min", 4), (5, "maj", 4), (7, "maj", 4)],
    "jazzy": [(2, "min7", 4), (7, "7", 4), (0, "maj7", 4), (9, "min7", 4)],
    "minor": [(0, "min", 4), (8, "maj", 4), (3, "maj", 4), (10, "maj", 4)],
    "minor-v": [(0, "min", 4), (5, "min", 4), (7, "7", 4), (0, "min", 4)],
    "sus": [(0, "sus4", 2), (0, "maj", 2), (5, "sus2", 2), (5, "maj", 2), (7, "sus4", 2), (7, "maj", 2), (0, "maj", 4)],
    "fast": [(0, "maj", 2), (5, "maj", 2), (7, "maj", 2), (5, "maj", 2)],
    "dim": [(0, "maj", 4), (1, "dim", 4), (2, "min", 4), (7, "7", 4)],
    "blues": [(0, "7", 4), (5, "7", 4), (0, "7", 4), (0, "7", 4), (5, "7", 4), (5, "7", 4), (0, "7", 4), (7, "7", 4)],
    "ballad": [(0, "maj", 4), (4, "min", 4), (5, "maj", 4), (7, "sus4", 2), (7, "maj", 2)],
    "worship": [(0, "maj", 4), (7, "maj", 4, 4), (9, "min", 4), (4, "min", 4),
                (5, "maj", 4), (0, "maj", 4, 4), (2, "min", 4), (7, "maj", 4)],
}

SONGS = [  # (progression, tonic, minor key?, bpm, repeats[, modulation semitones for the last third])
    ("pop", 0, False, 100, 4), ("doo-wop", 7, False, 120, 4), ("jazzy", 3, False, 90, 3),
    ("minor", 9, True, 110, 4), ("minor-v", 4, True, 95, 4), ("sus", 2, False, 105, 3),
    ("fast", 9, False, 140, 6), ("dim", 5, False, 100, 3), ("blues", 10, False, 125, 2),
    ("ballad", 8, False, 72, 3), ("pop", 6, False, 128, 4), ("minor", 1, True, 85, 3),
    # Worship-style ending: G major, up a semitone to Ab for the last third.
    ("worship", 7, False, 76, 6, 1),
]


def midi_hz(m, detune):
    return 440.0 * 2 ** ((m - 69 + detune) / 12)


def tone(freq, dur, rng, partials=8, decay=2.5, bright=0.6):
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for h in range(1, partials + 1):
        f = freq * h * (1 + 0.0004 * (h - 1) ** 2)          # slight inharmonicity
        if f > SR / 2.2:
            break
        out += (bright ** (h - 1)) / h ** 0.5 * np.sin(2 * np.pi * f * t + rng.uniform(0, 2 * np.pi))
    env = np.exp(-decay * t) * np.minimum(1, t / 0.005)
    env[-min(n, 200):] *= np.linspace(1, 0, min(n, 200))
    return out * env


def voice(freqs_durs, detune):
    """Sine-ish voice with vibrato; list of (midi or None, duration)."""
    chunks = []
    for m, d in freqs_durs:
        n = int(d * SR)
        t = np.arange(n) / SR
        if m is None:
            chunks.append(np.zeros(n))
            continue
        f = midi_hz(m, detune) * (1 + 0.006 * np.sin(2 * np.pi * 5.5 * t))
        phase = 2 * np.pi * np.cumsum(f) / SR
        sig = np.sin(phase) + 0.3 * np.sin(2 * phase) + 0.15 * np.sin(3 * phase)
        env = np.minimum(1, t / 0.04) * np.minimum(1, (d - t) / 0.05)
        chunks.append(sig * env)
    return np.concatenate(chunks)


def drums(n_beats, beat, rng):
    n = int(n_beats * beat * SR) + SR
    out = np.zeros(n)
    t = np.arange(int(0.25 * SR)) / SR
    kick = np.sin(2 * np.pi * (50 + 80 * np.exp(-t * 30)) * t) * np.exp(-t * 12)
    for b in range(n_beats):
        i = int(b * beat * SR)
        if b % 2 == 0:
            out[i:i + len(kick)] += 0.9 * kick
        else:
            sn = rng.standard_normal(int(0.18 * SR)) * np.exp(-np.arange(int(0.18 * SR)) / SR * 25)
            out[i:i + len(sn)] += 0.35 * sn
        for half in (0, 0.5):
            j = int((b + half) * beat * SR)
            hh = rng.standard_normal(int(0.05 * SR))
            hh = np.diff(hh, prepend=0) * np.exp(-np.arange(len(hh)) / SR * 80)
            out[j:j + len(hh)] += 0.12 * hh
    return out


def render(prog_name, tonic, minor, bpm, repeats, rng, modulation=0):
    detune = rng.uniform(-0.25, 0.25)
    beat = 60.0 / bpm
    lead_in = 1.0
    events = []                                   # (start, end, root pc, quality)
    t = lead_in
    for r in range(repeats):
        shift = modulation if r >= repeats - repeats // 3 else 0
        for degree, quality, beats, *inv in PROGRESSIONS[prog_name]:
            events.append((t, t + beats * beat, (tonic + degree + shift) % 12, quality, inv[0] if inv else 0))
            t += beats * beat
    total = t + 1.5
    mix = np.zeros(int(total * SR) + SR)

    def add(sig, start, gain):
        i = int(start * SR)
        mix[i:i + len(sig)] += gain * sig[: len(mix) - i]

    for start, end, root, quality, inv in events:
        intervals = QUALITIES[quality]
        # Piano: re-strike each half bar, random inversion/voicing around C4.
        base = 48 + root if root >= 5 else 60 + root
        notes = [base + i for i in intervals]
        if rng.random() < 0.4:
            notes = notes[1:] + [notes[0] + 12]   # first inversion
        if rng.random() < 0.3:
            notes.append(notes[0] + 12)
        strike = start
        while strike < end - 1e-6:
            dur = min(2 * beat, end - strike)
            for m in notes:
                add(tone(midi_hz(m, detune), dur + 0.3, rng), strike + rng.uniform(0, 0.015), 0.18)
            strike += 2 * beat
        # Bass: root on each beat, occasional fifth or approach note.
        b = start
        bass_pc = (root + inv) % 12
        bass_root = 36 + bass_pc if bass_pc < 8 else 24 + bass_pc
        while b < end - 1e-6:
            m = bass_root
            r = rng.random()
            if r < 0.15 and inv == 0:
                m = bass_root + 7
            elif r < 0.22 and end - b <= beat + 1e-6:
                m = bass_root + rng.choice([-1, 2])       # passing note into the next chord
            add(tone(midi_hz(m, detune), beat * 0.95, rng, partials=5, decay=3.0, bright=0.4), b, 0.45)
            b += beat

    # Voice: chord tones on strong beats, neighbour tones in between, some rests.
    melody = []
    for start, end, root, quality, inv in events:
        intervals = QUALITIES[quality]
        d = start
        while d < end - 1e-6:
            step = beat if rng.random() < 0.7 else beat / 2
            step = min(step, end - d)
            if rng.random() < 0.15:
                melody.append((None, step))
            else:
                chord_tone = 60 + root + rng.choice(intervals) + (12 if rng.random() < 0.3 else 0)
                m = chord_tone if rng.random() < 0.7 else chord_tone + rng.choice([-2, -1, 1, 2])
                melody.append((m, step))
            d += step
    add(voice(melody, detune), lead_in, 0.22)
    add(drums(int((t - lead_in) / beat), beat, rng), lead_in, 0.5)

    mix = mix[: int(total * SR)]
    mix = 0.9 * mix / (np.abs(mix).max() + 1e-9)

    lab = [f"0.000\t{lead_in:.3f}\tN"]
    degree_names = {3: "b3", 4: "3", 7: "5", 10: "b7", 11: "7"}
    for start, end, root, quality, inv in events:
        label = NAMES[root] if quality == "maj" else f"{NAMES[root]}:{quality}"
        if inv:
            label += "/" + degree_names[inv]
        lab.append(f"{start:.3f}\t{end:.3f}\t{label}")
    lab.append(f"{t:.3f}\t{total:.3f}\tN")
    key = f"{NAMES[tonic]}:{'min' if minor else 'maj'}"
    return mix, "\n".join(lab) + "\n", key, detune


def write_wav(path, x):
    pcm = np.clip(x * 32767, -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="TestSet/synthetic")
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    audio_dir = os.path.join(args.out, "audio")
    label_dir = os.path.join(args.out, "labels")
    os.makedirs(audio_dir, exist_ok=True)
    os.makedirs(label_dir, exist_ok=True)

    rng = np.random.default_rng(args.seed)
    for i, (prog, tonic, minor, bpm, repeats, *mod) in enumerate(SONGS, start=1):
        name = f"song_{i:02d}"
        mix, lab, key, detune = render(prog, tonic, minor, bpm, repeats, rng, *mod)
        write_wav(os.path.join(audio_dir, name + ".wav"), mix)
        open(os.path.join(label_dir, name + ".lab"), "w").write(lab)
        open(os.path.join(audio_dir, name + ".key"), "w").write(key + "\n")
        print(f"{name}: {prog:<8} {key:<6} {bpm:>3} bpm, {len(mix) / SR:5.1f}s, detune {100 * detune:+.0f} cents")


if __name__ == "__main__":
    main()
