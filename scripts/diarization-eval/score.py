#!/usr/bin/env python3
"""Scores what the harness reported against the scenario manifest.

  python3 score.py --manifest <split>-manifest.json --results results.jsonl --out summary.json

Readers and voices are paired one to one by the Hungarian method, maximising shared
time. On a 10 ms grid:

  correct    share of attributed time (time a voice is reported) that lies in a turn
             of its paired reader (a turn includes the reader's short pauses);
  coverage   share of reference speech covered by any voice;
  confusion  speaker confusion as in DER: speech time given to the wrong voice,
             over total reference speaker time;
  der        missed + false alarm + confusion, over total reference speaker time,
             no collar.

Reference speech for coverage, confusion and DER is a turn where the clean mix is
within 35 dB of its loud frames, so the pauses inside a turn do not count as missed.
  exact      the conversation was given exactly as many voices as it has readers.

Label lag is how much audio had been fed when a span arrived, minus its end.
"""
import argparse
import json
import pathlib
import statistics

import numpy as np
from scipy.optimize import linear_sum_assignment

from audio import read_wav, speech_mask

STEP = 0.01


def grid(intervals, length):
    active = np.zeros(length, dtype=bool)
    for start, end in intervals:
        active[max(0, int(round(start / STEP))):max(0, int(round(end / STEP)))] = True
    return active


def voiced(audio, length):
    """Speech activity of the clean 16 kHz mix on the scoring grid, cached beside it."""
    cache = audio.with_suffix('.vad.npy')
    if cache.exists():
        mask = np.load(cache)
    else:
        mask = speech_mask(read_wav(audio), hop=STEP)
        np.save(cache, mask)
    out = np.zeros(length, dtype=bool)
    out[:min(length, len(mask))] = mask[:length]
    return out


def score_run(conv, result, audio):
    length = int(np.ceil(max(result['duration'], max(t['end'] for t in conv['turns'])) / STEP)) + 1
    speakers = conv['speakers']
    turns = np.stack([grid([(t['start'], t['end']) for t in conv['turns'] if t['speaker'] == s], length) for s in speakers])
    ref = turns & voiced(audio, length)[None, :]
    voices = sorted({int(v) for v, _, _ in result['spans']})
    hyp = np.stack([grid([(s, e) for v, s, e in result['spans'] if int(v) == voice], length) for voice in voices]) \
        if voices else np.zeros((0, length), dtype=bool)
    shared = (turns[:, None, :] & hyp[None, :, :]).sum(axis=2) * STEP if voices else np.zeros((len(speakers), 0))
    rows, cols = linear_sum_assignment(-shared) if voices else ([], [])
    mapping = {int(r): int(c) for r, c in zip(rows, cols) if shared[r, c] > 0}
    attributed = hyp.sum() * STEP
    correct = sum(shared[r, c] for r, c in mapping.items())
    n_ref = ref.sum(axis=0)
    n_hyp = hyp.sum(axis=0)
    n_correct = np.zeros(length, dtype=int)
    for r, c in mapping.items():
        n_correct += ref[r] & hyp[c]
    speech = n_ref > 0
    total = n_ref.sum() * STEP
    missed = np.maximum(n_ref - n_hyp, 0).sum() * STEP
    false_alarm = np.maximum(n_hyp - n_ref, 0).sum() * STEP
    confusion = (np.minimum(n_ref, n_hyp) - n_correct).sum() * STEP
    lags = result['lags']
    return {
        'run': result['run'], 'id': conv['id'], 'condition': result['run'].split('.')[-1],
        'kind': conv['kind'], 'count': conv['count'], 'turns_class': conv['turns_class'],
        'similar_pair': conv['similar_pair'], 'duration': result['duration'],
        'attributed': attributed, 'correct': correct, 'speech': speech.sum() * STEP,
        'covered': (speech & (n_hyp > 0)).sum() * STEP, 'speaker_time': total,
        'missed': missed, 'false_alarm': false_alarm, 'confusion': confusion,
        'voices': len(voices), 'exact': len(voices) == conv['count'],
        'share': correct / attributed if attributed else 0.0,
        'lag_median': statistics.median(lags) if lags else None, 'lags': lags,
        'rtf': result['real_time_factor'], 'peak_mb': result['peak_footprint_mb'],
        'failure': result.get('failure'),
    }


