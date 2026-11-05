#!/usr/bin/env python3
"""Offline exploration of post-processing on dumped model probabilities (dev only).

The harness's --dump mode writes the model's raw per-frame speaker probabilities.
This script turns them into voice spans with candidate rules and scores them, so
many variants can be compared in seconds. It is a sketch for choosing what to try:
every number reported as a result comes from the harness running the app's code.
"""
import argparse
import json
import pathlib
import sys

import numpy as np

import score

FRAME = 0.1


def load(dump, run):
    info = json.loads((dump / f'{run}.json').read_text())
    probs = np.fromfile(dump / f'{run}.f32', dtype=np.float32).reshape(-1, info['speakers'])
    return probs, info


def runs_of(active):
    """(start, end) frame ranges where `active` is true."""
    padded = np.concatenate([[False], active, [False]])
    edges = np.flatnonzero(padded[1:] != padded[:-1])
    return list(zip(edges[::2], edges[1::2]))


def hysteresis(p, onset, offset, min_on, min_off):
    """FluidAudio's per-speaker rule: open above onset, close below offset, drop
    stretches shorter than min_on, close gaps shorter than min_off."""
    out = np.zeros_like(p, dtype=bool)
    for s in range(p.shape[1]):
        speaking = False
        for t in range(p.shape[0]):
            if speaking:
                speaking = p[t, s] >= offset
            else:
                speaking = p[t, s] > onset
            out[t, s] = speaking
        segs = runs_of(out[:, s])
        merged = []
        for a, b in segs:
            if merged and a - merged[-1][1] <= min_off:
                merged[-1] = (merged[-1][0], b)
            else:
                merged.append((a, b))
        out[:, s] = False
        for a, b in merged:
            if b - a >= min_on:
                out[a:b, s] = True
    return out


def to_spans(active):
    spans = []
    for s in range(active.shape[1]):
        for a, b in runs_of(active[:, s]):
            spans.append([s, a * FRAME, b * FRAME])
    return spans


def baseline(p, **_):
    return hysteresis(p, 0.5, 0.5, 2, 5)


def smooth(p, width):
    if width <= 1:
        return p
    kernel = np.ones(width) / width
    # Causal moving average: frame t sees t-width+1 ... t, reported with that delay
    # (the caller accounts for it as lag, the spans keep their real times).
    padded = np.vstack([np.repeat(p[:1], width // 2, axis=0), p, np.repeat(p[-1:], width - 1 - width // 2, axis=0)])
    return np.stack([np.convolve(padded[:, s], kernel, mode='valid') for s in range(p.shape[1])], axis=1)


def dominant(p, threshold=0.5, second=1.1, min_off=5, min_on=2, width=1, confirm=0.0, hold=0):
    """One voice per frame: the most likely slot above `threshold`; a second slot
    only above `second` (true overlap). A slot is reported once it has `confirm`
    seconds of dominant speech; before that its frames go to the best confirmed
    slot. Gaps up to min_off frames of the same voice are closed, stretches under
    min_on dropped."""
    q = smooth(p, width)
    T, S = q.shape
    top = np.argmax(q, axis=1)
    best = q[np.arange(T), top]
    confirmed = np.zeros(S, dtype=bool)
    seen = np.zeros(S)
    label = np.full(T, -1)
    need = confirm / FRAME
    for t in range(T):
        if best[t] <= threshold:
            continue
        s = top[t]
        seen[s] += 1
        # The decision for frame t may wait `hold` frames: a slot confirmed by then counts.
        future = seen[s] + np.sum(top[t + 1:t + 1 + hold] == s) if hold else seen[s]
        if confirmed[s] or future >= need:
            if seen[s] >= need:
                confirmed[s] = True
            label[t] = s
        else:
            others = np.where(confirmed)[0]
            if len(others):
                label[t] = others[np.argmax(q[t, others])]
    active = np.zeros((T, S), dtype=bool)
    active[np.arange(T)[label >= 0], label[label >= 0]] = True
    if second <= 1:
        extra = (q > second) & ~active
        active |= extra
    out = np.zeros_like(active)
    for s in range(S):
        segs = runs_of(active[:, s])
        merged = []
        for a, b in segs:
            if merged and a - merged[-1][1] <= min_off:
                merged[-1] = (merged[-1][0], b)
            else:
                merged.append((a, b))
        for a, b in merged:
            if b - a >= min_on:
                out[a:b, s] = True
    return out


RULES = {'baseline': baseline, 'dominant': dominant, 'hysteresis': hysteresis}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work', type=pathlib.Path, required=True)
    parser.add_argument('--dump', type=pathlib.Path, required=True)
    parser.add_argument('--rule', default='baseline')
    parser.add_argument('--param', nargs='*', default=[], help='name=value')
    parser.add_argument('--detail', action='store_true')
    parser.add_argument('--brief', action='store_true', help='one line: correct/exact/fewer/more per group')
    args = parser.parse_args()
    manifest = json.loads((args.work / 'dev-manifest.json').read_text())
    params = {k: float(v) if '.' in v else int(v) for k, v in (p.split('=') for p in args.param)}
    rows = []
    for conv in manifest['conversations']:
        for path in sorted(args.dump.glob(f"{conv['id']}.*.json")):
            run = path.stem
            p, info = load(args.dump, run)
            active = RULES[args.rule](p, **params)
            spans = [s for s in to_spans(active) if s[1] < info['duration']]
            spans = [[v, a, min(b, info['duration'])] for v, a, b in spans]
            result = {'run': run, 'duration': info['duration'], 'spans': spans, 'lags': [0.0],
                      'real_time_factor': 0.0, 'peak_footprint_mb': 0.0}
            rows.append(score.score_run(conv, result, args.work / 'audio' / 'dev' / f"{conv['id']}.clean16.wav"))
    summary = {name: score.aggregate([r for r in rows if keep(r)]) for name, keep in score.GROUPS.items()}
    if args.brief:
        keys = [k for k in ['all', 'human 2-3, no similar pair', 'human 2-3, similar pair', 'human 4-5',
                            'system voices', 'turns short', 'call48'] if summary[k]]
        cells = [f"{summary[k]['correct'] * 100:5.1f}/{summary[k]['exact'] * 100:3.0f}/{summary[k]['fewer_voices'] * 100:2.0f}/{summary[k]['more_voices'] * 100:2.0f}"
                 for k in keys]
        print(f"{args.rule} {' '.join(args.param):40} | " + ' | '.join(cells), flush=True)
        return
    print(args.rule, params)
    print(score.table(summary))
    if args.detail:
        for r in rows:
            print(f"{r['run']:24} n={r['count']} voices={r['voices']} share={r['share'] * 100:.1f}")


if __name__ == '__main__':
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    main()
