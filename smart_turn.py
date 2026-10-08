"""Smart Turn v3 (pipecat-ai/smart-turn-v3): "has the speaker finished?" from audio.

Takes the last 8 s of a 16 kHz utterance, returns P(turn complete) in [0, 1].
The Whisper log-mel front end is reimplemented in numpy so the product doesn't
need transformers/torch (checked against WhisperFeatureExtractor to ~1e-5).
"""
from pathlib import Path

import numpy as np
import onnxruntime as ort

SR, N_FFT, HOP, N_MELS, SECONDS = 16000, 400, 160, 80, 8
MODEL = Path(__file__).resolve().parent / "models" / "smart-turn-v3.2-cpu.onnx"


def _mel_filters():
    # slaney mel scale + slaney norm, as in Whisper / librosa defaults
    def hz_to_mel(f):
        f = np.asarray(f, dtype=np.float64)
        lin = f / (200.0 / 3)
        log = 15.0 + np.log(np.maximum(f, 1e-10) / 1000.0) / (np.log(6.4) / 27.0)
        return np.where(f >= 1000.0, log, lin)

    def mel_to_hz(m):
        m = np.asarray(m, dtype=np.float64)
        lin = m * (200.0 / 3)
        log = 1000.0 * np.exp((np.log(6.4) / 27.0) * (m - 15.0))
        return np.where(m >= 15.0, log, lin)

    fft_f = np.linspace(0, SR / 2, N_FFT // 2 + 1)
    mel_pts = mel_to_hz(np.linspace(hz_to_mel(0.0), hz_to_mel(SR / 2), N_MELS + 2))
    fdiff = np.diff(mel_pts)
    ramps = mel_pts[:, None] - fft_f[None, :]
    lower = -ramps[:-2] / fdiff[:-1, None]
    upper = ramps[2:] / fdiff[1:, None]
    w = np.maximum(0, np.minimum(lower, upper))
    w *= (2.0 / (mel_pts[2:N_MELS + 2] - mel_pts[:N_MELS]))[:, None]
    return w  # (80, 201)


_FILTERS = _mel_filters()
_WINDOW = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N_FFT) / N_FFT)  # periodic hann


def features(audio: np.ndarray) -> np.ndarray:
    n = SR * SECONDS
    a = audio.astype(np.float64)[-n:]
    a = np.pad(a, (n - len(a), 0))                         # left-pad: speech sits at the end
    a = (a - a.mean()) / np.sqrt(a.var() + 1e-7)            # do_normalize=True
    p = np.pad(a, (N_FFT // 2, N_FFT // 2), mode="reflect")  # center=True
    frames = np.lib.stride_tricks.sliding_window_view(p, N_FFT)[::HOP]
    spec = np.abs(np.fft.rfft(frames * _WINDOW, axis=1)) ** 2
    spec = spec[:-1].T                                       # drop last frame -> 800
    logm = np.log10(np.maximum(_FILTERS @ spec, 1e-10))
    logm = np.maximum(logm, logm.max() - 8.0)
    return ((logm + 4.0) / 4.0).astype(np.float32)          # (80, 800)


class SmartTurn:
    def __init__(self, path=MODEL):
        o = ort.SessionOptions()
        o.intra_op_num_threads = 1
        o.inter_op_num_threads = 1
        self.s = ort.InferenceSession(str(path), sess_options=o,
                                      providers=["CPUExecutionProvider"])

    def p_complete(self, audio: np.ndarray) -> float:
        out = self.s.run(None, {"input_features": features(audio)[None]})[0]
        return float(out.reshape(-1)[0])
