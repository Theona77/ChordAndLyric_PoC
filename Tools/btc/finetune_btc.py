"""Fine-tune BTC on your own songs, then convert with convert_btc.py.

    pip install torch librosa mir_eval pyyaml numpy
    git clone https://github.com/jayg996/BTC-ISMIR19.git

    python finetune_btc.py --btc ./BTC-ISMIR19 \
        --audio ../../TestSet/real/audio --labels ../../TestSet/real/labels \
        --out btc_finetuned.pt --epochs 20

    python convert_btc.py --btc ./BTC-ISMIR19 --checkpoint btc_finetuned.pt \
        --out ../../ChordDetectionPOC/Models

Data: one audio file per song plus a MIREX .lab file with the same name (Harte labels, e.g.
"C", "A:min7", "D/3", "N"). Chords outside BTC's 14 qualities become "X" (unknown); slash-chord
bass notes are ignored, as in BTC's own training.

What it does, mirroring BTC's training recipe (Park et al., ISMIR 2019):
  - 10 s instances every 5 s; each instance's CQT is computed on its own 10 s of audio, with the
    exact same features the app computes (cqt_mirror.py / ConstantQ.swift): 108 frames x 144 bins.
  - Pitch-shift augmentation (default -5...+6 semitones, like BTC). BTC shifted the audio with
    rubberband; here the CQT is shifted by 2 bins per semitone and the labels are transposed, which
    is much faster and close enough for fine-tuning.
  - Starts from the released large-vocabulary weights and keeps their feature mean/std, so the
    fine-tuned model drops into the app unchanged.
  - Songs are split into train/validation (--val-fraction); frame accuracy is reported on the
    validation songs before and after training, so you can see whether it helped.
"""
import argparse
import os
import random
import sys

import librosa
import mir_eval
import numpy as np
import torch
import torch.nn.functional as F
import yaml

import cqt_mirror

np.float = float  # BTC uses the removed np.float alias

SR, HOP, T, BINS = 22050, 2048, 108, 144
INSTANCE = 10 * SR
STEP = 5 * SR
FLOOR = np.log(1e-6)
QUALITIES = ["min", "maj", "dim", "aug", "min6", "maj6", "min7", "minmaj7",
             "maj7", "7", "dim7", "hdim7", "sus2", "sus4"]
X_CLASS, N_CLASS = 168, 169
AUDIO_EXT = (".wav", ".mp3", ".m4a", ".flac", ".aif", ".aiff")


# MARK: labels

def class_of(label):
    """Harte label -> BTC class index (0..169), like BTC's convert_to_id_voca."""
    if label in ("N", ""):
        return N_CLASS
    try:
        root, quality, _, _ = mir_eval.chord.split(label, reduce_extended_chords=True)
    except mir_eval.chord.InvalidChordException:
        return X_CLASS
    if root in ("N", "X"):
        return N_CLASS if root == "N" else X_CLASS
    quality = quality or "maj"
    if quality not in QUALITIES:
        return X_CLASS
    return mir_eval.chord.pitch_class_to_semitone(root) % 12 * 14 + QUALITIES.index(quality)


def transpose_class(c, semitones):
    if c >= 168:
        return c
    root, quality = divmod(c, 14)
    return (root + semitones) % 12 * 14 + quality


def frame_labels(intervals, labels, times):
    """Class of the chord sounding at each frame time."""
    classes = np.full(len(times), N_CLASS, dtype=np.int64)
    ids = [class_of(l) for l in labels]
    for (start, end), c in zip(intervals, ids):
        classes[(times >= start) & (times < end)] = c
    return classes


# MARK: data

def load_song(audio_path, lab_path, basis):
    y, _ = librosa.load(audio_path, sr=SR, mono=True)
    intervals, labels = mir_eval.io.load_labeled_intervals(lab_path)
    instances = []
    for start in range(0, max(len(y) - INSTANCE, 0) + 1, STEP):
        seg = y[start:start + INSTANCE]
        feat = np.log(np.abs(cqt_mirror.cqt(seg, basis=basis)) + 1e-6).T[:T]      # [frames, 144]
        times = (start + np.arange(len(feat)) * HOP) / SR
        lab = frame_labels(intervals, labels, times)
        if len(feat) < T:                                                      # last, short instance
            pad = T - len(feat)
            feat = np.pad(feat, ((0, pad), (0, 0)), constant_values=np.nan)    # filled with the mean later
            lab = np.pad(lab, (0, pad), constant_values=-100)                  # ignored by the loss
        instances.append((feat.astype(np.float32), lab))
    return instances


def shift(feat, lab, semitones):
    """Pitch-shift a CQT instance by rolling bins (2 per semitone) and transpose its labels."""
    k = 2 * semitones
    out = np.full_like(feat, FLOOR)
    if k > 0:
        out[:, k:] = feat[:, :-k]
    elif k < 0:
        out[:, :k] = feat[:, -k:]
    else:
        out = feat.copy()
    out[np.isnan(feat[:, :1]).repeat(BINS, 1)] = np.nan
    return out, np.array([transpose_class(c, semitones) if c >= 0 else c for c in lab])


# MARK: model