GROUPS = {
    'all': lambda r: True,
    'human 2-3, no similar pair': lambda r: r['kind'] == 'human' and r['count'] <= 3 and not r['similar_pair'],
    'human 2-3, similar pair': lambda r: r['kind'] == 'human' and r['count'] <= 3 and r['similar_pair'],
    'human 4-5': lambda r: r['kind'] == 'human' and r['count'] >= 4,
    'human 4-5, similar pair': lambda r: r['kind'] == 'human' and r['count'] >= 4 and r['similar_pair'],
    'similar pair (all counts)': lambda r: r['similar_pair'],
    'system voices': lambda r: r['kind'] == 'system',
    'turns long': lambda r: r['kind'] == 'human' and r['turns_class'] == 'long',
    'turns medium': lambda r: r['kind'] == 'human' and r['turns_class'] == 'medium',
    'turns short': lambda r: r['kind'] == 'human' and r['turns_class'] == 'short',
    'clean8': lambda r: r['condition'] == 'clean8',
    'clean48': lambda r: r['condition'] == 'clean48',
    'call48': lambda r: r['condition'] == 'call48',
}


def aggregate(rows):
    if not rows:
        return None
    attributed = sum(r['attributed'] for r in rows)
    lags = sorted(l for r in rows for l in r['lags'])
    return {
        'runs': len(rows),
        'correct': sum(r['correct'] for r in rows) / attributed if attributed else 0.0,
        'correct_mean': statistics.mean(r['share'] for r in rows),
        'coverage': sum(r['covered'] for r in rows) / sum(r['speech'] for r in rows),
        'confusion': sum(r['confusion'] for r in rows) / sum(r['speaker_time'] for r in rows),
        'der': sum(r['missed'] + r['false_alarm'] + r['confusion'] for r in rows) / sum(r['speaker_time'] for r in rows),
        'exact': sum(r['exact'] for r in rows) / len(rows),
        'fewer_voices': sum(r['voices'] < r['count'] for r in rows) / len(rows),
        'more_voices': sum(r['voices'] > r['count'] for r in rows) / len(rows),
        'lag_median': lags[len(lags) // 2] if lags else None,
        'lag_p90': lags[int(len(lags) * 0.9)] if lags else None,
        'rtf_median': statistics.median(r['rtf'] for r in rows),
        'peak_mb_max': max(r['peak_mb'] for r in rows),
        'failures': sum(bool(r['failure']) for r in rows),
    }


def table(summary):
    lines = ['| Group | Runs | Correct | Mean | Coverage | Confusion | DER | Exact count | Fewer | More | Lag median | Lag p90 |',
             '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
    for name, g in summary.items():
        if g is None:
            continue
        lines.append(f"| {name} | {g['runs']} | {g['correct'] * 100:.1f} | {g['correct_mean'] * 100:.1f} | "
                     f"{g['coverage'] * 100:.1f} | {g['confusion'] * 100:.1f} | {g['der'] * 100:.1f} | "
                     f"{g['exact'] * 100:.0f} | {g['fewer_voices'] * 100:.0f} | {g['more_voices'] * 100:.0f} | "
                     f"{g['lag_median']:.2f} | {g['lag_p90']:.2f} |")
    g = summary['all']
    lines.append(f"\nReal-time factor median {g['rtf_median']:.4f}, peak footprint {g['peak_mb_max']:.0f} MB, failures {g['failures']}.")
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', type=pathlib.Path, required=True)
    parser.add_argument('--results', type=pathlib.Path, required=True)
    parser.add_argument('--audio', type=pathlib.Path, required=True, help='folder of <id>.clean16.wav')
    parser.add_argument('--out', type=pathlib.Path)
    args = parser.parse_args()
    conversations = {c['id']: c for c in json.loads(args.manifest.read_text())['conversations']}
    rows = []
    for line in args.results.read_text().splitlines():
        result = json.loads(line)
        cid = result['run'].rsplit('.', 1)[0]
        rows.append(score_run(conversations[cid], result, args.audio / f'{cid}.clean16.wav'))
    summary = {name: aggregate([r for r in rows if keep(r)]) for name, keep in GROUPS.items()}
    print(table(summary))
    if args.out:
        for r in rows:
            r.pop('lags')
        args.out.write_text(json.dumps({'summary': summary, 'runs': rows}, indent=1) + '\n')


if __name__ == '__main__':
    main()
