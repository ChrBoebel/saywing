#!/usr/bin/env python3
"""Deterministic, seeded conversations for the diarization evaluation.

  python3 scenarios.py --work /tmp/claude/diar-eval plan --split dev   # writes <split>-manifest.json
  python3 scenarios.py --work /tmp/claude/diar-eval render --split dev # writes the audio

A manifest fully describes every conversation: who speaks when, which part of the
speaker's file, at what level. Rendering it again gives the same audio. Each
conversation is rendered in three conditions:

  clean8   the mix at the model's 8 kHz, fed as is;
  clean48  the same mix, fed at 48 kHz through the app's resampler;
  call48   a call: band-limited to 300-3400 Hz, an AAC round trip at 20 kbit/s,
           light noise (25 dB SNR), fed at 48 kHz through the app's resampler.

The harness upsamples the 16 kHz files to 48 kHz before feeding them.
"""
import argparse
import hashlib
import json
import pathlib
import random
import subprocess
import tempfile

import numpy as np
from scipy import signal

from audio import RATE, read_wav, speech_mask, write_wav

SEED = 'saywing-diarization-eval-2026-11'
TURNS = {'long': (10.0, 20.0), 'medium': (4.0, 8.0), 'short': (1.5, 4.0)}
HUMAN_CONVERSATIONS = 60
SYSTEM_CONVERSATIONS = 12
SIMILAR_F0 = 20.0     # Hz between the medians of a "similar" pair, same gender
SKIP_HEAD, SKIP_TAIL = 25.0, 20.0  # LibriVox announcements
TARGET_RMS = 0.07


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def load_split(work, split):
    corpus = {e['id']: e for e in json.loads((work / 'corpus.json').read_text())}
    ids = json.loads((work / f'{split}-speakers.json').read_text())
    return [corpus[i] for i in ids]


def similar_pairs(pool):
    pairs = []
    for i, a in enumerate(pool):
        for b in pool[i + 1:]:
            if a['gender'] == b['gender'] and abs(a['f0_median'] - b['f0_median']) <= SIMILAR_F0:
                pairs.append((abs(a['f0_median'] - b['f0_median']), a['id'], b['id']))
    return sorted(pairs)


def plan_turns(rng, speakers, turn_class, duration, overlap_rate):
    """Turns until `duration`: every speaker early on, then random, never twice in a row."""
    low, high = TURNS[turn_class]
    order = list(speakers)
    rng.shuffle(order)
    turns, clock, previous = [], 0.0, None
    while clock < duration:
        if len(turns) < len(order):
            speaker = order[len(turns)]
        else:
            speaker = rng.choice([s for s in speakers if s != previous])
        length = round(rng.uniform(low, high), 2)
        if turns:
            if rng.random() < overlap_rate:
                shift = -min(rng.uniform(0.2, 1.2), 0.4 * min(length, turns[-1]['end'] - turns[-1]['start']))
            elif rng.random() < 0.15:
                shift = rng.uniform(1.5, 4.0)
            else:
                shift = rng.uniform(0.15, 1.0)
            clock = turns[-1]['end'] + shift
        start = round(clock, 3)
        turns.append({'speaker': speaker, 'start': start, 'end': round(start + length, 3)})
        clock = start + length
        previous = speaker
    # Every speaker speaks at least twice, so a returning voice is tested too.
    counts = {s: sum(t['speaker'] == s for t in turns) for s in speakers}
    for speaker in speakers:
        while counts[speaker] < 2:
            start = round(turns[-1]['end'] + rng.uniform(0.15, 1.0), 3)
            if turns[-1]['speaker'] == speaker:
                break
            turns.append({'speaker': speaker, 'start': start, 'end': round(start + rng.uniform(low, high), 3)})
            counts[speaker] += 1
    return turns


