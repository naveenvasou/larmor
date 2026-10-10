"""Larmor's audio engine: one process that owns BOTH the mic and the agent's voice.

    mic ─▶ larmor_audio (Apple VoiceProcessingIO: echo-cancelled) ─▶ Silero VAD
        ─▶ Smart Turn (are they done?) ─▶ local Parakeet ─▶ ~/.larmor/turns.jsonl
    speak ─▶ POST /say ─▶ TTS renders each sentence ─▶ larmor_audio stdin ─▶ speaker

Why the ear plays the voice too: Apple's echo canceller can only subtract audio it
is handed as the far-end reference. When the agent's voice goes out through the
same unit, the mic signal comes back with it removed, so we can keep listening
while talking and treat ANY speech we hear as the user. That makes barge-in a plain VAD
decision: the user starts talking while we're playing -> pause playback at once
(SIGUSR1 flushes it in one render block), then stop or resume. No word matching,
no transcript of our own voice.

Control (HTTP on 127.0.0.1, port written to ~/.larmor/ear.json):
    POST /say  {"text": "..."}   queue a line (sentences render ahead of playback)
    POST /stop                   stop talking now, drop anything queued
    GET  /state                  {"speaking": bool, "queued": n}
"""
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
import onnxruntime as ort
import requests
import soxr

from smart_turn import SmartTurn

SR = 16000
FRAME = 512                       # Silero v5 frame at 16 kHz (32 ms)
CTX = 64                          # v5 wants the previous 64 samples prepended
HERE = Path(__file__).resolve().parent
VAD_MODEL = os.getenv("LARMOR_VAD_MODEL", str(HERE / "models" / "silero_vad.onnx"))
AUDIO_BIN = os.getenv("LARMOR_AUDIO_BIN", str(HERE / "native" / "larmor_audio"))
ENGINE = os.getenv("LARMOR_ENGINE_URL", "http://127.0.0.1:8160")   # engine/larmor_engine.py
OUT = Path(os.getenv("LARMOR_TURNS", os.path.expanduser("~/.larmor/turns.jsonl")))
INFO = Path(os.path.expanduser("~/.larmor/ear.json"))

START_P, END_P = 0.6, 0.35        # VAD hysteresis: enter speech above START, leave below END
MIN_SPEECH_S = 0.30               # shorter than this is a click or a cough
PRE_ROLL_S = 0.30                 # keep audio from just before the VAD fired
MAX_TURN_S = 60.0
# Turn end = Smart Turn, not a fixed silence timer. After a short pause ask the
# model "is the user done?": yes -> end now; no -> keep listening, give up after a long pause.
CHECK_AFTER_S = 0.30
DONE_P = 0.5
# Smart Turn alone scores thinking pauses as finished whenever the phrase *sounds*
# done, cutting people off mid-thought. Two guards, both standard practice:
#   1. the earlier the pause, the surer the model must be;
#   2. a "done" is only a CANDIDATE until its transcript is back - if the text ends
#      mid-thought ("uh", "and", "the", "because"...) or they speak again first, keep going.
def done_threshold(silent_s: float) -> float:
    if silent_s < 0.6:
        return 0.85
    if silent_s < 1.2:
        return 0.70
    return DONE_P


TRAILING = set("""uh um umm hmm er ah and or but so the a an of to with for like because
that which who is are was were if then in on at as my our your their this these we i
you it its from about into than also just very really actually basically""".split())


def ends_mid_thought(text: str) -> bool:
    words = re.findall(r"[a-z']+", text.lower())
    return bool(words) and (words[-1] in TRAILING or text.rstrip().endswith((",", "-", "…")))
