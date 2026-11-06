#!/usr/bin/env python3
"""Runs the harness over one split and scores it.

  python3 evaluate.py --work /tmp/claude/diar-eval --split dev --label baseline \\
      --model /path/nemotron-3   # a folder from scripts/fetch-diarization-model.py

Results land in <work>/runs/<label>-<split>.{jsonl,json,md}. Runs on the test split
are logged in <work>/test-runs.log, and a fourth one is refused: the test set is for
final candidates only.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import subprocess
import sys

import score

HERE = pathlib.Path(__file__).resolve().parent
CONDITIONS = {'clean8': ('clean8', None), 'clean48': ('clean16', 48000), 'call48': ('call16', 48000)}
TEST_RUN_LIMIT = 3


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work', type=pathlib.Path, required=True)
    parser.add_argument('--split', choices=['dev', 'test'], required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--model', type=pathlib.Path, required=True)
    parser.add_argument('--conditions', nargs='*', default=list(CONDITIONS))
    parser.add_argument('--binary', type=pathlib.Path,
                        default=pathlib.Path('/tmp/claude/diar-eval/build/release/diarization-eval'))
    parser.add_argument('--only', nargs='*', help='conversation ids (dev only)')
    parser.add_argument('--rescore', action='store_true', help='score existing results again (dev only)')
    args = parser.parse_args()
    manifest_path = args.work / f'{args.split}-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    digest = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    recorded = (args.work / f'{args.split}-manifest.json.sha256').read_text().split()[0]
    if digest != recorded:
        raise SystemExit(f'{manifest_path} changed after it was written')
    if args.split == 'test' and not args.rescore:
        if args.only:
            raise SystemExit('the test split is always run whole')
        log = args.work / 'test-runs.log'
        done = log.read_text().splitlines() if log.exists() else []
        if len(done) >= TEST_RUN_LIMIT:
            raise SystemExit(f'{len(done)} test runs already: {done}')
        with log.open('a') as handle:
            handle.write(f'{datetime.datetime.now().isoformat(timespec="seconds")} {args.label} {digest}\n')
    runs = []
    for conv in manifest['conversations']:
        if args.only and conv['id'] not in args.only:
            continue
        for condition in args.conditions:
            stem, rate = CONDITIONS[condition]
            entry = {'run': f"{conv['id']}.{condition}",
                     'audio': str(args.work / 'audio' / args.split / f"{conv['id']}.{stem}.wav")}
            if rate:
                entry['feedRate'] = rate
            runs.append(entry)
    out = args.work / 'runs'
    out.mkdir(exist_ok=True)
    plan = out / f'{args.label}-{args.split}.plan.json'
    plan.write_text(json.dumps(runs, indent=1))
    results = out / f'{args.label}-{args.split}.jsonl'
    if not args.rescore:
        subprocess.run([str(args.binary), '--model', str(args.model), '--plan', str(plan), '--out', str(results)],
                       check=True, stdout=subprocess.DEVNULL if len(runs) > 20 else None)
    rows = []
    conversations = {c['id']: c for c in manifest['conversations']}
    for line in results.read_text().splitlines():
        result = json.loads(line)
        cid = result['run'].rsplit('.', 1)[0]
        rows.append(score.score_run(conversations[cid], result, args.work / 'audio' / args.split / f'{cid}.clean16.wav'))
    summary = {name: score.aggregate([r for r in rows if keep(r)]) for name, keep in score.GROUPS.items()}
    text = f'# {args.label} on {args.split}\n\nModel `{args.model.name}`, manifest SHA-256 `{digest}`.\n\n' + score.table(summary)
    (out / f'{args.label}-{args.split}.md').write_text(text + '\n')
    for r in rows:
        r.pop('lags')
    (out / f'{args.label}-{args.split}.json').write_text(json.dumps({'summary': summary, 'runs': rows}, indent=1) + '\n')
    print(text)


if __name__ == '__main__':
    sys.path.insert(0, str(HERE))
    main()