def load_btc(btc_dir, checkpoint):
    sys.path.insert(0, btc_dir)
    from btc_model import BTC_model  # noqa: E402
    cfg = yaml.safe_load(open(os.path.join(btc_dir, "run_config.yaml")))
    model_cfg = dict(cfg["model"])
    model_cfg["num_chords"] = 170
    model = BTC_model(config=model_cfg)
    ckpt = torch.load(checkpoint, map_location="cpu", weights_only=False)
    model.load_state_dict(ckpt["model"])
    return model, float(ckpt["mean"]), float(ckpt["std"])


def to_tensor(batch, mean, std):
    feats = np.stack([f for f, _ in batch])
    feats = np.where(np.isnan(feats), mean, feats)          # padding normalises to 0, like BTC
    x = torch.tensor((feats - mean) / std, dtype=torch.float32)
    y = torch.tensor(np.stack([l for _, l in batch]), dtype=torch.long)
    return x, y


def logits(model, x):
    hidden, _ = model.self_attn_layers(x)
    return model.output_layer.output_projection(hidden)


def accuracy(model, data, mean, std, batch_size=32):
    model.eval()
    correct = total = 0
    with torch.no_grad():
        for i in range(0, len(data), batch_size):
            x, y = to_tensor(data[i:i + batch_size], mean, std)
            pred = logits(model, x).argmax(-1)
            mask = y >= 0
            correct += (pred[mask] == y[mask]).sum().item()
            total += mask.sum().item()
    return correct / max(total, 1)


# MARK: main

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--btc", required=True, help="BTC-ISMIR19 checkout (for the model code and weights)")
    p.add_argument("--audio", required=True)
    p.add_argument("--labels", required=True)
    p.add_argument("--out", required=True, help="where to save the fine-tuned checkpoint (.pt)")
    p.add_argument("--init", help="checkpoint to start from (default: BTC's large-vocabulary weights)")
    p.add_argument("--epochs", type=int, default=20)
    p.add_argument("--lr", type=float, default=1e-4)
    p.add_argument("--batch-size", type=int, default=16)
    p.add_argument("--shifts", default="-5,6", help="pitch-shift range in semitones, e.g. -5,6 or 0,0")
    p.add_argument("--val-fraction", type=float, default=0.2)
    p.add_argument("--freeze-layers", type=int, default=0,
                   help="keep the first N of BTC's 8 attention layers fixed (less overfitting on small data)")
    p.add_argument("--seed", type=int, default=0)
    args = p.parse_args()

    random.seed(args.seed); np.random.seed(args.seed); torch.manual_seed(args.seed)
    init = args.init or os.path.join(args.btc, "test", "btc_model_large_voca.pt")
    model, mean, std = load_btc(args.btc, init)

    names = sorted(os.path.splitext(f)[0] for f in os.listdir(args.labels) if f.endswith(".lab"))
    songs = []
    for name in names:
        audio = next((os.path.join(args.audio, name + e) for e in AUDIO_EXT
                      if os.path.exists(os.path.join(args.audio, name + e))), None)
        if audio:
            songs.append((name, audio, os.path.join(args.labels, name + ".lab")))
        else:
            print(f"skipping {name}: no audio file")
    if len(songs) < 2:
        sys.exit("need at least 2 songs (one for validation)")
    random.shuffle(songs)
    n_val = max(1, int(round(len(songs) * args.val_fraction)))
    val_songs, train_songs = songs[:n_val], songs[n_val:]
    print(f"{len(train_songs)} training songs, {len(val_songs)} validation songs: "
          f"{', '.join(s[0] for s in val_songs)}")

    basis = cqt_mirror.kernels(0.0)
    train = [inst for _, a, l in train_songs for inst in load_song(a, l, basis)]
    val = [inst for _, a, l in val_songs for inst in load_song(a, l, basis)]
    lo, hi = (int(v) for v in args.shifts.split(","))
    train = [shift(f, l, k) for f, l in train for k in range(lo, hi + 1)]
    print(f"{len(train)} training instances (with pitch shifts {lo}..{hi}), {len(val)} validation instances")

    for layer in model.self_attn_layers.self_attn_layers[:args.freeze_layers]:
        for param in layer.parameters():
            param.requires_grad = False
    optimizer = torch.optim.Adam([q for q in model.parameters() if q.requires_grad],
                                 lr=args.lr, betas=(0.9, 0.98), eps=1e-9)

    best = accuracy(model, val, mean, std)
    print(f"validation frame accuracy before fine-tuning: {100 * best:.1f}%")
    best_state = {k: v.clone() for k, v in model.state_dict().items()}

    for epoch in range(1, args.epochs + 1):
        model.train()
        random.shuffle(train)
        losses = []
        for i in range(0, len(train), args.batch_size):
            x, y = to_tensor(train[i:i + args.batch_size], mean, std)
            loss = F.cross_entropy(logits(model, x).reshape(-1, 170), y.reshape(-1), ignore_index=-100)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            losses.append(loss.item())
        acc = accuracy(model, val, mean, std)
        marker = ""
        if acc > best:
            best, marker = acc, "  (best so far)"
            best_state = {k: v.clone() for k, v in model.state_dict().items()}
        print(f"epoch {epoch:3d}  loss {np.mean(losses):.3f}  validation accuracy {100 * acc:.1f}%{marker}")

    torch.save({"model": best_state, "mean": mean, "std": std}, args.out)
    print(f"saved the best checkpoint ({100 * best:.1f}% validation frame accuracy) to {args.out}")


if __name__ == "__main__":
    main()