RECHECK_EVERY_S = 0.40
MAX_PAUSE_S = 2.5
# Barge-in is two-stage. Stopping for good on any 0.25 s of voice meant a "mm-hmm",
# a "sorry" or someone else in the room cut the agent off. So 0.25 s of voice only
# PAUSES playback, which still feels instant; the stop is committed when the user
# keeps talking (COMMIT_S) or their words turn out to be a real interruption. A
# backchannel or no words at all resumes the sentence from just before the pause.
# No matching against our own words: echo is the echo canceller's job.
BARGE_IN_S = float(os.getenv("LARMOR_BARGE_IN_S", "0.25"))  # user speech while we talk -> pause
COMMIT_S = float(os.getenv("LARMOR_BARGE_COMMIT_S", "0.9"))  # this much voice -> stop for good
PROBE_AFTER_S = 0.30              # a paused blip that's gone quiet this long gets transcribed
REWIND_S = 0.30                   # resume a little before the pause point
BACKCHANNEL = {"mm", "mmm", "hmm", "mhm", "mm-hmm", "mmhmm", "uh-huh", "uh", "um", "yeah", "yes",
               "yep", "ok", "okay", "right", "sure", "cool", "nice", "got it", "i see", "sorry",
               "ah", "oh", "huh", "hm", "aha", "great", "alright", "all right"}
LEAD_S = 0.20                     # how far ahead of the speaker we feed playback

PARENT = int(os.getenv("LARMOR_PARENT_PID", "0"))
SENT = re.compile(r"(?<=[.!?…])\s+")


def log(*a):
    print(time.strftime("%H:%M:%S"), "[ear]", *a, file=sys.stderr, flush=True)


class Vad:
    def __init__(self, path):
        o = ort.SessionOptions()
        o.intra_op_num_threads = 1
        o.inter_op_num_threads = 1
        self.s = ort.InferenceSession(path, sess_options=o, providers=["CPUExecutionProvider"])
        self.reset()

    def reset(self):
        self.state = np.zeros((2, 1, 128), dtype=np.float32)
        self.ctx = np.zeros(CTX, dtype=np.float32)

    def __call__(self, frame: np.ndarray) -> float:
        x = np.concatenate([self.ctx, frame])[None, :].astype(np.float32)
        out, self.state = self.s.run(None, {"input": x, "state": self.state,
                                            "sr": np.array(SR, dtype=np.int64)})
        self.ctx = frame[-CTX:]
        return float(out[0][0])


