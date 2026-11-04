#!/usr/bin/env python3
"""Session-local Supertonic worker: bounded JSON/PCM over anonymous pipes.

Run with Python -I -B under the app's deny-network/deny-write sandbox. No model
or dependency downloader is present. The parent owns cancellation and kills this
single process; this worker never launches child processes or persists content.
"""
import base64
import contextlib
import hashlib
import importlib.util
import json
import os
import platform
from pathlib import Path
import re
import sys

SAMPLE_RATE = 44100
MAX_PACKET_FRAMES = 24000
# As raised by Python, libc++ and the pinned ONNX Runtime. Only ever matched here, never sent.
OUT_OF_MEMORY_MESSAGES = ("allocation failed", "failed to allocate", "out of memory", "bad_alloc", "bad allocation")


class WorkerFailure(Exception):
    """A fixed code for the parent. It holds no cause, message, path or request text."""
    def __init__(self, code):
        super().__init__(code)
        self.code = code


class RequestTooLong(ValueError):
    pass


@contextlib.contextmanager
def failure_stage(code):
    try:
        yield
    except WorkerFailure:
        raise
    except RequestTooLong:
        raise WorkerFailure("too_long") from None
    except Exception as error:
        memory = isinstance(error, MemoryError) or any(text in str(error).lower() for text in OUT_OF_MEMORY_MESSAGES)
        raise WorkerFailure("out_of_memory" if memory else code) from None


def read_request(source, session=False):
    line = source.readline(64002)
    if session and not line:
        return None
    if len(line) > 64001:
        raise RequestTooLong("Oversized request frame")
    if not line.endswith(b"\n"):
        raise ValueError("Invalid request frame")
    request = json.loads(line)
    fields = {"text", "language", "id"} if session else {"text", "language"}
    if not isinstance(request, dict) or set(request) != fields:
        raise ValueError("Invalid fields")
    text, language = request["text"], request["language"]
    if not isinstance(text, str) or not text.strip():
        raise ValueError("Invalid text")
    if len(text) > 8000:
        raise RequestTooLong("Too many characters")
    if language not in ("de", "en"):
        raise ValueError("Invalid language")
    if session:
        identity = request["id"]
        if not isinstance(identity, str) or not 0 < len(identity) <= 64:
            raise ValueError("Invalid identity")
        return text, language, identity
    return text, language


def segments(text):
    # Keep common German/English abbreviations, initials and ordinal dates with
    # their following context. Never expand numbers or rewrite user wording.
    abbreviations = {"dr.", "prof.", "mr.", "mrs.", "ms.", "bzw.", "ca.", "nr.",
                     "z.b.", "d.h.", "u.a.", "usw.", "etc.", "e.g.", "i.e.", "vs."}
    sentences = []
    start = 0
    text = text.strip()
    for boundary in re.finditer(r"(?<=[.!?])\s+|\n[ \t]*\n+", text):
        preceding = text[:boundary.start()].split()
        token = preceding[-1] if preceding else ""
        paragraph = boundary.group().count("\n") >= 2
        protected = token.lower() in abbreviations or re.fullmatch(r"(?:[^\W\d_]|\d+)\.", token)
        if protected and not paragraph:
            continue
        sentences.append(text[start:boundary.start()])
        start = boundary.end()
    sentences.append(text[start:])
    result = []
    for sentence in sentences:
        remaining = sentence.strip()
        while len(remaining) > 240:
            spaces = list(re.finditer(r"\s", remaining[:241]))
            boundary = spaces[-1].start() if spaces else 240
            result.append(remaining[:boundary])
            remaining = remaining[boundary:].lstrip()
        if remaining:
            result.append(remaining)
    return result


def send(output, packet):
    output.write(json.dumps(packet, separators=(",", ":")).encode() + b"\n")
    output.flush()


def await_ack(source):
    if source.readline(6) != b"next\n":
        raise ValueError("Parent disconnected")


