"""Larmor engine: local speech-to-text (Parakeet) and voice (Chatterbox) in one process.

The menu-bar app starts, watches and restarts it; the ear (larmor_ear.py) calls it.

    POST /transcribe      raw 16 kHz mono int16 PCM  -> {"text", "ms", "audio_s"}
    POST /warm            no-op once loaded (kept for the ear's startup call)
    POST /speak           {"text"} (application/json) -> 24 kHz mono WAV bytes
    GET  /health          {"state": downloading|loading|ready|error, "progress", ...}

Only local programs may call it. Anything a browser sends (an Origin or Sec-Fetch-Site
header, or someone else's Host after DNS rebinding) is refused, so a web page can't use it.

First run downloads the models (about 3 GB) and /health reports the progress.

    python engine/larmor_engine.py            # port 8160, or LARMOR_ENGINE_PORT
"""
import asyncio
import io
import os
import queue
import threading
import time
import traceback
import wave
from pathlib import Path

import numpy as np
from aiohttp import web

PORT = int(os.getenv("LARMOR_ENGINE_PORT", "8160"))
STT_MODEL = os.getenv("LARMOR_STT_MODEL", "mlx-community/parakeet-tdt-0.6b-v2")
TTS_MODEL = os.getenv("LARMOR_TTS_MODEL", "mlx-community/chatterbox-turbo-8bit")
S3TOK = "mlx-community/S3TokenizerV2"   # Chatterbox Turbo fetches this at load; count it in the download
SR = 16000

STATE = {"state": "starting", "detail": "", "progress": 0.0,
         "downloaded_mb": 0, "total_mb": 0, "stt": False, "tts": False, "tts_sr": 24000}


def log(*a):
    print(time.strftime("%H:%M:%S"), "[larmor-engine]", *a, flush=True)


# ── download ──────────────────────────────────────────────────────────────────

def _repo_cache(repo: str) -> Path:
    from huggingface_hub.constants import HF_HUB_CACHE
    return Path(HF_HUB_CACHE) / ("models--" + repo.replace("/", "--"))


def _bytes_on_disk(repo: str) -> int:
    d = _repo_cache(repo) / "blobs"
    return sum(f.stat().st_size for f in d.glob("*")) if d.exists() else 0


def download_models() -> None:
    """Fetch the model repos, reporting progress for the menu bar. Already-cached
    files are skipped by huggingface_hub, so reruns are instant.

    Progress comes from huggingface_hub's own network byte counter (its
    "Downloading bytes" bar), hooked through tqdm_class. Watching blobs/ on disk doesn't work: Xet
    downloads don't grow the file as they go."""
    from huggingface_hub import HfApi, snapshot_download
    from huggingface_hub.utils import tqdm as hf_tqdm
    repos = [STT_MODEL, TTS_MODEL, S3TOK]
    only = {S3TOK: ["model.safetensors"]}
    try:
        api = HfApi()
        total = sum(sum((s.size or 0) for s in api.model_info(r, files_metadata=True).siblings
                        if r not in only or s.rfilename in only[r])
                    for r in repos)
    except Exception as e:  # offline with a full cache is fine; offline without one fails below
        log("could not size repos:", e)
        total = 0
    cached = sum(_bytes_on_disk(r) for r in repos)
    got = [0]

    class Progress(hf_tqdm):
        def __init__(self, *a, **k):
            # a disabled tqdm (no TTY under launchd) never sets .unit/.desc, so keep our own
            self._bytes = k.get("unit") == "B" and str(k.get("desc", "")).startswith("Downloading bytes")
            super().__init__(*a, **k)

        def update(self, n=1):
            if self._bytes:
                got[0] += n or 0
                have = min(cached + got[0], total) if total else cached + got[0]
                STATE["downloaded_mb"] = round(have / 1e6)
                STATE["progress"] = round(have / total, 3) if total else 0.0
            return super().update(n)

    STATE.update(state="downloading", total_mb=round(total / 1e6),
                 downloaded_mb=round(cached / 1e6),
                 progress=round(min(cached / total, 1.0), 3) if total else 0.0)
    for r in repos:
        STATE["detail"] = r.split("/")[-1]
        snapshot_download(r, allow_patterns=only.get(r), tqdm_class=Progress)
    STATE.update(progress=1.0, downloaded_mb=round(total / 1e6), detail="")


# ── models: each lives on its own thread (MLX streams are per thread) ─────────

stt_jobs: queue.Queue = queue.Queue()
tts_jobs: queue.Queue = queue.Queue()
loaded = {"stt": threading.Event(), "tts": threading.Event()}


def stt_worker():
    import mlx.core as mx
    from parakeet_mlx import from_pretrained
    from parakeet_mlx.audio import get_logmel
    mx.set_cache_limit(512 * 1024 ** 2)
    t = time.time()
    m = from_pretrained(STT_MODEL)
    mx.eval(m.parameters())                      # weights load lazily; pay it now
    m.generate(get_logmel(mx.zeros(SR), m.preprocessor_config))
    STATE["stt"] = True
    loaded["stt"].set()
    log(f"stt {STT_MODEL} ready in {time.time() - t:.1f}s")
    while True:
        pcm, fut, loop = stt_jobs.get()
        try:
            audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
            dur = len(audio) / SR
            t = time.time()
            text = ""
            if dur >= 0.2:
                r = m.generate(get_logmel(mx.array(audio), m.preprocessor_config))[0]
                text = r.text
            mx.clear_cache()
            out = {"text": text.strip(), "ms": round((time.time() - t) * 1000), "audio_s": round(dur, 2)}
            loop.call_soon_threadsafe(fut.set_result, out)
        except Exception as e:  # noqa: BLE001
            loop.call_soon_threadsafe(fut.set_exception, e)


