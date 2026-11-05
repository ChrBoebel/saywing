"""Small audio helpers shared by the corpus and scenario scripts."""
import numpy as np
from scipy.io import wavfile

RATE = 16_000  # master rate of the corpus and of mixed scenarios


def read_wav(path):
    rate, data = wavfile.read(path)
    if rate != RATE:
        raise ValueError(f'{path}: {rate} Hz, expected {RATE}')
    data = data.astype(np.float32)
    return data if data.ndim == 1 else data.mean(axis=1)


def write_wav(path, samples, rate=RATE):
    wavfile.write(path, rate, np.asarray(samples, dtype=np.float32))


def frames(samples, size, hop):
    count = max(0, 1 + (len(samples) - size) // hop)
    index = np.arange(size)[None, :] + hop * np.arange(count)[:, None]
    return samples[index]


def speech_mask(samples, rate=RATE, hop=0.02, floor_db=-35.0):
    """Frames whose level is within `floor_db` of the loud frames: speech, roughly."""
    size = int(rate * hop)
    level = np.sqrt((frames(samples, size, size) ** 2).mean(axis=1) + 1e-12)
    loud = np.percentile(level, 95)
    return level > loud * 10 ** (floor_db / 20)


def f0_track(samples, rate=RATE):
    """Voiced-frame F0 in Hz by normalised autocorrelation (60-400 Hz)."""
    size, hop = int(0.04 * rate), int(0.02 * rate)
    windows = frames(samples, size, hop)
    level = np.sqrt((windows ** 2).mean(axis=1))
    windows = windows[level > np.percentile(level, 50)]
    if len(windows) > 8000:
        windows = windows[np.linspace(0, len(windows) - 1, 8000).astype(int)]
    windows = windows - windows.mean(axis=1, keepdims=True)
    spectrum = np.fft.rfft(windows, n=2 * size, axis=1)
    auto = np.fft.irfft(np.abs(spectrum) ** 2, axis=1)[:, :size]
    auto /= auto[:, :1] + 1e-12
    low, high = int(rate / 400), int(rate / 60)
    lags = low + np.argmax(auto[:, low:high], axis=1)
    peaks = auto[np.arange(len(auto)), lags]
    return rate / lags[peaks > 0.5]


def f0_median(samples, rate=RATE):
    """Median F0, skipping the first 25 s and last 20 s (LibriVox announcements)."""
    body = samples[int(25 * rate):len(samples) - int(20 * rate)]
    track = f0_track(body if len(body) > rate * 30 else samples, rate)
    return float(np.median(track)) if len(track) else float('nan')
