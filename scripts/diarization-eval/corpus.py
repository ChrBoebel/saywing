#!/usr/bin/env python3
"""Builds the speaker corpus for the diarization evaluation, outside the repository.

Public-domain LibriVox readers (German and English multi-reader collections on
archive.org) and the installed macOS `say` voices. Every file is recorded with its
source URL, reader, licence and SHA-256 in `<work>/corpus.json`. Audio stays in
`<work>/speakers`; nothing here is committed or used by the app.

  python3 corpus.py --work /tmp/claude/diar-eval build
  python3 corpus.py --work /tmp/claude/diar-eval split   # once, before any tuning

Needs network access to librivox.org and archive.org, ffmpeg, numpy and scipy.
"""
import argparse
import hashlib
import json
import pathlib
import random
import re
import subprocess
import sys
import tempfile
import urllib.parse

import numpy as np

from audio import RATE, f0_median, read_wav, write_wav

SEED = 'saywing-diarization-eval-2026-11'
HEADERS = {'User-Agent': 'saywing-diarization-eval/1.0 (local evaluation)'}
API = 'https://librivox.org/api/feed/audiobooks/?format=json&extended=1&limit=100&title='
# Multi-reader collections: one reader per section.
COLLECTIONS = {
    'de': ['^Sammlung kurzer deutscher Prosa', '^Kinder- und Hausmärchen (1812'],
    'en': ['^Short Story Collection Vol'],
}
PER_GROUP = 12            # readers per (language, gender)
SECTION_RANGE = (240, 1500)
F0_SPLIT = 165.0          # Hz; below is labelled male, above female (an estimate)
# Speech-like system voices; the Eloquence voices are one persona per name.
SAY_VOICES = {
    'de_DE': ['Anna', 'Eddy', 'Flo', 'Grandma', 'Grandpa', 'Reed', 'Rocko', 'Sandy', 'Shelley'],
    'en_US': ['Samantha', 'Albert', 'Fred', 'Junior', 'Kathy', 'Ralph'],
    'en_GB': ['Daniel'],
}
# A pitch estimate misreads several synthetic voices; their persona says it plainly.
SAY_GENDER = {'Anna': 'female', 'Eddy': 'male', 'Flo': 'female', 'Grandma': 'female', 'Grandpa': 'male',
              'Reed': 'male', 'Rocko': 'male', 'Sandy': 'female', 'Shelley': 'female', 'Samantha': 'female',
              'Albert': 'male', 'Fred': 'male', 'Junior': 'male', 'Kathy': 'female', 'Ralph': 'male', 'Daniel': 'male'}
SAY_TEXT = {
    'de': pathlib.Path(__file__).with_name('say-text-de.txt'),
    'en': pathlib.Path(__file__).with_name('say-text-en.txt'),
}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def fetch(url, target):
    """Downloads with curl, which copes with the archive's redirects and chunking."""
    part = pathlib.Path(f'{target}.part')
    subprocess.run(['curl', '-sSfL', '--retry', '4', '--retry-all-errors', '-m', '600', '-A', HEADERS['User-Agent'],
                    '-o', str(part), url], check=True)
    part.rename(target)


def fetch_json(url, cache):
    if not cache.exists():
        fetch(url, cache)
    return json.loads(cache.read_text())


def order(key):
    return hashlib.sha256(f'{SEED}:{key}'.encode()).hexdigest()


def catalog(work):
    meta = work / 'meta'
    meta.mkdir(parents=True, exist_ok=True)
    readers = {}
    for language, queries in COLLECTIONS.items():
        for query in queries:
            name = re.sub(r'[^a-z0-9]+', '-', query.lower()).strip('-')
            books = fetch_json(API + urllib.parse.quote(query), meta / f'{language}-{name}.json')['books']
            for book in books:
                for section in book['sections']:
                    if len(section['readers']) != 1 or not section['listen_url']:
                        continue
                    reader = section['readers'][0]
                    seconds = int(section['playtime'] or 0)
                    if not SECTION_RANGE[0] <= seconds <= SECTION_RANGE[1]:
                        continue
                    entry = readers.setdefault(reader['reader_id'], {
                        'reader_id': reader['reader_id'], 'reader': reader['display_name'],
                        'language': language, 'sections': []})
                    if entry['language'] != language:
                        continue  # a reader of both languages stays with the first
                    entry['sections'].append({
                        'book_id': book['id'], 'book': book['title'], 'item': book['url_iarchive'],
                        'title': section['title'], 'url': section['listen_url'], 'seconds': seconds})
    return readers


def archive_file(item_url, filename, meta):
    item = item_url.rstrip('/').split('/')[-1]
    data = fetch_json(f'https://archive.org/metadata/{item}', meta / f'item-{item}.json')
    match = next((f for f in data['files'] if f['name'] == filename), None)
    return item, data['metadata'].get('licenseurl'), match


def download(url, target):
    if not target.exists():
        fetch(url.replace('://www.archive.org', '://archive.org'), target)


def decode(source, target):
    subprocess.run(['ffmpeg', '-nostdin', '-loglevel', 'error', '-y', '-i', str(source), '-ac', '1',
                    '-ar', str(RATE), '-c:a', 'pcm_f32le', str(target)], check=True)