def file_hash(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def load_verified_helper(model):
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / "model-manifest.json").read_text())
    for entry in manifest["files"]:
        path = (model / entry["path"]).resolve()
        if not path.is_relative_to(model) or path.stat().st_size != entry["bytes"]:
            raise ValueError("Model size mismatch")
        if "sha256" in entry:
            valid = file_hash(path) == entry["sha256"]
        else:
            blob = f"blob {entry['bytes']}\0".encode() + path.read_bytes()
            valid = hashlib.sha1(blob).hexdigest() == entry["git_blob"]
        if not valid:
            raise ValueError("Model hash mismatch")
    helper_path = root / "upstream/helper.py"
    if file_hash(helper_path) != manifest["runtime_source"]["sha256"]:
        raise ValueError("Helper hash mismatch")
    spec = importlib.util.spec_from_file_location("supertonic_helper", helper_path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    return helper


def load_speech_model(helper, model):
    directory = str(model / "onnx")
    if platform.machine() != "x86_64":
        return helper.load_text_to_speech(directory, use_gpu=False)
    # Four independent ONNX sessions otherwise spin competing CPU thread pools.
    # Keep the pinned helper/model intact and bound CPU work without changing
    # voice, denoising steps, segmentation or playback buffering.
    options = helper.ort.SessionOptions()
    options.intra_op_num_threads = min(4, os.cpu_count() or 1)
    options.add_session_config_entry("session.intra_op.allow_spinning", "0")
    options.add_session_config_entry("session.inter_op.allow_spinning", "0")
    sessions = helper.load_onnx_all(directory, options, ["CPUExecutionProvider"])
    return helper.TextToSpeech(helper.load_cfgs(directory),
                               helper.load_text_processor(directory), *sessions)


def run(source, output, model, session=False):
    with failure_stage("invalid_request"):
        request = read_request(source, session=session)
    if request is None:
        return
    with failure_stage("load_failed"):
        helper = load_verified_helper(model)
        import numpy as np

        tts = load_speech_model(helper, model)
        if tts.sample_rate != SAMPLE_RATE:
            raise ValueError("Wrong model sample rate")
        style = helper.load_voice_style([str(model / "voice_styles/M1.json")])
    while request is not None:
        text, language = request[:2]
        identity = request[2] if session else None
        def emit(packet):
            if session:
                packet["id"] = identity
                packet["protocol"] = 2
            send(output, packet)
        with failure_stage("synthesis_failed"):
            # Per-text reproducibility must not depend on earlier queued text. A retry
            # with a fresh worker relies on it to continue where the first one stopped.
            np.random.seed(42)
            emit({"kind": "ready", "sampleRate": SAMPLE_RATE})
            synthesize(source, emit, tts, style, text, language)
            emit({"kind": "end"})
        # Do not retain a user's prior text/PCM while waiting for another request.
        del text, language, request
        if not session:
            break
        with failure_stage("invalid_request"):
            request = read_request(source, session=True)


def synthesize(source, emit, tts, style, text, language):
    import numpy as np
    for segment in segments(text):
        wav, duration = tts(segment, language, style, 8, speed=1.0)
        seconds = float(duration[0])
        if not np.isfinite(seconds) or not 0 < seconds <= 120:
            raise ValueError("Invalid duration")
        frames = int(SAMPLE_RATE * seconds)
        if wav.ndim != 2 or wav.shape[0] != 1 or wav.shape[1] < frames or frames == 0:
            raise ValueError("Incomplete audio")
        audio = wav[0, :frames]
        if not np.isfinite(audio).all() or np.max(np.abs(audio)) <= 0.0001:
            raise ValueError("Invalid audio")
        for offset in range(0, frames, MAX_PACKET_FRAMES):
            pcm = audio[offset:offset + MAX_PACKET_FRAMES].astype("<f4").tobytes()
            emit({"kind": "audio", "sampleRate": SAMPLE_RATE,
                          "pcm": base64.b64encode(pcm).decode("ascii")})
            await_ack(source)


def main():
    # Hide native-library prints and traceback content before importing upstream.
    output = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
    with open(os.devnull, "wb") as null:
        os.dup2(null.fileno(), sys.stdout.fileno())
        os.dup2(null.fileno(), sys.stderr.fileno())
    try:
        session = len(sys.argv) == 4 and sys.argv[3] == "--session"
        if (len(sys.argv) != 3 and not session) or sys.argv[1] != "--model":
            raise ValueError("Invalid arguments")
        run(sys.stdin.buffer, output, Path(sys.argv[2]).resolve(), session=session)
    except Exception as error:
        code = error.code if isinstance(error, WorkerFailure) else "invalid_request"
        try:
            send(output, {"kind": "error", "code": code})
        except OSError:
            pass
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