def transcribe(audio: np.ndarray) -> str:
    pcm = (np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes()
    try:
        r = requests.post(f"{ENGINE}/transcribe", data=pcm, timeout=30)
        return (r.json().get("text") or "").strip()
    except Exception as e:
        log("parakeet failed:", e)
        return ""


def emit(ev: dict):
    OUT.parent.mkdir(exist_ok=True)
    with OUT.open("a") as f:
        f.write(json.dumps(ev) + "\n")


def parent_alive() -> bool:
    if not PARENT:
        return True
    try:
        os.kill(PARENT, 0)
        return True
    except OSError:
        return False


class Audio:
    """The larmor_audio helper: echo-cancelled mic out of stdout, playback into stdin."""

    def __init__(self):
        self.p = subprocess.Popen([AUDIO_BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, bufsize=0)
        self.mic_rate = None
        self.ref_rate = None
        self.ready = threading.Event()
        threading.Thread(target=self._stderr, daemon=True).start()
        if not self.ready.wait(10):
            raise RuntimeError("larmor_audio never announced its formats")

    def _stderr(self):
        for raw in self.p.stderr:
            line = raw.decode(errors="replace").strip()
            if m := re.match(r"REF_FORMAT sr=(\d+)", line):
                self.ref_rate = int(m.group(1))
            elif m := re.match(r"FORMAT sr=(\d+)", line):
                self.mic_rate = int(m.group(1))
            elif line.startswith("FLUSHED"):
                pass
            else:
                log("audio:", line)
            if self.mic_rate and self.ref_rate:
                self.ready.set()

    def frames(self):
        """Yield 16 kHz float32 mono chunks of the echo-cancelled mic."""
        rs = soxr.ResampleStream(self.mic_rate, SR, 1, dtype="float32")
        while True:
            b = self.p.stdout.read(4096)
            if not b:
                return
            if len(b) % 2:
                b += self.p.stdout.read(1)
            x = np.frombuffer(b, dtype=np.int16).astype(np.float32) / 32768.0
            y = rs.resample_chunk(x)
            if len(y):
                yield y

    def play(self, pcm_i16: bytes):
        self.p.stdin.write(pcm_i16)

    def flush(self):
        try:
            self.p.send_signal(signal.SIGUSR1)
        except OSError:
            pass

    def close(self):
        try:
            self.p.terminate()
        except OSError:
            pass


def is_backchannel(text: str) -> bool:
    t = re.sub(r"[^a-z' -]", "", text.lower()).strip()
    return not t or t in BACKCHANNEL or all(w in BACKCHANNEL for w in t.split())


class Mouth:
    """Renders sentences with the engine and feeds them to the speaker,
    one sentence ahead, paced to real time so a flush loses almost nothing."""

    def __init__(self, audio: Audio):
        self.audio = audio
        self.lines: queue.Queue = queue.Queue()
        self.rendered: queue.Queue = queue.Queue(maxsize=2)
        self.gen = 0                    # bumped on stop: anything older is dropped
        self.play_until = 0.0           # wall time our queued audio finishes playing
        self.cur_text = ""
        self.paused = False
        self.rewind_s = 0.0             # audio to replay on resume (flushed + a little more)
        threading.Thread(target=self._render_loop, daemon=True).start()
        threading.Thread(target=self._play_loop, daemon=True).start()

    @property
    def speaking(self) -> bool:
        return (self.paused or time.time() < self.play_until
                or not self.lines.empty() or not self.rendered.empty())

    def pause(self):
        """Silence now, keep our place. The ring held up to LEAD_S of unplayed audio;
        the play loop rewinds by that much plus REWIND_S when it resumes."""
        if self.paused:
            return
        self.paused = True
        self.rewind_s = max(0.0, self.play_until - time.time()) + REWIND_S
        self.audio.flush()
        self.play_until = time.time()

    def resume(self):
        self.paused = False

    def say(self, text: str):
        for s in SENT.split(text.strip()):
            if s.strip():
                self.lines.put((self.gen, s.strip()))

    def stop(self) -> bool:
        was = self.speaking
        self.gen += 1
        self.paused = False
        for q in (self.lines, self.rendered):
            while True:
                try:
                    q.get_nowait()
                except queue.Empty:
                    break
        self.audio.flush()
        self.play_until = time.time()
        return was

    def _render(self, text: str) -> np.ndarray | None:
        try:
            r = requests.post(f"{ENGINE}/speak", json={"text": text}, timeout=60)
            r.raise_for_status()
            import io
            import wave
            with wave.open(io.BytesIO(r.content), "rb") as w:
                sr, ch = w.getframerate(), w.getnchannels()
                x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
            if ch > 1:
                x = x.reshape(-1, ch).mean(axis=1).astype(np.int16)
            y = soxr.resample(x.astype(np.float32) / 32768.0, sr, self.audio.ref_rate)
            return (np.clip(y, -1, 1) * 32767).astype(np.int16)
        except Exception as e:
            log("tts failed:", e)
            return None

    def _render_loop(self):
        while True:
            gen, text = self.lines.get()
            if gen != self.gen:
                continue
            pcm = self._render(text)
            if pcm is not None and gen == self.gen:
                self.rendered.put((gen, text, pcm))

    def _play_loop(self):
        rate = None
        while True:
            gen, text, pcm = self.rendered.get()
            if gen != self.gen:
                continue
            rate = self.audio.ref_rate
            self.cur_text = text
            step = int(rate * 0.02)                       # 20 ms writes
            i = 0
            if self.play_until < time.time():
                self.play_until = time.time()
            while i < len(pcm) and gen == self.gen:
                if self.paused:
                    if self.rewind_s:
                        i = max(0, i - int(self.rewind_s * rate))
                        self.rewind_s = 0.0
                    time.sleep(0.01)
                    if self.play_until < time.time():
                        self.play_until = time.time()
                    continue
                ahead = self.play_until - time.time()
                if ahead > LEAD_S:
                    time.sleep(ahead - LEAD_S)
                    continue
                chunk = pcm[i:i + step]
                self.audio.play(chunk.tobytes())
                self.play_until += len(chunk) / rate
                i += step


class Control(BaseHTTPRequestHandler):
    mouth: Mouth = None

    def log_message(self, *a):
        pass

    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _local(self) -> bool:
        """Only Larmor's MCP server calls this. Refuse anything a browser sends."""
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        if self.headers.get("Origin") or self.headers.get("Sec-Fetch-Site") or host not in ("127.0.0.1", "localhost"):
            self._send({"error": "local programs only"}, 403)
            return False
        return True

    def do_GET(self):
        if not self._local():
            return
        if self.path == "/state":
            self._send({"speaking": self.mouth.speaking, "queued": self.mouth.lines.qsize()})
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        if not self._local():
            return
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/say":
            self.mouth.say(body.get("text", ""))
            self._send({"ok": True, "queued": self.mouth.lines.qsize()})
        elif self.path == "/stop":
            self._send({"ok": True, "was_speaking": self.mouth.stop()})
        else:
            self._send({"error": "not found"}, 404)


def main():
    try:
        requests.post(f"{ENGINE}/warm", timeout=2)   
    except Exception:
        pass
    audio = Audio()
    mouth = Mouth(audio)
    Control.mouth = mouth
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Control)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    INFO.parent.mkdir(exist_ok=True)
    INFO.write_text(json.dumps({"port": srv.server_address[1], "pid": os.getpid()}))
    log(f"up: mic {audio.mic_rate} Hz, speaker {audio.ref_rate} Hz, control :{srv.server_address[1]}")

    vad, turn = Vad(VAD_MODEL), SmartTurn()
    pre, pre_n = [], int(PRE_ROLL_S * SR / FRAME)
    speech, in_speech, silent_s, Larmor_s, next_check = [], False, 0.0, 0.0, CHECK_AFTER_S
    barged = False
    held = False                       # playback paused on their voice, stop not yet committed
    probe = None                       # transcript of a paused blip: backchannel or interruption?
    fs = FRAME / SR
    buf = np.zeros(0, dtype=np.float32)
    last_check = time.time()

    def emit_turn(text, audio_, wall_end, interrupted):
        if text:
            emit({"type": "turn", "channel": "mic", "text": text, "is_final": True,
                  "is_turn_end": True, "wall_clock": wall_end, "aec": True,
                  "interrupted_agent": interrupted, "dur_s": round(len(audio_) / SR, 2)})
            log(f"turn ({len(audio_)/SR:.1f}s{', barge-in' if interrupted else ''}): {text}")

    cand = None   # {"res": {...}, "n": frames at decision, "barged": bool} while its STT runs

    def start_candidate(audio_):
        res = {"text": None}
        def run():
            res["text"] = transcribe(audio_)
        th = threading.Thread(target=run, daemon=True)
        th.start()
        return {"res": res, "th": th, "audio": audio_}

    def commit(why):
        nonlocal barged, held
        barged, held = True, False
        mouth.stop()
        log(f"barge-in: stopped speaking ({why})")
        emit({"type": "bargein", "channel": "mic", "wall_clock": time.time()})

    def let_go(why):
        nonlocal held
        held = False
        mouth.resume()
        log(f"barge-in: resumed ({why})")

    try:
        for chunk in audio.frames():
            if time.time() - last_check > 2:
                last_check = time.time()
                if not parent_alive():
                    log("parent gone, exiting")
                    return
            buf = np.concatenate([buf, chunk])
            while len(buf) >= FRAME:
                fr, buf = buf[:FRAME], buf[FRAME:]
                p = vad(fr)
                if not in_speech:
                    pre.append(fr)
                    if len(pre) > pre_n:
                        pre.pop(0)
                    if held:                      # safety: never stay paused with no speech
                        let_go("no speech")
                    if p >= START_P:
                        in_speech, speech, pre = True, list(pre), []
                        silent_s, Larmor_s, next_check, barged = 0.0, 0.0, CHECK_AFTER_S, False
                        probe = None
                    continue
                speech.append(fr)
                if p >= END_P:
                    Larmor_s += fs
                    silent_s, next_check = 0.0, CHECK_AFTER_S
                else:
                    silent_s += fs
                # barge-in, stage 1: their voice while we talk -> pause at once.
                if not barged and not held and Larmor_s >= BARGE_IN_S and mouth.speaking:
                    held = True
                    mouth.pause()
                    log("barge-in: paused")
                # stage 2: still going -> it's a real interruption.
                if held and Larmor_s >= COMMIT_S:
                    commit(f"{Larmor_s:.1f}s of speech")
                    probe = None
                # or they stopped short: was that a word that matters?
                if held and probe is None and silent_s >= PROBE_AFTER_S:
                    probe = start_candidate(np.concatenate(speech))
                if probe is not None and silent_s == 0.0:
                    probe = None                  # talking again; COMMIT_S will decide
                if probe is not None and not probe["th"].is_alive():
                    text = probe["res"]["text"] or ""
                    probe = None
                    if is_backchannel(text):
                        let_go(f"{text!r} is a backchannel")
                        in_speech, speech = False, []
                        vad.reset()
                        continue
                    commit(f"{text!r}")
                    emit_turn(text, np.concatenate(speech), time.time(), True)
                    in_speech, speech = False, []
                    vad.reset()
                    continue
                if held:
                    continue                      # undecided: no turn logic until it is
                if cand is not None and silent_s == 0.0:
                    log("kept talking -> candidate dropped")
                    cand = None
                if cand is not None and not cand["th"].is_alive():
                    text = cand["res"]["text"] or ""
                    if text and ends_mid_thought(text) and silent_s < MAX_PAUSE_S:
                        log(f"pause {silent_s:.1f}s, text ends mid-thought ({text[-30:]!r}) -> waiting")
                        cand = None
                    else:
                        emit_turn(text, cand["audio"], time.time(), barged)
                        cand = None
                        in_speech, speech = False, []
                        vad.reset()
                        continue
                if cand is not None:
                    continue                      # its transcript is still coming back
                dur = len(speech) * fs
                hard = dur >= MAX_TURN_S or silent_s >= MAX_PAUSE_S
                done = hard
                if not done and silent_s >= next_check and Larmor_s >= MIN_SPEECH_S:
                    pc = turn.p_complete(np.concatenate(speech))
                    need = done_threshold(silent_s)
                    done = pc >= need
                    next_check = silent_s + RECHECK_EVERY_S
                    log(f"pause {silent_s:.1f}s, P(done)={pc:.2f} (need {need:.2f}) -> "
                        f"{'checking text' if done else 'waiting'}")
                if done:
                    if Larmor_s < MIN_SPEECH_S:
                        if held:
                            let_go("too short to be speech")
                        in_speech, speech = False, []
                        vad.reset()
                        continue
                    cand = start_candidate(np.concatenate(speech))
                    if hard:                      # no second-guessing at the hard caps
                        cand["th"].join()
                        emit_turn(cand["res"]["text"] or "", cand["audio"], time.time(), barged)
                        cand = None
                        in_speech, speech = False, []
                        vad.reset()
    finally:
        audio.close()
        try:
            INFO.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    try:
        main()
    except KeyboardInterrupt:
        pass