def plan(work, split):
    rng = random.Random(f'{SEED}:{split}')
    pool = load_split(work, split)
    humans = [e for e in pool if e['kind'] == 'librivox']
    systems = [e for e in pool if e['kind'] == 'say']
    by_language = {}
    for e in humans:
        by_language.setdefault(e['language'], []).append(e)
    conversations = []
    for index in range(HUMAN_CONVERSATIONS):
        count = 2 + index % 4
        turn_class = ['long', 'medium', 'short'][(index // 4) % 3]
        similar = (index // 12) % 5 in (0, 2)  # 24 of 60, spread over counts and turn lengths
        language = ['de', 'en'][(index // 2) % 2]
        candidates = by_language[language]
        chosen = []
        if similar:
            pairs = similar_pairs(candidates)
            if not pairs:
                raise SystemExit(f'{split}: no similar pair in {language}')
            _, a, b = rng.choice(pairs[:max(3, len(pairs) // 3)])
            chosen = [a, b]
        rest = [e['id'] for e in candidates if e['id'] not in chosen]
        rng.shuffle(rest)
        chosen += rest[:count - len(chosen)]
        if len(chosen) < count:
            raise SystemExit(f'{split}: only {len(chosen)} {language} speakers')
        conversations.append(conversation(rng, f'{split}-{index + 1:03d}', chosen, turn_class, similar, 'human', language))
    for index in range(SYSTEM_CONVERSATIONS):
        count = [2, 3, 3, 4][index % 4]
        language = ['de', 'en'][index % 2]
        candidates = [e['id'] for e in systems if e['language'] == language]
        rng.shuffle(candidates)
        chosen = candidates[:min(count, len(candidates))]
        turn_class = ['medium', 'short', 'long'][(index // 2) % 3]
        conversations.append(conversation(rng, f'{split}-sys-{index + 1:03d}', chosen, turn_class, False, 'system', language))
    corpus = {e['id']: e for e in pool}
    manifest = {
        'split': split, 'seed': SEED, 'generator': 'scripts/diarization-eval/scenarios.py',
        'speakers': [{k: corpus[i][k] for k in ('id', 'kind', 'reader', 'language', 'gender', 'f0_median', 'wav_sha256')}
                     for i in sorted(corpus)],
        'conversations': conversations,
    }
    path = work / f'{split}-manifest.json'
    if path.exists():
        raise SystemExit(f'{path} exists; manifests are written once')
    path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + '\n')
    (work / f'{split}-manifest.json.sha256').write_text(f'{sha256(path)}  {path.name}\n')
    print(split, len(conversations), 'conversations', sha256(path))


def conversation(rng, cid, speakers, turn_class, similar, kind, language):
    duration = round(rng.uniform(60, 240), 1)
    overlap_rate = rng.uniform(0.0, 0.3)
    turns = plan_turns(rng, speakers, turn_class, duration, overlap_rate)
    gains = {s: round(rng.uniform(-3, 3), 2) for s in speakers}
    seeds = {s: rng.randrange(1 << 30) for s in speakers}
    return {'id': cid, 'kind': kind, 'speakers': speakers, 'count': len(speakers), 'turns_class': turn_class,
            'similar_pair': similar, 'gain_db': gains, 'source_seed': seeds, 'turns': turns,
            'language': language}


def level(samples):
    mask = np.repeat(speech_mask(samples), int(0.02 * RATE))
    voiced = samples[:len(mask)][mask[:len(samples)]]
    return float(np.sqrt(np.mean(voiced ** 2))) if len(voiced) else 1.0


def mix(work, conv, cache):
    """The 16 kHz mix and the stretch of source audio each turn used."""
    end = max(t['end'] for t in conv['turns'])
    out = np.zeros(int(end * RATE) + RATE // 2, dtype=np.float64)
    cursors = {}
    for speaker in conv['speakers']:
        if speaker not in cache:
            samples = read_wav(work / 'speakers' / f'{speaker}.wav')
            body = samples[int(SKIP_HEAD * RATE):len(samples) - int(SKIP_TAIL * RATE)]
            if len(body) < 30 * RATE:
                body = samples
            cache[speaker] = (body / level(body) * TARGET_RMS).astype(np.float32)
        cursors[speaker] = random.Random(conv['source_seed'][speaker]).randrange(len(cache[speaker]))
    for turn in conv['turns']:
        speaker = turn['speaker']
        body = cache[speaker]
        count = int(round((turn['end'] - turn['start']) * RATE))
        piece = np.take(body, np.arange(cursors[speaker], cursors[speaker] + count), mode='wrap')
        cursors[speaker] = (cursors[speaker] + count) % len(body)
        start = int(round(turn['start'] * RATE))
        out[start:start + count] += piece * 10 ** (conv['gain_db'][speaker] / 20)
    return out.astype(np.float32)


def call(samples, rng):
    sos = signal.butter(4, [300, 3400], btype='bandpass', fs=RATE, output='sos')
    band = signal.sosfilt(sos, samples).astype(np.float32)
    with tempfile.TemporaryDirectory() as folder:
        source, coded, back = (pathlib.Path(folder) / n for n in ('in.wav', 'coded.m4a', 'back.wav'))
        write_wav(source, band)
        subprocess.run(['afconvert', '-f', 'm4af', '-d', 'aac', '-b', '20000', str(source), str(coded)], check=True)
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEF32', str(coded), str(back)], check=True)
        decoded = read_wav(back)
    # Undo any codec delay so the reference times still hold.
    window = min(len(band), 30 * RATE)
    corr = signal.correlate(decoded[:window + 4096], band[:window], mode='valid', method='fft')
    delay = int(np.argmax(corr[:4096]))
    decoded = decoded[delay:delay + len(band)]
    decoded = np.pad(decoded, (0, len(band) - len(decoded)))
    speech = level(band)
    noise = rng.standard_normal(len(decoded)).astype(np.float32)
    noise = signal.lfilter([0.049922035, -0.095993537, 0.050612699, -0.004408786],
                           [1, -2.494956002, 2.017265875, -0.522189400], noise).astype(np.float32)  # pink
    noise *= speech / np.sqrt(np.mean(noise ** 2)) * 10 ** (-25 / 20)
    return decoded + noise, delay


def render(work, split, only=None):
    manifest = json.loads((work / f'{split}-manifest.json').read_text())
    folder = work / 'audio' / split
    folder.mkdir(parents=True, exist_ok=True)
    cache = {}
    for conv in manifest['conversations']:
        if only and conv['id'] not in only:
            continue
        mixed = mix(work, conv, cache)
        peak = np.max(np.abs(mixed))
        if peak > 0.99:
            mixed *= 0.99 / peak
        write_wav(folder / f"{conv['id']}.clean8.wav", signal.resample_poly(mixed, 1, 2), 8000)
        write_wav(folder / f"{conv['id']}.clean16.wav", mixed)
        degraded, delay = call(mixed, np.random.default_rng(int(hashlib.sha256(conv['id'].encode()).hexdigest()[:8], 16)))
        peak = np.max(np.abs(degraded))
        write_wav(folder / f"{conv['id']}.call16.wav", degraded * (0.99 / peak if peak > 0.99 else 1))
        print(conv['id'], f'{len(mixed) / RATE:.0f}s', f'codec delay {delay}', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work', type=pathlib.Path, required=True)
    parser.add_argument('step', choices=['plan', 'render'])
    parser.add_argument('--split', choices=['dev', 'test'], required=True)
    parser.add_argument('--only', nargs='*')
    args = parser.parse_args()
    if args.step == 'plan':
        plan(args.work, args.split)
    else:
        render(args.work, args.split, set(args.only or []))


if __name__ == '__main__':
    main()
