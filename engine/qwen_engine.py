"""Qwen 本地推理与人声门控；不保存上次识别文本。"""
from __future__ import annotations

import contextlib
import os
from pathlib import Path
import resource
import sys
import time

import numpy as np

ROOT = Path(__file__).resolve().parent
SAMPLE_RATE = 16000
MODEL_DIR = ROOT / "models" / "qwen3-asr-1.7b-8bit"
VAD_MODEL = ROOT / "models" / "vad" / "silero_vad.onnx"


def read_pcm(path: Path) -> np.ndarray:
    raw = path.read_bytes()
    if len(raw) % 2:
        raise ValueError("录音文件不是完整的 16 位 PCM，请重新录音")
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


def has_speech(samples: np.ndarray) -> bool:
    if len(samples) < SAMPLE_RATE * 0.25 or np.max(np.abs(samples), initial=0) < 0.0001:
        return False
    # 不能把普通环境噪声、提示音当成人声，交给生成式模型猜文字。
    with contextlib.redirect_stdout(sys.stderr):
        import sherpa_onnx

        config = sherpa_onnx.VadModelConfig()
        config.silero_vad.model = str(VAD_MODEL)
        config.silero_vad.threshold = 0.5
        config.silero_vad.min_speech_duration = 0.20
        config.silero_vad.min_silence_duration = 0.15
        config.sample_rate = SAMPLE_RATE
        config.num_threads = 1
        vad = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=30)
        window = config.silero_vad.window_size
        for offset in range(0, len(samples), window):
            chunk = samples[offset:offset + window]
            if len(chunk) < window:
                chunk = np.pad(chunk, (0, window - len(chunk)))
            vad.accept_waveform(chunk)
            if vad.is_speech_detected() or not vad.empty():
                return True
        vad.flush()
        return not vad.empty()


class QwenEngine:
    def __init__(self):
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
        os.environ["TOKENIZERS_PARALLELISM"] = "false"
        if not (MODEL_DIR / "model.safetensors").is_file():
            raise FileNotFoundError(f"找不到本地 Qwen 模型：{MODEL_DIR}")
        started = time.perf_counter()
        with contextlib.redirect_stdout(sys.stderr):
            import mlx.core as mx
            from mlx_audio.stt import load

            self.mx = mx
            mx.set_cache_limit(512 * 1024 * 1024)
            self.model = load(MODEL_DIR, strict=True)
        self.load_seconds = time.perf_counter() - started

    def recognize(self, samples: np.ndarray, language: str | None = None) -> tuple[str, dict]:
        started = time.perf_counter()
        duration = len(samples) / SAMPLE_RATE
        with contextlib.redirect_stdout(sys.stderr):
            # 每个进程只识别本次录音，不传上次文字、草稿或对话历史。
            result = self.model.generate(
                samples, language=language, temperature=0.0,
                max_tokens=min(8192, max(128, int(duration * 12 + 64))),
                chunk_duration=30.0, verbose=False, system_prompt=None,
            )
            self.mx.synchronize()
        inference = time.perf_counter() - started
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        if sys.platform != "darwin":
            rss *= 1024
        return result.text.strip(), {
            "model": "Qwen3-ASR-1.7B-8bit / MLX",
            "audio_seconds": round(duration, 3),
            "load_seconds": round(self.load_seconds, 3),
            "inference_seconds": round(inference, 3),
            "total_seconds": round(self.load_seconds + inference, 3),
            "mlx_peak_gib": round(self.mx.get_peak_memory() / 1024**3, 3),
            "process_peak_gib": round(rss / 1024**3, 3),
        }
