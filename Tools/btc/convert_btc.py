"""Convert BTC (Bi-directional Transformer for Chord recognition, Park et al. 2019) to Core ML.

    git clone https://github.com/jayg996/BTC-ISMIR19.git      # MIT licence, includes weights
    pip install torch coremltools librosa pyyaml numpy
    python convert_btc.py --btc ./BTC-ISMIR19 --out ../../ChordDetectionPOC/Models
    # or a model you fine-tuned with finetune_btc.py:
    python convert_btc.py --btc ./BTC-ISMIR19 --checkpoint btc_finetuned.pt --out ../../ChordDetectionPOC/Models

Writes:
  BTCChords.mlpackage  input  "logcqt"   [1, 108, 144]  log(|CQT| + 1e-6), NOT normalised
                       output "logprobs" [1, 108, 170]  log-softmax over BTC's large vocabulary
  BTCKernels.bin       the sparse CQT filter bank used by ChordDetectionPOC/Engine/ConstantQ.swift

The feature normalisation (mean/std from the checkpoint) is baked into the model, so the app only
computes the log-CQT. Pad partial windows with the checkpoint mean (printed below), which
normalises to 0 exactly like BTC's own zero padding.

Output classes: index = root * 14 + quality for roots C..B and qualities
  min maj dim aug min6 maj6 min7 minmaj7 maj7 7 dim7 hdim7 sus2 sus4
then 168 = X (unknown chord) and 169 = N (no chord).
"""
import argparse
import os
import struct
import sys

import numpy as np
import torch
import torch.nn as nn
import yaml

import cqt_mirror

np.float = float  # BTC uses the removed np.float alias


T, D, HEADS = 108, 128, 4


def layer_norm(ln, x):
    # BTC's LayerNorm: unbiased std, eps added to the std (not the variance).
    mean = x.mean(-1, keepdim=True)
    var = ((x - mean) ** 2).sum(-1, keepdim=True) / (x.shape[-1] - 1)
    return ln.gamma * (x - mean) / (torch.sqrt(var) + ln.eps) + ln.beta


def attention(mha, x, mask):
    def heads(t):
        return t.reshape(1, T, HEADS, D // HEADS).permute(0, 2, 1, 3)
    q = heads(mha.query_linear(x)) * mha.query_scale
    k = heads(mha.key_linear(x))
    v = heads(mha.value_linear(x))
    w = torch.softmax(torch.matmul(q, k.permute(0, 1, 3, 2)) + mask, dim=-1)
    ctx = torch.matmul(w, v).permute(0, 2, 1, 3).reshape(1, T, D)
    return mha.output_linear(ctx)


def feed_forward(ffn, x):
    for layer in ffn.layers:                      # two kernel-3 convs, ReLU after each
        y = layer.pad(x.permute(0, 2, 1))
        x = torch.relu(layer.conv(y).permute(0, 2, 1))
    return x


def block(blk, x, mask):
    x = x + attention(blk.multi_head_attention, layer_norm(blk.layer_norm_mha, x), mask)
    return x + feed_forward(blk.positionwise_convolution, layer_norm(blk.layer_norm_ffn, x))


class BTCForCoreML(nn.Module):
    """BTC's forward pass rewritten with fixed shapes (batch 1, 108 frames) so it traces into a
    graph coremltools can convert. Uses the original modules' weights; checked against the
    original implementation below."""

    def __init__(self, btc, mean, std):
        super().__init__()
        self.btc = btc
        self.mean = float(mean)
        self.std = float(std)
        layers = btc.self_attn_layers
        self.register_buffer("timing", layers.timing_signal[:, :T, :].clone())
        fwd = torch.triu(torch.full((T, T), -1e4), 1)       # forward block can't see the future
        self.register_buffer("mask_fwd", fwd.view(1, 1, T, T))
        self.register_buffer("mask_bwd", fwd.t().contiguous().view(1, 1, T, T))

    def forward(self, logcqt):
        layers = self.btc.self_attn_layers
        x = layers.embedding_proj((logcqt - self.mean) / self.std) + self.timing
        for layer in layers.self_attn_layers:
            f = block(layer.attn_block, x, self.mask_fwd)
            b = block(layer.backward_attn_block, x, self.mask_bwd)
            x = layer.linear(torch.cat((f, b), dim=2))
        x = layer_norm(layers.layer_norm, x)
        return torch.log_softmax(self.btc.output_layer.output_projection(x), dim=-1)


def reference_logprobs(btc, mean, std, logcqt):
    hidden, _ = btc.self_attn_layers((logcqt - mean) / std)
    return torch.log_softmax(btc.output_layer.output_projection(hidden), dim=-1)


def load_btc(btc_dir, checkpoint=None):
    sys.path.insert(0, btc_dir)
    from btc_model import BTC_model  # noqa: E402

    cfg = yaml.safe_load(open(os.path.join(btc_dir, "run_config.yaml")))
    model_cfg = dict(cfg["model"])
    model_cfg["num_chords"] = 170
    model = BTC_model(config=model_cfg).eval()
    ckpt = torch.load(checkpoint or os.path.join(btc_dir, "test", "btc_model_large_voca.pt"),
                      map_location="cpu", weights_only=False)
    model.load_state_dict(ckpt["model"])

    return model, float(ckpt["mean"]), float(ckpt["std"])


def write_kernels(path):
    basis, n_fft, lengths = cqt_mirror.kernels(0.0)
    with open(path, "wb") as f:
        f.write(b"BTCK")
        f.write(struct.pack("<iii", 1, n_fft, basis.shape[0]))
        f.write(np.asarray(lengths, dtype="<f4").tobytes())
        for row in basis:
            idx = np.nonzero(row)[0]
            f.write(struct.pack("<i", len(idx)))
            f.write(idx.astype("<i4").tobytes())
            f.write(row[idx].real.astype("<f4").tobytes())
            f.write(row[idx].imag.astype("<f4").tobytes())
    print(f"wrote {path}: n_fft={n_fft}, bins={basis.shape[0]}, nonzeros={(basis != 0).sum()}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--btc", required=True, help="path to a BTC-ISMIR19 checkout")
    parser.add_argument("--out", required=True, help="output directory")
    parser.add_argument("--checkpoint", help="checkpoint to convert (default: BTC's large-vocabulary weights)")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    import coremltools as ct

    btc, mean, std = load_btc(args.btc, args.checkpoint)
    wrapper = BTCForCoreML(btc, mean, std).eval()
    print(f"checkpoint feature mean={mean!r} std={std!r}")

    example = torch.randn(1, T, 144) * std + mean
    with torch.no_grad():
        diff = (wrapper(example) - reference_logprobs(btc, mean, std, example)).abs().max().item()
        print(f"rewritten vs original BTC max abs diff: {diff:.2e}")
        assert diff < 1e-3, "rewritten forward pass doesn't match BTC"
        traced = torch.jit.trace(wrapper, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="logcqt", shape=(1, T, 144), dtype=np.float32)],
        outputs=[ct.TensorType(name="logprobs", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.short_description = "BTC chord recognition (Park et al., ISMIR 2019), large vocabulary."
    mlmodel.author = "Jonggwon Park et al. (MIT licence); converted for ChordDetectionPOC"
    mlmodel.user_defined_metadata["feature_mean"] = repr(mean)
    mlmodel.user_defined_metadata["feature_std"] = repr(std)
    mlmodel.save(os.path.join(args.out, "BTCChords.mlpackage"))
    print("wrote BTCChords.mlpackage")

    write_kernels(os.path.join(args.out, "BTCKernels.bin"))


if __name__ == "__main__":
    main()
