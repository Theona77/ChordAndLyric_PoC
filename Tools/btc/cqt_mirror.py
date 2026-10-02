"""Single-rate constant-Q transform matching the features BTC was trained on.

librosa computes its CQT octave by octave with resampling; this computes the same filter bank
directly at 22050 Hz. On BTC's example song the model's predictions from these features agree
with predictions from librosa.cqt on 99.1% of frames. The Swift `ConstantQ` type uses the
kernels exported from here (see convert_btc.py), so the two stay identical.

Settings are BTC's: 22050 Hz, hop 2048, 144 bins from C1, 24 bins/octave, tuning 0
(librosa's default, also in 0.6.3 which BTC was trained with).
"""
import numpy as np

SR = 22050; HOP = 2048; N_BINS = 144; BPO = 24
FMIN_C1 = 32.70319566257483

def filter_lengths(freqs):
    logf = np.log2(freqs)
    bpo = np.empty_like(freqs)
    bpo[0] = 1 / (logf[1] - logf[0]); bpo[-1] = 1 / (logf[-1] - logf[-2])
    bpo[1:-1] = 2 / (logf[2:] - logf[:-2])
    alpha = (2.0 ** (2 / bpo) - 1) / (2.0 ** (2 / bpo) + 1)
    Q = 1.0 / alpha
    return Q * SR / freqs

def kernels(tuning_bins=0.0, quantile=0.01):
    fmin = FMIN_C1 * 2.0 ** (tuning_bins / BPO)
    freqs = fmin * 2.0 ** (np.arange(N_BINS) / BPO)
    lengths = filter_lengths(freqs)
    n_fft = int(2 ** np.ceil(np.log2(lengths.max())))
    rows = []
    for L, f in zip(lengths, freqs):
        n = np.arange(np.floor(-L / 2), np.floor(L / 2))       # == np.arange(-L//2, L//2)
        sig = np.exp(1j * 2 * np.pi * f / SR * n)
        sig *= hann_periodic(len(sig))
        sig /= np.abs(sig).sum()
        full = np.zeros(n_fft, complex)
        start = (n_fft - len(sig)) // 2
        full[start:start + len(sig)] = sig
        full *= L / n_fft
        F = np.fft.fft(full)[: n_fft // 2 + 1]
        # sparsify: drop the smallest magnitudes that together make up `quantile` of the row's L1 mass
        mag = np.abs(F); order = np.argsort(mag); csum = np.cumsum(mag[order]) / mag.sum()
        F[order[csum < quantile]] = 0
        rows.append(F)
    return np.array(rows), n_fft, lengths

def hann_periodic(n):
    # scipy.signal.get_window('hann', n, fftbins=True)
    return 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / n)

def cqt(y, tuning_bins=0.0, basis=None):
    B, n_fft, lengths = basis if basis is not None else kernels(tuning_bins)
    n_frames = 1 + len(y) // HOP
    pad = np.concatenate([np.zeros(n_fft // 2), y, np.zeros(n_fft // 2 + HOP)])
    out = np.empty((N_BINS, n_frames), complex)
    for t in range(n_frames):
        frame = pad[t * HOP: t * HOP + n_fft]
        X = np.fft.rfft(frame)
        out[:, t] = B @ X
    return out / np.sqrt(lengths)[:, None]
