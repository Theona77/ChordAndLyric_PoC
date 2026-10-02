#!/usr/bin/env python3
"""Score chord .lab files against references with the standard MIREX metrics (mir_eval).

    pip install mir_eval numpy
    python3 Tools/score.py --ref TestSet/labels results/templates results/basicPitch results/btc

Each results folder is compared song by song (matching file names) and summarised as
duration-weighted accuracy over all songs:

  root      chord root only (C, Cmaj7, Cm all count as "C")
  majmin    major/minor triads; other qualities are mapped to maj/min or excluded
  majmin_inv  majmin, and the bass note must match too (D/F# is not D)
  mirex     MIREX 2010: correct if it shares at least 3 pitch classes with the reference
  thirds    root and third
  sevenths  maj/min/7/maj7/min7 vocabulary
  tetrads   full four-note qualities

"N" (no chord) regions count like any other label for root/majmin/mirex.
"""
import argparse
import os
import sys

import mir_eval
import numpy as np

METRICS = ["root", "majmin", "majmin_inv", "mirex", "thirds", "sevenths", "tetrads"]


def load(path):
    intervals, labels = mir_eval.io.load_labeled_intervals(path)
    return intervals, labels


def score_song(ref_path, est_path):
    ref_int, ref_lab = load(ref_path)
    est_int, est_lab = load(est_path)
    end = ref_int.max()
    est_int, est_lab = mir_eval.util.adjust_intervals(est_int, est_lab, ref_int.min(), end,
                                                      mir_eval.chord.NO_CHORD, mir_eval.chord.NO_CHORD)
    intervals, ref, est = mir_eval.util.merge_labeled_intervals(ref_int, ref_lab, est_int, est_lab)
    durations = mir_eval.util.intervals_to_durations(intervals)

    scores = {}
    for metric in METRICS:
        comparison = getattr(mir_eval.chord, metric)(ref, est)
        valid = comparison >= 0                       # -1 = reference label excluded by this metric
        scores[metric] = (float(np.sum(durations[valid] * comparison[valid])), float(np.sum(durations[valid])))
    return scores


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ref", required=True, help="folder of reference .lab files")
    parser.add_argument("--per-song", action="store_true", help="also print every song's scores")
    parser.add_argument("results", nargs="+", help="one or more folders of estimated .lab files")
    args = parser.parse_args()

    refs = sorted(f for f in os.listdir(args.ref) if f.endswith(".lab"))
    if not refs:
        sys.exit(f"no .lab files in {args.ref}")

    header = f"{'results':<28}{'songs':>6}" + "".join(f"{m:>11}" for m in METRICS)
    print(header)
    print("-" * len(header))
    for folder in args.results:
        totals = {m: [0.0, 0.0] for m in METRICS}
        rows, missing = [], []
        for name in refs:
            est = os.path.join(folder, name)
            if not os.path.exists(est):
                missing.append(name)
                continue
            s = score_song(os.path.join(args.ref, name), est)
            rows.append((name, s))
            for m in METRICS:
                totals[m][0] += s[m][0]
                totals[m][1] += s[m][1]

        cells = "".join(f"{(100 * c / d if d else float('nan')):>10.1f}%" for c, d in (totals[m] for m in METRICS))
        print(f"{os.path.basename(os.path.normpath(folder)):<28}{len(rows):>6}{cells}")
        if args.per_song:
            for name, s in rows:
                cells = "".join(f"{(100 * c / d if d else float('nan')):>10.1f}%" for c, d in (s[m] for m in METRICS))
                print(f"  {name[:26]:<26}{'':>6}{cells}")
        if missing:
            print(f"  (missing {len(missing)}: {', '.join(missing[:5])}{'...' if len(missing) > 5 else ''})")


if __name__ == "__main__":
    main()