def build_readers(work, corpus):
    meta, mp3s, speakers = work / 'meta', work / 'mp3', work / 'speakers'
    mp3s.mkdir(exist_ok=True)
    speakers.mkdir(exist_ok=True)
    known = {entry['id'] for entry in corpus}
    counts = {}
    for entry in corpus:
        counts[(entry['language'], entry['gender'])] = counts.get((entry['language'], entry['gender']), 0) + 1
    readers = catalog(work)
    for reader in sorted(readers.values(), key=lambda r: order(r['reader_id'])):
        language = reader['language']
        if all(counts.get((language, g), 0) >= PER_GROUP for g in ('female', 'male')):
            continue
        speaker_id = f"lv{reader['reader_id']}"
        if speaker_id in known or not reader['sections']:
            continue
        section = max(reader['sections'], key=lambda s: (s['seconds'], s['url']))
        filename = section['url'].split('/')[-1]
        mp3 = mp3s / filename
        try:
            item, licence, info = archive_file(section['item'], filename, meta)
            if info is None or not licence or 'publicdomain' not in licence:
                print(f'skip {reader["reader"]}: licence {licence!r}, file {bool(info)}', file=sys.stderr)
                continue
            download(section['url'], mp3)
        except subprocess.CalledProcessError as error:
            print(f'skip {reader["reader"]}: {error}', file=sys.stderr)
            continue
        if info.get('sha1') and hashlib.sha1(mp3.read_bytes()).hexdigest() != info['sha1']:
            raise SystemExit(f'{filename}: SHA-1 differs from archive.org metadata')
        wav = speakers / f'{speaker_id}.wav'
        decode(mp3, wav)
        f0 = f0_median(read_wav(wav))
        gender = 'male' if f0 < F0_SPLIT else 'female'
        if counts.get((language, gender), 0) >= PER_GROUP:
            wav.unlink()
            continue
        counts[(language, gender)] = counts.get((language, gender), 0) + 1
        entry = {
            'id': speaker_id, 'kind': 'librivox', 'reader': reader['reader'], 'reader_id': reader['reader_id'],
            'language': language, 'gender': gender, 'gender_source': f'median F0 vs {F0_SPLIT:.0f} Hz',
            'f0_median': round(f0, 1), 'book': section['book'], 'section': section['title'],
            'source_url': section['url'], 'archive_item': item, 'license': licence,
            'mp3_sha256': sha256(mp3), 'wav': wav.name, 'wav_sha256': sha256(wav),
            'seconds': round(len(read_wav(wav)) / RATE, 1)}
        corpus.append(entry)
        known.add(speaker_id)
        print(f"{speaker_id} {language}: {section['title']}", flush=True)
        save(work, corpus)


def say_voices():
    listing = subprocess.run(['say', '-v', '?'], capture_output=True, text=True, check=True).stdout
    installed = {}
    for line in listing.splitlines():
        match = re.match(r'^(.+?)\s+([a-z]{2,3}_[A-Z0-9]{2,3})\s+#', line)
        if match:
            installed.setdefault(match[2], []).append(match[1])
    for locale, names in SAY_VOICES.items():
        for name in names:
            full = next((v for v in installed.get(locale, []) if v == name or v.startswith(f'{name} (')), None)
            if full:
                yield locale, name, full


def build_say(work, corpus):
    speakers = work / 'speakers'
    known = {entry['id'] for entry in corpus}
    for locale, name, full in say_voices():
        speaker_id = f'say-{name.lower()}'
        if speaker_id in known:
            continue
        language = locale[:2]
        lines = [l.strip() for l in SAY_TEXT[language].read_text().splitlines() if l.strip()]
        random.Random(f'{SEED}:{speaker_id}').shuffle(lines)
        with tempfile.TemporaryDirectory() as folder:
            raw = pathlib.Path(folder) / 'say.caf'
            subprocess.run(['say', '-v', full, '--file-format=caff', '--data-format=LEF32@48000', '-o', str(raw),
                            '\n'.join(lines)], check=True)
            wav = speakers / f'{speaker_id}.wav'
            decode(raw, wav)
        samples = read_wav(wav)
        f0 = f0_median(samples)
        entry = {
            'id': speaker_id, 'kind': 'say', 'reader': full, 'language': language, 'locale': locale,
            'gender': SAY_GENDER[name], 'gender_source': 'voice persona',
            'f0_median': round(f0, 1), 'source_url': f'macOS say -v "{full}"', 'license':
            'macOS system voice, generated locally for evaluation, not redistributed',
            'text': SAY_TEXT[language].name, 'wav': wav.name, 'wav_sha256': sha256(wav),
            'seconds': round(len(samples) / RATE, 1)}
        corpus.append(entry)
        print(f'{speaker_id} {locale}', flush=True)
        save(work, corpus)


def save(work, corpus):
    (work / 'corpus.json').write_text(json.dumps(sorted(corpus, key=lambda e: e['id']), indent=1, ensure_ascii=False) + '\n')


def split(work):
    """Speakers, not conversations, are split: dev and test never share a voice."""
    corpus = json.loads((work / 'corpus.json').read_text())
    groups = {}
    for entry in corpus:
        groups.setdefault((entry['kind'], entry['language'], entry['gender']), []).append(entry)
    dev, test = [], []
    for key in sorted(groups):
        members = sorted(groups[key], key=lambda e: order(e['id']))
        half = len(members) // 2
        test += [e['id'] for e in members[:half]]
        dev += [e['id'] for e in members[half:]]
    for name, ids in [('dev', dev), ('test', test)]:
        path = work / f'{name}-speakers.json'
        if path.exists():
            raise SystemExit(f'{path} exists; the split is made once')
        path.write_text(json.dumps(sorted(ids), indent=1) + '\n')
        print(name, len(ids), sha256(path))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work', type=pathlib.Path, required=True)
    parser.add_argument('step', choices=['build', 'split'])
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    if args.step == 'build':
        path = args.work / 'corpus.json'
        corpus = json.loads(path.read_text()) if path.exists() else []
        build_readers(args.work, corpus)
        build_say(args.work, corpus)
        save(args.work, corpus)
    else:
        split(args.work)


if __name__ == '__main__':
    main()