def tts_worker():
    from mlx_audio.tts.utils import load_model
    t = time.time()
    model = load_model(TTS_MODEL)
    sr = STATE["tts_sr"] = getattr(model, "sample_rate", 24000)
    for _ in model.generate(text="Ready."):
        pass
    STATE["tts"] = True
    loaded["tts"].set()
    log(f"tts {TTS_MODEL} ready in {time.time() - t:.1f}s, {sr} Hz")
    while True:
        text, fut, loop = tts_jobs.get()
        try:
            parts = [np.asarray(r.audio, dtype=np.float32).reshape(-1) for r in model.generate(text=text)]
            a = np.concatenate(parts) if parts else np.zeros(0, dtype=np.float32)
            peak = float(np.abs(a).max()) if a.size else 0.0
            if peak > 0:
                a = a / peak * 0.95
            fade = min(int(0.02 * sr), a.size)
            if fade > 1:
                a[-fade:] *= np.linspace(1, 0, fade, dtype=np.float32)
            buf = io.BytesIO()
            with wave.open(buf, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(sr)
                w.writeframes((a * 32767).astype(np.int16).tobytes())
            loop.call_soon_threadsafe(fut.set_result, (buf.getvalue(), len(a) / sr))
        except Exception as e:  # noqa: BLE001
            loop.call_soon_threadsafe(fut.set_exception, e)


def boot():
    try:
        download_models()
        STATE.update(state="loading", detail="")
        threading.Thread(target=stt_worker, daemon=True, name="stt").start()
        threading.Thread(target=tts_worker, daemon=True, name="tts").start()
        for name, ev in loaded.items():
            while not ev.wait(1):
                pass
        STATE.update(state="ready")
        log("ready")
    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        STATE.update(state="error", detail=f"{type(e).__name__}: {e}")


# ── http ──────────────────────────────────────────────────────────────────────

LOCAL_HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}


@web.middleware
async def local_only(req: web.Request, handler):
    """The ear and the menu-bar app are the only callers, and neither is a browser.
    Browsers send Origin on every cross-site POST (no-cors included) and Sec-Fetch-Site
    on modern requests; a DNS-rebinding page arrives with its own Host."""
    if req.headers.get("Origin") or req.headers.get("Sec-Fetch-Site") or req.host not in LOCAL_HOSTS:
        return web.json_response({"error": "local programs only"}, status=403)
    return await handler(req)


async def _submit(q: queue.Queue, ev: threading.Event, *args):
    if not ev.is_set():
        raise web.HTTPServiceUnavailable(text=f"engine {STATE['state']}")
    loop = asyncio.get_running_loop()
    fut = loop.create_future()
    q.put((*args, fut, loop))
    return await fut


async def transcribe(req: web.Request):
    pcm = await req.read()
    try:
        out = await _submit(stt_jobs, loaded["stt"], pcm)
    except web.HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        return web.json_response({"error": f"{type(e).__name__}: {e}"}, status=500)
    log(f"{out['audio_s']:5.1f}s -> {out['ms']:4d} ms | {out['text'][:60]!r}")
    return web.json_response(out)


async def speak(req: web.Request):
    if req.content_type != "application/json":
        return web.json_response({"error": "send application/json"}, status=415)
    body = await req.json()
    text = (body.get("text") or "").strip()
    if not text:
        return web.json_response({"error": "need text"}, status=400)
    t = time.time()
    try:
        wav, dur = await _submit(tts_jobs, loaded["tts"], text)
    except web.HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        return web.json_response({"error": str(e)}, status=500)
    return web.Response(body=wav, content_type="audio/wav",
                        headers={"X-Audio-S": f"{dur:.2f}", "X-Elapsed": f"{time.time() - t:.3f}"})


async def warm(_):
    return web.json_response({"ok": True, "loaded": STATE["stt"]})


async def health(_):
    return web.json_response({"ok": STATE["state"] == "ready", **STATE,
                              "stt_model": STT_MODEL, "tts_model": TTS_MODEL})


def watch_parent():
    """Exit when the menu-bar app that started us goes away, however it died,
    so a killed app never leaves 3 GB of models resident with nobody owning them."""
    pid = int(os.getenv("LARMOR_ENGINE_PARENT", "0"))
    if not pid:
        return
    while True:
        time.sleep(2)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            log(f"parent {pid} gone, exiting")
            os._exit(0)


def main():
    threading.Thread(target=boot, daemon=True, name="boot").start()
    threading.Thread(target=watch_parent, daemon=True, name="parent").start()
    app = web.Application(client_max_size=64 * 1024 ** 2, middlewares=[local_only])
    app.router.add_post("/transcribe", transcribe)
    app.router.add_post("/warm", warm)
    app.router.add_post("/speak", speak)
    app.router.add_get("/health", health)
    web.run_app(app, host="127.0.0.1", port=PORT,
                print=lambda *_: log(f"listening on 127.0.0.1:{PORT}"))
    # run_app returns on SIGTERM, but a download in progress keeps non-daemon
    # executor threads alive and the interpreter would wait on them forever.
    log("stopped")
    os._exit(0)


if __name__ == "__main__":
    main()
